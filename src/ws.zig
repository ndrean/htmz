const std = @import("std");
const zap = @import("zap");
const WebSockets = zap.WebSockets;
const jwt = @import("jwt.zig");
const cart_manager = @import("cart_manager.zig");

var GlobalContextManager: ContextManager = undefined;

const WebsocketHandler = WebSockets.Handler(Context);

const Context = struct {
    user_id: []const u8,
    channel: []const u8,
    subscribeArgs: WebsocketHandler.SubscribeArgs,
    settings: WebsocketHandler.WebSocketSettings,
};

const ContextList = std.ArrayList(*Context);

const ContextManager = struct {
    allocator: std.mem.Allocator,
    channel: []const u8,
    lock: std.Thread.Mutex = .{},
    contexts: ContextList,
    presence_count: u32 = 0,
    cart_manager: *cart_manager.CartManager,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        channelName: []const u8,
        cart_mgr: *cart_manager.CartManager,
    ) Self {
        return .{
            .allocator = allocator,
            .channel = channelName,
            .contexts = ContextList.empty,
            .cart_manager = cart_mgr,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.contexts.items) |ctx| {
            self.allocator.free(ctx.user_id);
            self.allocator.destroy(ctx);
        }
        self.contexts.deinit(self.allocator);
    }

    pub fn newContext(self: *Self, user_id: []const u8) !*Context {
        self.lock.lock();
        defer self.lock.unlock();

        const ctx = try self.allocator.create(Context);
        const owned_user_id = try self.allocator.dupe(u8, user_id);

        ctx.* = .{
            .user_id = owned_user_id,
            .channel = self.channel,
            // used in subscribe()
            .subscribeArgs = .{
                .channel = self.channel,
                .force_text = true,
                .context = ctx,
            },
            // used in upgrade()
            .settings = .{
                .on_open = on_open_websocket,
                .on_close = on_close_websocket,
                .on_message = handle_websocket_message,
                .context = ctx,
            },
        };
        try self.contexts.append(self.allocator, ctx);
        self.presence_count += 1;
        return ctx;
    }

    pub fn removeContext(self: *Self, context: *Context) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.contexts.items, 0..) |ctx, i| {
            if (ctx == context) {
                _ = self.contexts.swapRemove(i);
                self.presence_count -= 1;
                break;
            }
        }
    }

    pub fn getPresenceCount(self: *Self) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.presence_count;
    }
};

fn on_open_websocket(context: ?*Context, handle: WebSockets.WsHandle) !void {
    if (context) |ctx| {
        _ = WebsocketHandler.subscribe(handle, &ctx.subscribeArgs) catch |err| {
            std.log.err("Error subscribing to websocket: {any}", .{err});
            return;
        };

        // Broadcast presence count update (minimal: just the number)
        const count = GlobalContextManager.getPresenceCount();
        var buf: [16]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "{d}",
            .{count},
        ) catch unreachable;

        // Publish to presence channel
        WebsocketHandler.publish(.{ .channel = ctx.channel, .message = message });
        // std.log.info("User {s} connected. Total users: {d}", .{ ctx.user_id, count });
    }
}

fn on_close_websocket(context: ?*Context, uuid: isize) !void {
    _ = uuid;
    if (context) |ctx| {
        // Remove context from manager
        GlobalContextManager.removeContext(ctx);

        // Broadcast updated presence count (minimal: just the number)
        const count = GlobalContextManager.getPresenceCount();
        var buf: [16]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "{d}",
            .{count},
        ) catch unreachable;

        // Publish to presence channel
        WebsocketHandler.publish(.{ .channel = ctx.channel, .message = message });
        // std.log.info("User {s} disconnected. Total users: {d}", .{ ctx.user_id, count });

        // Clear user's shopping cart when they disconnect
        GlobalContextManager.cart_manager.clearCart(ctx.user_id) catch |err| {
            std.log.warn("Failed to clear cart for user {s}: {any}", .{ ctx.user_id, err });
        };

        // Clean up context
        GlobalContextManager.allocator.free(ctx.user_id);
        GlobalContextManager.allocator.destroy(ctx);
    }
}

fn handle_websocket_message(context: ?*Context, handle: WebSockets.WsHandle, message: []const u8, is_text: bool) !void {
    _ = context;
    _ = handle;
    _ = message;
    _ = is_text;
    // For presence, we don't need to handle incoming messages
    // This is just for maintaining the connection
}

// Initialize the global context manager
pub fn initGlobalContextManager(allocator: std.mem.Allocator, cart_mgr: *cart_manager.CartManager) void {
    GlobalContextManager = ContextManager.init(allocator, "presence", cart_mgr);
}

// Upgrade HTTP request to WebSocket for /presence endpoint
pub fn upgradeToWebSocket(r: zap.Request, user_id: []const u8) !void {
    // Create new context for this user
    const context = try GlobalContextManager.newContext(user_id);

    // Upgrade the connection
    try WebsocketHandler.upgrade(r.h, &context.settings);
}

// Deinit the global context manager
pub fn deinitGlobalContextManager() void {
    GlobalContextManager.deinit();
}