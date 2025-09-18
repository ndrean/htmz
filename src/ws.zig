const std = @import("std");
const zap = @import("zap ");
const WebSockets = zap.WebSockets;

var GlobalContextManager: ContextManager = undefined;

const WebsocketHandler = WebSockets.Handler(Context);

const Context = struct {
    channel: []const u8,
    subscribeArgs: WebsocketHandler.SubscribeArgs,
    settings: WebsocketHandler.WebsocketSettings,
};

const ContextList: std.ArrayList(*Context) = .empty;

const ContextManager = struct {
    allocator: std.mem.Allocator,
    channel: []const u8,
    usernamePrefix: []const u8,
    lock: std.Thread.Mutex = .{},
    contexts: ContextList = undefined,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        channelName: []const u8,
        usernamePrefix: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .channel = channelName,
            .usernamePrefix = usernamePrefix,
            .contexts = ContextList.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.contexts.items) |ctx| {
            self.allocator.free(ctx.userName);
        }
        self.contexts.deinit();
    }

    pub fn newContext(self: *Self) !*Context {
        self.lock.lock();
        defer self.lock.unlock();

        const ctx = try self.allocator.create(Context);
        const userName = try std.fmt.allocPrint(
            self.allocator,
            "{s}{d}",
            .{ self.usernamePrefix, self.contexts.items.len },
        );
        ctx.* = .{
            .userName = userName,
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
                // .on_message = handle_websocket_message,
                .context = ctx,
            },
        };
        try self.contexts.append(ctx);
        return ctx;
    }
};

fn on_open_websocket(context: ?*Context, handle: WebSockets.WsHandle) void {
    if (context) |ctx| {
        _ = WebsocketHandler.subscribe(handle, &ctx.subscribeArgs) catch |err| {
            std.log.err("Error opening websocket: {any}", .{err});
            return;
        };

        // say hello
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "{s} joined the chat.",
            .{ctx.userName},
        ) catch unreachable;

        // send notification to all others
        WebsocketHandler.publish(.{ .channel = ctx.channel, .message = message });
        std.log.info("new websocket opened: {s}", .{message});
    }
}

fn on_close_websocket(context: ?*Context, uuid: isize) void {
    _ = uuid;
    if (context) |ctx| {
        // say goodbye
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "{s} left the chat.",
            .{ctx.userName},
        ) catch unreachable;

        // send notification to all others
        WebsocketHandler.publish(.{ .channel = ctx.channel, .message = message });
        std.log.info("websocket closed: {s}", .{message});
    }
}
