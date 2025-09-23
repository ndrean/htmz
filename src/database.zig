//! Database operations for shopping cart
const std = @import("std");
const sqlite = @import("sqlite");

pub const CartItem = struct {
    id: u32,
    name: []const u8,
    quantity: u32,
    price: f32,
};

// Helper function to read SVG file content
fn readSVGFile(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    var path_buffer: [256]u8 = undefined;
    const svg_path = try std.fmt.bufPrint(&path_buffer, "public/svg/{s}", .{filename});

    return std.fs.cwd().readFileAlloc(allocator, svg_path, 16384) catch |err| {
        std.debug.print("Failed to read SVG file {s}: {any}\n", .{ svg_path, err });
        return error.SVGReadError; // Don't allocate on error
    };
}

pub const Database = struct {
    db: sqlite.Db,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
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

        var database = Database{
            .db = db,
            .mutex = std.Thread.Mutex{},
        };

        // No PRAGMA statements - testing if they were causing the performance issues

        try database.createTables();
        try database.createItems(allocator);
        return database;
    }

    pub fn deinit(self: *Database) void {
        self.db.deinit();
    }

    fn createItems(self: *Database, allocator: std.mem.Allocator) !void {
        // Note: createItems is called during init before any concurrent access
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
                // Read SVG files and insert with actual content
                const items = [_]struct { name: []const u8, price: f32, svg_file: []const u8 }{
                    .{ .name = "Apple", .price = 0.50, .svg_file = "apple-svgrepo-com.svg" },
                    .{ .name = "Bananas", .price = 0.30, .svg_file = "banana-svgrepo-com.svg" },
                    .{ .name = "Bread", .price = 2.00, .svg_file = "bread-svgrepo-com.svg" },
                    .{ .name = "Cheese", .price = 3.00, .svg_file = "cheese-svgrepo-com.svg" },
                    .{ .name = "Chicken", .price = 5.00, .svg_file = "chicken-svgrepo-com.svg" },
                    .{ .name = "Fish", .price = 7.00, .svg_file = "fish-svgrepo-com.svg" },
                    .{ .name = "Grapes", .price = 2.50, .svg_file = "grapes-svgrepo-com.svg" },
                    .{ .name = "Carrot", .price = 0.20, .svg_file = "carrot-svgrepo-com.svg" },
                    .{ .name = "Doughnut", .price = 1.00, .svg_file = "doughnut-svgrepo-com.svg" },
                    .{ .name = "Eggs (dozen)", .price = 2.50, .svg_file = "eggs-svgrepo-com.svg" },
                };

                for (items) |item| {
                    const svg_content = readSVGFile(allocator, item.svg_file) catch {
                        continue;
                    };
                    defer allocator.free(svg_content);


                    var stmt = try self.db.prepare("INSERT INTO items (name, price, image) VALUES (?, ?, ?)");
                    defer stmt.deinit();

                    try stmt.exec(.{}, .{ .name = item.name, .price = item.price, .image = svg_content });
                }
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
        svg_data: ?[]const u8,
    };

    pub fn getGroceryItem(self: *Database, allocator: std.mem.Allocator, item_id: u32) !?GroceryItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql = "SELECT id, name, price, image FROM items WHERE id = ?";
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        var iter = try stmt.iterator(struct {
            id: c_int,
            name: [256:0]u8,
            price: f64,
            image: ?[16384:0]u8,
        }, .{ .id = item_id });

        if (try iter.next(.{})) |row| {
            const name = try allocator.dupe(
                u8,
                std.mem.sliceTo(&row.name, 0),
            );
            const svg_data = if (row.image) |img| try allocator.dupe(
                u8,
                std.mem.sliceTo(&img, 0),
            ) else null;
            return GroceryItem{
                .id = @intCast(row.id),
                .name = name,
                .price = @floatCast(row.price),
                .svg_data = svg_data,
            };
        }
        return null;
    }

    pub fn getAllGroceryItems(self: *Database, allocator: std.mem.Allocator) ![]GroceryItem {
        self.mutex.lock();
        defer self.mutex.unlock();

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

        var count: u32 = 0;
        while (try iter.next(.{})) |row| {
            count += 1;

            const name = try allocator.dupe(
                u8,
                std.mem.sliceTo(&row.name, 0),
            );

            try items.append(
                allocator,
                GroceryItem{
                    .id = @intCast(row.id),
                    .name = name,
                    .price = @floatCast(row.price),
                    .svg_data = null, // No SVG data for list view
                },
            );
        }

        return try items.toOwnedSlice(allocator);
    }
};
