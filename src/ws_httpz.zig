const std = @import("std");
const httpz = @import("httpz");
const jwt = @import("jwt.zig");

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

    pub const WSContext = struct {
        user_id: []const u8,
        allocator: std.mem.Allocator,
    };

    pub fn init(conn: *websocket.Conn, context: *const WSContext) !@This() {
        // Initialize clients list if needed
        if (!clients_initialized) {
            clients = .empty;
            clients_initialized = true;
        }

        const self = @This(){
            .user_id = context.user_id,
            .conn = conn,
            .allocator = context.allocator,
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
