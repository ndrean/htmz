const std = @import("std");
const zap = @import("zap");

/// Simple presence manager for tracking connected users
pub const Presence = struct {
    allocator: std.mem.Allocator,
    connections: std.HashMap(u32, void, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            // user_id (u32) -> void (no value, just key presence) to build a SET
            .connections = std.HashMap(
                u32,
                void,
                std.hash_map.AutoContext(u32),
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // No need to free keys since they're just u32 numbers
        self.connections.deinit();
    }

    /// Add a new user connection
    pub fn addConnection(self: *Self, presence_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.connections.put(presence_id, {});
        std.log.info("Added presence_id {d} to connections", .{presence_id});
    }

    /// Remove a user connection
    pub fn removeConnection(self: *Self, presence_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.connections.remove(presence_id);
        std.log.info("Removed presence_id {d} from connections", .{presence_id});
    }

    /// Get current user count
    pub fn getUserCount(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.connections.count());
    }

    /// Broadcast user count to all connected WebSocket clients
    pub fn broadcastUserCount(self: *Self) void {
        const count = self.getUserCount();
        std.log.info("User count: {d}", .{count});

        // Create JSON message with user count
        var buffer: [100]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{{\"type\":\"user_count\",\"count\":{d}}}", .{count}) catch {
            std.log.err("Failed to format user count message", .{});
            return;
        };

        // Publish to the "presence" channel
        const WsHandler = zap.WebSockets.Handler(*WebSocketContext);
        WsHandler.publish(.{
            .channel = "presence",
            .message = message,
            .is_json = true,
        });
    }
};

/// Context for individual WebSocket connections
pub const WebSocketContext = struct {
    allocator: std.mem.Allocator,
    presence_id: u32, // Simple numeric ID for presence tracking
    settings: zap.WebSockets.Handler(*WebSocketContext).WebSocketSettings,

    const Self = @This();

    var next_presence_id: u32 = 1;
    var presence_id_mutex: std.Thread.Mutex = std.Thread.Mutex{};

    fn generatePresenceId() u32 {
        presence_id_mutex.lock();
        defer presence_id_mutex.unlock();

        const id = next_presence_id;
        next_presence_id += 1;
        return id;
    }

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const presence_id = generatePresenceId();
        std.log.info("Creating WebSocket context with presence_id: {d}", .{presence_id});

        const ctx = try allocator.create(Self);
        ctx.* = Self{
            .allocator = allocator,
            .presence_id = presence_id,
            .settings = undefined, // Will be set after creation
        };

        std.log.info("Context created with presence_id: {d}", .{ctx.presence_id});
        return ctx;
    }

    pub fn deinit(self: *Self) void {
        // Nothing to free anymore since presence_id is just a number
        _ = self;
    }
};

/// Global WebSocket Context Manager for proper memory management
pub const WebSocketContextManager = struct {
    allocator: std.mem.Allocator,
    contexts: std.ArrayList(*WebSocketContext),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .contexts = std.ArrayList(*WebSocketContext).empty,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all contexts
        for (self.contexts.items) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        self.contexts.deinit(self.allocator);
    }

    pub fn createContext(self: *Self) !*WebSocketContext {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = try WebSocketContext.init(self.allocator);
        try self.contexts.append(self.allocator, ctx);
        return ctx;
    }

    pub fn removeContext(self: *Self, ctx: *WebSocketContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find and remove the context from the list
        for (self.contexts.items, 0..) |item, i| {
            if (item == ctx) {
                _ = self.contexts.swapRemove(i);
                break;
            }
        }

        // Clean up the context
        ctx.deinit();
        self.allocator.destroy(ctx);
    }
};
