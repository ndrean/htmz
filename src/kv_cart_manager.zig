const std = @import("std");
const okredis = @import("okredis");
const database = @import("database.zig");

const Client = okredis.Client;
const DynamicReply = okredis.types.DynamicReply;

pub const KVCartManager = struct {
    allocator: std.mem.Allocator,
    database: *database.Database,
    redis_client: Client,
    reader_buffer: [4096]u8,
    writer_buffer: [4096]u8,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, db: *database.Database, uri: []const u8) !KVCartManager {
        var manager = KVCartManager{
            .allocator = allocator,
            .database = db,
            .redis_client = undefined,
            .reader_buffer = undefined,
            .writer_buffer = undefined,
            .mutex = std.Thread.Mutex{},
        };

        // Initialize Redis connection
        const addr = try std.net.Address.parseIp4(uri, 6379);
        const connection = try std.net.tcpConnectToAddress(addr);

        manager.redis_client = try Client.init(connection, .{
            .reader_buffer = &manager.reader_buffer,
            .writer_buffer = &manager.writer_buffer,
        });

        return manager;
    }

    pub fn deinit(self: *KVCartManager) void {
        self.redis_client.close();
    }

    // Helper function to create cart key: "user:{user_id}"
    fn makeCartKey(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "user:{s}", .{user_id});
    }


    /// Add item to cart (or increase quantity if already exists) - HINCRBY user:{user_id} {item_id} 1
    pub fn addToCart(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8, item_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);
        const item_id_str = try std.fmt.allocPrint(allocator, "{d}", .{item_id});
        defer allocator.free(item_id_str);

        std.debug.print("Adding item {d} to user {s}\n", .{ item_id, user_id });

        // HINCRBY user:{user_id} {item_id} 1 (creates field if it doesn't exist)
        const new_qty = try self.redis_client.send(i64, .{ "HINCRBY", cart_key, item_id_str, 1 });
        std.debug.print("New quantity for item {d}: {d}\n", .{ item_id, new_qty });
    }

    /// Remove item from cart completely
    pub fn removeFromCart(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8, item_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.print("Removing item {d} from user {s} cart\n", .{ item_id, user_id });

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);
        const item_id_str = try std.fmt.allocPrint(allocator, "{d}", .{item_id});
        defer allocator.free(item_id_str);

        // HDEL user:{user_id} {item_id}
        try self.redis_client.send(void, .{ "HDEL", cart_key, item_id_str });
    }

    /// Increase item quantity by 1
    pub fn increaseQuantity(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8, item_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);
        const item_id_str = try std.fmt.allocPrint(allocator, "{d}", .{item_id});
        defer allocator.free(item_id_str);

        // HINCRBY user:{user_id} {item_id} 1
        _ = try self.redis_client.send(i64, .{ "HINCRBY", cart_key, item_id_str, 1 });
    }

    /// Decrease item quantity by 1 (removes item if quantity reaches 0)
    pub fn decreaseQuantity(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8, item_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);
        const item_id_str = try std.fmt.allocPrint(allocator, "{d}", .{item_id});
        defer allocator.free(item_id_str);

        // HINCRBY user:{user_id} {item_id} -1
        const new_qty = try self.redis_client.send(i64, .{ "HINCRBY", cart_key, item_id_str, -1 });

        // If quantity reaches 0 or below, remove item completely
        if (new_qty <= 0) {
            try self.redis_client.send(void, .{ "HDEL", cart_key, item_id_str });
        }
    }

    /// Get cart count (total number of items) - HVALS user:{user_id}
    pub fn getCartCount(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);

        // HVALS user:{user_id} to get all quantity values
        const quantities = self.redis_client.sendAlloc([][]u8, allocator, .{ "HVALS", cart_key }) catch |err| switch (err) {
            error.Nil => return 0,
            else => return err,
        };
        defer allocator.free(quantities);

        var total_count: u32 = 0;
        for (quantities) |qty_str| {
            const qty = std.fmt.parseInt(u32, qty_str, 10) catch continue;
            total_count += qty;
        }

        return total_count;
    }

    /// Get cart total value - HKEYS user:{user_id} then HGET for each item
    pub fn getCartTotal(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8) !f64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_value: f64 = 0.0;

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);

        // HKEYS user:{user_id} to get all item IDs
        const item_id_strs = self.redis_client.sendAlloc([][]u8, allocator, .{ "HKEYS", cart_key }) catch |err| switch (err) {
            error.Nil => return 0.0,
            else => return err,
        };
        defer allocator.free(item_id_strs);

        for (item_id_strs) |item_id_str| {
            const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch continue;

            // HGET user:{user_id} {item_id}
            const qty_str = self.redis_client.sendAlloc(?[]u8, allocator, .{ "HGET", cart_key, item_id_str }) catch continue;
            defer if (qty_str) |str| allocator.free(str);

            if (qty_str) |str| {
                const qty = std.fmt.parseInt(u32, str, 10) catch continue;
                if (qty > 0) {
                    // Get item details from database
                    if (self.database.getGroceryItem(allocator, item_id) catch null) |item| {
                        total_value += item.price * @as(f64, @floatFromInt(qty));
                    }
                }
            }
        }

        return total_value;
    }

    /// Get full cart with items - HKEYS user:{user_id} then HGET for each
    pub fn getCart(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8) ![]database.CartItem {
        std.debug.print("GETCART: Fetching cart for user: {s}\n", .{user_id});

        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);

        // Get item IDs using HKEYS, then individual HGET operations
        std.debug.print("About to call HKEYS for key: {s}\n", .{cart_key});
        const item_id_strs = self.redis_client.sendAlloc([][]u8, allocator, .{ "HKEYS", cart_key }) catch |err| switch (err) {
            error.Nil => {
                std.debug.print("HKEYS returned Nil (empty cart)\n", .{});
                return allocator.alloc(database.CartItem, 0);
            },
            else => {
                std.debug.print("HKEYS error: {any}\n", .{err});
                return err;
            },
        };
        defer allocator.free(item_id_strs);
        std.debug.print("HKEYS returned {} item IDs\n", .{item_id_strs.len});

        var cart_items: std.ArrayList(database.CartItem) = .empty;
        defer cart_items.deinit(allocator);

        for (item_id_strs) |item_id_str| {
            const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch continue;

            // Get quantity using HGET
            const qty_str = self.redis_client.sendAlloc(?[]u8, allocator, .{ "HGET", cart_key, item_id_str }) catch continue;
            defer if (qty_str) |str| allocator.free(str);
            const qty = if (qty_str) |str| std.fmt.parseInt(u32, str, 10) catch 0 else 0;

            std.debug.print("Item {d}: quantity = {d}\n", .{ item_id, qty });

            // Get item details from database
            if (self.database.getGroceryItem(allocator, item_id) catch null) |item| {
                try cart_items.append(allocator, database.CartItem{
                    .id = item.id,
                    .name = item.name,
                    .price = item.price,
                    .quantity = qty,
                });
            }
        }

        return cart_items.toOwnedSlice(allocator);
    }

    /// Remove entire user cart (for WebSocket cleanup) - using hash operations
    pub fn removeUserCart(self: *KVCartManager, allocator: std.mem.Allocator, user_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cart_key = try self.makeCartKey(allocator, user_id);
        defer allocator.free(cart_key);

        // Simply delete the entire hash - this removes all items at once
        try self.redis_client.send(void, .{ "DEL", cart_key });

        std.log.info("Removed Redis cart for user: {s}", .{user_id});
    }
};
