//! Concurrent Cart manager using user_id as key with nested HashMap
const std = @import("std");
const database = @import("database.zig");

pub const CartManager = struct {
    main_db: *database.Database,
    // user_id -> HashMap(item_id -> quantity)
    user_carts: std.HashMap(
        []const u8,
        std.HashMap(
            u32,
            u32,
            std.hash_map.AutoContext(u32),
            std.hash_map.default_max_load_percentage,
        ),
        std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
    ),
    allocator: std.mem.Allocator,
    rwlock: std.Thread.RwLock,

    pub fn init(allocator: std.mem.Allocator, main_db: *database.Database) !CartManager {
        return CartManager{
            .main_db = main_db,
            .user_carts = std.HashMap(
                []const u8,
                std.HashMap(u32, u32, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
                std.hash_map.StringContext,
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .allocator = allocator,
            .rwlock = std.Thread.RwLock{},
        };
    }

    pub fn deinit(self: *CartManager) void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        // Free all stored data
        var iter = self.user_carts.iterator();
        while (iter.next()) |entry| {
            // Free user_id key
            self.allocator.free(entry.key_ptr.*);
            // Deinit the inner HashMap
            entry.value_ptr.deinit();
        }
        self.user_carts.deinit();
        // Don't deinit main_db here - it's managed elsewhere
    }

    pub fn getMainDatabase(self: *CartManager) *database.Database {
        return self.main_db;
    }

    pub fn addToCart(self: *CartManager, user_id: []const u8, item_id: u32) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        try self.ensureUserCartExists(user_id);
        // Don't store the pointer - refetch after potential reallocation
        if (self.user_carts.getPtr(user_id)) |cart| {
            if (cart.getPtr(item_id)) |existing_quantity| {
                existing_quantity.* += 1;
            } else {
                try cart.put(item_id, 1);
            }
        }
    }

    pub fn removeFromCart(self: *CartManager, user_id: []const u8, item_id: u32) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.user_carts.getPtr(user_id)) |cart| {
            _ = cart.remove(item_id);
        }
    }

    pub fn increaseQuantity(self: *CartManager, user_id: []const u8, item_id: u32) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.user_carts.getPtr(user_id)) |cart| {
            if (cart.getPtr(item_id)) |quantity| {
                quantity.* += 1;
            }
        }
    }

    pub fn decreaseQuantity(self: *CartManager, user_id: []const u8, item_id: u32) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.user_carts.getPtr(user_id)) |cart| {
            if (cart.getPtr(item_id)) |quantity| {
                if (quantity.* > 1) {
                    quantity.* -= 1;
                } else {
                    // Remove item if quantity becomes 0
                    _ = cart.remove(item_id);
                }
            }
        }
    }

    pub fn getCart(self: *CartManager, allocator: std.mem.Allocator, user_id: []const u8) ![]database.CartItem {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        var cart_items: std.ArrayList(database.CartItem) = .empty;
        defer cart_items.deinit(allocator);

        if (self.user_carts.get(user_id)) |cart| {
            var iter = cart.iterator();
            while (iter.next()) |entry| {
                const item_id = entry.key_ptr.*;
                const quantity = entry.value_ptr.*;

                // Get item details from database
                if (self.main_db.getGroceryItem(allocator, item_id)) |grocery_item_opt| {
                    if (grocery_item_opt) |grocery_item| {
                        defer allocator.free(grocery_item.name);
                        defer if (grocery_item.svg_data) |svg| allocator.free(svg);

                        const item_name = try allocator.dupe(
                            u8,
                            grocery_item.name,
                        );
                        try cart_items.append(allocator, database.CartItem{
                            .id = item_id,
                            .name = item_name,
                            .quantity = quantity,
                            .price = grocery_item.price,
                        });
                    }
                } else |_| {
                    continue;
                }
            }
        } else {}

        return try cart_items.toOwnedSlice(allocator);
    }

    pub fn getCartCount(self: *CartManager, user_id: []const u8) !c_int {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        if (self.user_carts.get(user_id)) |cart| {
            var total_count: c_int = 0;
            var iter = cart.iterator();
            while (iter.next()) |entry| {
                total_count += @intCast(entry.value_ptr.*);
            }
            return total_count;
        }
        return 0;
    }

    pub fn getCartTotal(self: *CartManager, allocator: std.mem.Allocator, user_id: []const u8) !f32 {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        if (self.user_carts.get(user_id)) |cart| {
            var total: f32 = 0.0;
            var iter = cart.iterator();
            while (iter.next()) |entry| {
                const item_id = entry.key_ptr.*;
                const quantity = entry.value_ptr.*;

                // Get price from database
                if (self.main_db.getGroceryItem(allocator, item_id)) |grocery_item_opt| {
                    if (grocery_item_opt) |grocery_item| {
                        defer allocator.free(grocery_item.name);
                        defer if (grocery_item.svg_data) |svg| allocator.free(svg);
                        total += grocery_item.price * @as(f32, @floatFromInt(quantity));
                    }
                } else |_| {
                    // Skip items that can't be found in database
                    continue;
                }
            }
            return total;
        }
        return 0.0;
    }

    pub fn clearCart(self: *CartManager, user_id: []const u8) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.user_carts.getPtr(user_id)) |cart| {
            cart.clearAndFree();
        }
    }

    // Private helper function to ensure a user's cart exists
    fn ensureUserCartExists(self: *CartManager, user_id: []const u8) !void {
        if (self.user_carts.contains(user_id)) {
            return;
        }

        // Create new cart for this user_id
        const user_id_copy = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(user_id_copy); // Clean up on error

        const new_cart = std.HashMap(u32, u32, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(self.allocator);
        try self.user_carts.put(user_id_copy, new_cart);
    }
};
