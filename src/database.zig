//! Database operations for shopping cart
const std = @import("std");
const sqlite = @import("sqlite");

pub const CartItem = struct {
    id: u32,
    name: []const u8,
    quantity: u32,
    price: f32,
};

pub const Database = struct {
    db: sqlite.Db,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        _ = allocator; // Not needed for memory mode
        _ = db_path; // Not needed for memory mode

        // File mode (commented for testing .Memory)
        // const db_path_z = try allocator.dupeZ(u8, db_path);
        // defer allocator.free(db_path_z);
        // const db = try sqlite.Db.init(.{
        //     .mode = .{ .File = db_path_z },

        // Memory mode
        const db = try sqlite.Db.init(.{
            .mode = .Memory,
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        });

        var database = Database{ .db = db };

        // No PRAGMA statements - testing if they were causing the performance issues

        try database.createTables();
        try database.createItems();
        return database;
    }

    pub fn deinit(self: *Database) void {
        self.db.deinit();
    }

    fn createItems(self: *Database) !void {
        const create_items_sql =
            \\CREATE TABLE IF NOT EXISTS items (
            \\    id INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    price REAL NOT NULL,
            \\    image TEXT
            \\);
        ;

        // the image field could be an SVG or URL to an image, but for simplicity we leave it NULL for now

        try self.db.exec(create_items_sql, .{}, .{});

        // Prepopulate with some items if table is empty
        const count_sql = "SELECT COUNT(*) FROM items";
        var count_stmt = try self.db.prepare(count_sql);
        defer count_stmt.deinit();
        const count = count_stmt.one(c_int, .{}, .{}) catch {

            // std.debug.print("Failed to count items: {}\n", .{err});
            return;
        };
        // std.debug.print("count: {any}\n", .{count});

        if (count) |c| {
            if (c == 0) {
                const insert_sql =
                    \\INSERT INTO items (name, price) VALUES
                    \\('Apple', 0.50),
                    \\('Bananas', 0.30),
                    \\('Bread', 2.00),
                    \\('Cheese', 3.00),
                    \\('Chicken', 5.00),
                    \\('Fish', 7.00),
                    \\('Grapes', 2.50),
                    \\('Carrot', 0.20),
                    \\('Doughnut', 1.00),
                    \\('Eggs (dozen)', 2.50);
                ;
                try self.db.exec(insert_sql, .{}, .{});
            }
        }
    }

    fn createTables(_: *Database) !void {
        // No cart table needed - using HashMap for cart storage
    }

    // Grocery items functions
    pub const GroceryItem = struct {
        id: u32,
        name: []const u8,
        price: f32,
    };

    pub fn getGroceryItem(self: *Database, allocator: std.mem.Allocator, item_id: u32) !?GroceryItem {
        const sql = "SELECT id, name, price FROM items WHERE id = ?";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        var iter = try stmt.iterator(struct {
            id: c_int,
            name: [256:0]u8,
            price: f64,
        }, .{ .id = item_id });

        if (try iter.next(.{})) |row| {
            const name = try allocator.dupe(u8, std.mem.sliceTo(&row.name, 0));
            return GroceryItem{
                .id = @intCast(row.id),
                .name = name,
                .price = @floatCast(row.price),
            };
        }
        return null;
    }

    pub fn getAllGroceryItems(self: *Database, allocator: std.mem.Allocator) ![]GroceryItem {
        const sql = "SELECT id, name, price FROM items ORDER BY id";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        var iter = try stmt.iterator(struct {
            id: c_int,
            name: [256:0]u8,
            price: f64,
        }, .{});

        var items: std.ArrayList(GroceryItem) = .empty;
        defer items.deinit(allocator);

        while (try iter.next(.{})) |row| {
            const name = try allocator.dupe(u8, std.mem.sliceTo(&row.name, 0));
            try items.append(allocator, GroceryItem{
                .id = @intCast(row.id),
                .name = name,
                .price = @floatCast(row.price),
            });
        }

        return try items.toOwnedSlice(allocator);
    }
};
