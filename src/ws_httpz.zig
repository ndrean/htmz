const std = @import("std");
const httpz = @import("httpz");
const jwt = @import("jwt.zig");
const cart_manager = @import("cart_manager.zig");

const websocket = httpz.websocket;

// JWT Helper Functions for WebSocket
fn getCookieToken(req: *httpz.Request, allocator: std.mem.Allocator) ?[]const u8 {
    var cookies = req.cookies();
    if (cookies.get("jwt_token")) |token| {
        return allocator.dupe(u8, token) catch null;
    }
    return null;
}

// JWT validation - returns payload if valid, null if invalid/missing
fn validateJWT(req: *httpz.Request, allocator: std.mem.Allocator) ?jwt.JWTPayload {
    if (getCookieToken(req, allocator)) |token| {
        defer allocator.free(token);
        if (jwt.verifyJWT(allocator, token)) |payload| {
            return payload;
        } else |_| {
            // JWT verification failed
            return null;
        }
    }
    return null; // No JWT cookie found
}

// Global presence counter
var presence_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Global list of connected clients for broadcasting
var clients: std.ArrayList(*WSClient) = undefined;
var clients_mutex: std.Thread.Mutex = .{};
var clients_initialized = false;

// Simple WebSocket Client handler for httpz
pub const WSClient = struct {
    user_id: []const u8,
    conn: *websocket.Conn,
    allocator: std.mem.Allocator,
    cart_manager: *cart_manager.CartManager,

    pub const WSContext = struct {
        user_id: []const u8,
        allocator: std.mem.Allocator,
        cart_manager: *cart_manager.CartManager,
    };

    pub fn init(conn: *websocket.Conn, context: *const WSContext) !@This() {
        // Initialize clients list if needed
        if (!clients_initialized) {
            clients = .empty;
            clients_initialized = true;
        }

        // Make our own copy of user_id since JWT payload will be freed
        const user_id_copy = try context.allocator.dupe(u8, context.user_id);

        const self = @This(){
            .user_id = user_id_copy,
            .conn = conn,
            .allocator = context.allocator,
            .cart_manager = context.cart_manager,
        };

        return self;
    }

    pub fn afterInit(self: *@This()) !void {
        // Add to clients list
        {
            clients_mutex.lock();
            defer clients_mutex.unlock();
            try clients.append(self.allocator, self);
        }

        // Increment presence count
        const new_count = presence_count.fetchAdd(1, .monotonic) + 1;
        // std.log.info("WebSocket connection established for user: {s} (total: {d})", .{ self.user_id, new_count });

        // Broadcast new count to all clients
        try broadcastPresenceCount(new_count);
    }

    pub fn clientMessage(_: *@This(), _: []const u8) !void {
        // std.log.info("Received message from {s}: {s}", .{ self.user_id, message });
        // Echo back for testing - in real implementation you'd send back via the connection
    }

    pub fn clientClose(self: *@This(), data: []const u8) !void {
        _ = data; // Close reason data

        // std.log.info("Cleaning up WebSocket client for user: {s}", .{self.user_id});

        // Clean up user's cart data
        self.cart_manager.removeUserCart(self.user_id);

        // Remove from clients list
        {
            clients_mutex.lock();
            defer clients_mutex.unlock();
            for (clients.items, 0..) |client, i| {
                if (client == self) {
                    _ = clients.swapRemove(i);
                    break;
                }
            }
        }

        // Decrement presence count
        const new_count = presence_count.fetchSub(1, .monotonic) - 1;
        // std.log.info("WebSocket connection closed for user: {s} (total: {d})", .{ self.user_id, new_count });

        // Broadcast new count to remaining clients
        broadcastPresenceCount(new_count) catch |err| {
            std.log.err("Failed to broadcast presence count on disconnect: {any}", .{err});
        };

        // Free only the user_id string - the WebSocket framework manages the client struct lifecycle
        std.log.info("Freeing user_id string for: {s}", .{self.user_id});
        self.allocator.free(self.user_id);
    }

    pub fn deinit(_: *@This()) void {
        // Cleanup if needed - clientClose should handle most disconnect logic
        // std.log.debug("Deinit called for user: {s}", .{self.user_id});
    }
};

// Broadcast presence count to all connected clients
fn broadcastPresenceCount(count: u32) !void {
    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return;

    clients_mutex.lock();
    defer clients_mutex.unlock();

    // Send to all connected clients, but skip failed ones
    var i: usize = 0;
    while (i < clients.items.len) {
        const client = clients.items[i];
        client.conn.write(count_str) catch |err| {
            std.log.warn("Failed to send presence count to client {s}: {any}, removing", .{ client.user_id, err });
            // Remove the failed client
            _ = clients.swapRemove(i);
            continue; // Don't increment i since we removed an item
        };
        i += 1;
    }
}

// WebSocket upgrade handler for httpz
pub fn websocketHandler(handler: anytype, req: *httpz.Request, res: *httpz.Response) !void {
    // Validate JWT and get user ID
    const payload = validateJWT(req, handler.app.allocator) orelse {
        res.status = 401;
        res.content_type = httpz.ContentType.TEXT;
        res.body = "401 - Unauthorized";
        return;
    };
    defer jwt.deinitPayload(handler.app.allocator, payload);

    // Create context for the WebSocket connection with validated user_id
    const ctx = WSClient.WSContext{
        .user_id = payload.user_id,
        .allocator = handler.app.allocator,
        .cart_manager = handler.app.cart_manager,
    };

    // Attempt to upgrade the connection using httpz built-in WebSocket support
    if (try httpz.upgradeWebsocket(WSClient, req, res, &ctx) == false) {
        // Not a WebSocket upgrade request - return current presence count
        const current_count = presence_count.load(.monotonic);
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{current_count}) catch "0";

        res.status = 200;
        res.content_type = httpz.ContentType.TEXT;
        res.body = count_str;
    }
}

// Cleanup function for shutdown - cleans up the global clients ArrayList
// Individual clients should clean themselves up in clientClose(), but during
// server shutdown we need to clean up the ArrayList itself and any remaining clients
pub fn deinitWebSocketClients(allocator: std.mem.Allocator) void {
    if (clients_initialized) {
        clients_mutex.lock();
        defer clients_mutex.unlock();

        std.log.info("Cleaning up global WebSocket clients list ({} clients remaining)", .{clients.items.len});

        // Clean up any remaining clients that didn't get a chance to call clientClose
        for (clients.items) |client| {
            std.log.info("Cleaning up remaining client user_id: {s}", .{client.user_id});
            allocator.free(client.user_id);
            // Note: Don't destroy the client struct - WebSocket framework handles that
        }

        // Deinit the ArrayList itself
        clients.deinit(allocator);
        clients_initialized = false;

        std.log.info("Global WebSocket clients list cleaned up", .{});
    } else {
        std.log.info("WebSocket clients list was not initialized", .{});
    }
}
