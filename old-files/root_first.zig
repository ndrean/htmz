//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const httpz = @import("httpz");
pub const z = @import("zexplorer");
const sqlite = @import("sqlite");
const grocery_items = @import("grocery_items.zig").grocery_list;

pub fn bPrint(i: usize) !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests: {d}\n", .{i});

    try stdout.flush(); // Don't forget to flush!
}

const CartItem = struct {
    name: []const u8,
    price: f32,
    quantity: u32,
};

const DataSourceType = enum {
    memory,
    sqlite,
};

const DataSource = union(DataSourceType) {
    memory: std.StringHashMap([]const u8),
    sqlite: sqlite.Db,
};


const App = struct {
    initial_html: []const u8,
    allocator: std.mem.Allocator,
    // css_engine: *z.CssSelectorEngine,
    body_node: *z.DomNode,
    cart: std.ArrayList(CartItem),
    // Pre-loaded templates (slices already contain length information)
    preloaded_grocery_items_html: []const u8,
    preloaded_groceries_page_html: []const u8,
    preloaded_shopping_list_html: []const u8,
    preloaded_item_details_default_html: []const u8,
    preloaded_item_details_template: []const u8,
    preloaded_cart_item_template: []const u8,
    // Data source configuration
    data_source_type: DataSourceType,
    data_source: DataSource,
};

fn preloadTemplates(
    allocator: std.mem.Allocator,
    body_node: *z.DomNode,
    _: *z.CssSelectorEngine,
) !struct {
    grocery_items_template: []const u8,
    groceries_page_html: []const u8,
    shopping_list_html: []const u8,
    item_details_default_html: []const u8,
    item_details_template: []const u8,
    cart_item_template: []const u8,
} {
    const doc = z.ownerDocument(body_node);

    // Extract raw templates (no data substitution)
    // const item_template = try css_engine.querySelector(body_node, "#grocery-item-template");
    // const grocery_item_template_html = try z.innerTemplateHTML(allocator, item_template.?);

    const item_template = try z.querySelector(allocator, doc, "#grocery-item-template");
    const grocery_item_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(item_template.?));

    const groceries_template = try z.querySelector(allocator, doc, "#groceries-page-template");
    const groceries_html = try z.innerTemplateHTML(allocator, z.elementToNode(groceries_template.?));
    // const groceries_template = try css_engine.querySelector(body_node, "#groceries-page-template");
    // const groceries_html = try z.innerTemplateHTML(allocator, groceries_template.?);

    const shopping_template = try z.querySelector(allocator, doc, "#shopping-list-template");
    const shopping_html = try z.innerTemplateHTML(allocator, z.elementToNode(shopping_template.?));

    // const shopping_template = try css_engine.querySelector(body_node, "#shopping-list-template");
    // const shopping_html = try z.innerTemplateHTML(allocator, shopping_template.?);

    const default_template = try z.querySelector(allocator, doc, "#item-details-default-template");
    const default_html = try z.innerTemplateHTML(allocator, z.elementToNode(default_template.?));

    // const default_template = try css_engine.querySelector(body_node, "#item-details-default-template");
    // const default_html = try z.innerTemplateHTML(allocator, default_template.?);

    const details_template = try z.querySelector(allocator, doc, "#item-details-template");
    const details_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(details_template.?));
    // const details_template = try css_engine.querySelector(body_node, "#item-details-template");
    // const details_template_html = try z.innerTemplateHTML(allocator, details_template.?);

    const cart_item_template = try z.querySelector(allocator, doc, "#cart-item-template");

    const cart_item_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(cart_item_template.?));
    // const cart_item_template = try css_engine.querySelector(body_node, "#cart-item-template");
    // const cart_item_template_html = try z.innerTemplateHTML(allocator, cart_item_template.?);

    return .{
        .grocery_items_template = grocery_item_template_html,
        .groceries_page_html = groceries_html,
        .shopping_list_html = shopping_html,
        .item_details_default_html = default_html,
        .item_details_template = details_template_html,
        .cart_item_template = cart_item_template_html,
    };
}

fn initMemoryDataSource(allocator: std.mem.Allocator) DataSource {
    // For memory mode, we'll just use an empty HashMap since we'll generate HTML on-the-fly
    // using the pre-loaded templates and hardcoded grocery_items data
    return DataSource{ .memory = std.StringHashMap([]const u8).init(allocator) };
}

fn initSqliteDataSource() !DataSource {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = "grocery.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });

    // Create table
    const create_table_sql =
        \\CREATE TABLE IF NOT EXISTS grocery_items (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL UNIQUE,
        \\    unit_price REAL NOT NULL
        \\);
    ;

    try db.exec(create_table_sql, .{}, .{});

    // Insert data from existing grocery_items array (ignore duplicates)
    const insert_sql = "INSERT OR IGNORE INTO grocery_items (name, unit_price) VALUES (?1, ?2)";

    for (grocery_items) |item| {
        try db.exec(insert_sql, .{}, .{ item.name, item.unit_price });
    }

    return DataSource{ .sqlite = db };
}

fn queryItemFromSqlite(app: *App, item_name: []const u8) !?[]const u8 {
    // SQLite implementation disabled due to API compatibility issues
    _ = app;
    _ = item_name;
    return null;
}

pub fn runServer(
    allocator: std.mem.Allocator,
    html: []const u8,
    css_engine: *z.CssSelectorEngine,
    body_node: *z.DomNode,
    use_sqlite: bool, // Configuration to choose data source
) !void {
    // Pre-load all templates at startup
    const preloaded = try preloadTemplates(
        allocator,
        body_node,
        css_engine,
    );

    // Initialize data source based on configuration
    const data_source_type: DataSourceType = if (use_sqlite) .sqlite else .memory;
    const data_source = switch (data_source_type) {
        .memory => initMemoryDataSource(allocator),
        .sqlite => try initSqliteDataSource(),
    };

    var _app = App{
        .initial_html = html,
        .allocator = allocator,
        // .css_engine = css_engine,
        .body_node = body_node,
        .cart = .empty,
        .preloaded_grocery_items_html = preloaded.grocery_items_template, // Raw template, not filled data
        .preloaded_groceries_page_html = preloaded.groceries_page_html,
        .preloaded_shopping_list_html = preloaded.shopping_list_html,
        .preloaded_item_details_default_html = preloaded.item_details_default_html,
        .preloaded_item_details_template = preloaded.item_details_template,
        .preloaded_cart_item_template = preloaded.cart_item_template,
        .data_source_type = data_source_type,
        .data_source = data_source,
    };

    var server = try httpz.Server(*App).init(
        allocator,
        .{ .port = 8080 },
        &_app,
    );
    defer {
        // Cleanup pre-loaded templates
        allocator.free(_app.preloaded_grocery_items_html);
        allocator.free(_app.preloaded_groceries_page_html);
        allocator.free(_app.preloaded_shopping_list_html);
        allocator.free(_app.preloaded_item_details_default_html);
        allocator.free(_app.preloaded_item_details_template);
        allocator.free(_app.preloaded_cart_item_template);

        // Cleanup data source
        switch (_app.data_source) {
            .memory => |*memory_map| {
                memory_map.deinit();
            },
            .sqlite => |*db| {
                db.deinit();
            },
        }

        _app.cart.deinit(allocator);
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/", sendFullPage, .{});
    router.get("/groceries", getGroceryList, .{});
    router.get("/shopping-list", getShoppingList, .{});
    router.get("/api/items", getItems, .{});
    router.get("/api/cart", getCartItems, .{});
    router.get("/item-details/default", getDefaultItemDetails, .{});
    router.get("/api/item-details/:id", getItemDetails, .{});
    router.post("/api/cart/add/:id", addToCart, .{});
    router.delete("/api/cart/remove/:id", removeFromCart, .{});

    // Optimized quantity-only endpoints
    router.post("/api/cart/increase-quantity/:id", increaseQuantityOnly, .{});
    router.post("/api/cart/decrease-quantity/:id", decreaseQuantityOnly, .{});

    try server.listen();
}

fn getItems(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    // Generate HTML using pre-loaded template with runtime data
    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(app.allocator);

    switch (app.data_source) {
        .memory => {
            for (grocery_items) |item| {
                // Use the raw template and substitute data at runtime
                const with_name = try std.mem.replaceOwned(u8, app.allocator, app.preloaded_grocery_items_html, "{name}", item.name);
                defer app.allocator.free(with_name);

                const price_str = try std.fmt.allocPrint(app.allocator, "{d:.2}", .{item.unit_price});
                defer app.allocator.free(price_str);

                const with_price = try std.mem.replaceOwned(u8, app.allocator, with_name, "{price}", price_str);
                defer app.allocator.free(with_price);

                const final_html = try std.mem.replaceOwned(u8, app.allocator, with_price, "{id}", item.name);
                defer app.allocator.free(final_html);

                try items_html.appendSlice(app.allocator, final_html);
            }
        },
        .sqlite => {
            // SQLite implementation disabled due to API compatibility issues
            return error.NotImplemented;
        },
    }

    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    const writer = res.writer();
    try writer.writeAll(items_html.items);
}

fn getGroceryList(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    res.body = app.preloaded_groceries_page_html;
}
fn getDefaultItemDetails(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    res.body = app.preloaded_item_details_default_html;
}

fn getItemDetails(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const item_name = req.param("id") orelse "Unknown";

    const item_html = switch (app.data_source) {
        .memory => blk: {
            // Find item in grocery_items and generate HTML using precomputed template
            const grocery_item = for (grocery_items) |item| {
                if (std.mem.eql(u8, item.name, item_name)) {
                    break item;
                }
            } else {
                break :blk null;
            };

            // Use preloaded template to generate HTML
            const with_name = try std.mem.replaceOwned(u8, app.allocator, app.preloaded_item_details_template, "{name}", grocery_item.name);
            defer app.allocator.free(with_name);

            const price_str = try std.fmt.allocPrint(app.allocator, "{d:.2}", .{grocery_item.unit_price});
            defer app.allocator.free(price_str);

            const with_price = try std.mem.replaceOwned(u8, app.allocator, with_name, "{price}", price_str);
            defer app.allocator.free(with_price);

            const final_html = try std.mem.replaceOwned(u8, app.allocator, with_price, "{id}", grocery_item.name);

            break :blk final_html;
        },
        .sqlite => blk: {
            const result = queryItemFromSqlite(app, item_name) catch null;
            break :blk result;
        },
    };

    if (item_html) |html| {
        res.status = 200;
        res.header("Content-Type", "text/html; charset=utf-8");
        res.body = html;

        // Free generated HTML for both memory and SQLite modes
        defer app.allocator.free(html);
    } else {
        res.status = 404;
        res.header("Content-Type", "text/html; charset=utf-8");
        res.body = "<div class=\"text-center text-red-500\"><h3>Item not found</h3></div>";
    }
}

fn getShoppingList(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    res.body = app.preloaded_shopping_list_html;
}

// Stack buffer approach: calculate size and use bufPrint + writeAll
fn replaceTemplateToWriter(
    writer: anytype,
    template: []const u8,
    name: []const u8,
    price: f32,
    quantity: u32,
) !void {
    // Stack-allocated buffers for formatting values
    var price_buf: [32]u8 = undefined;
    var quantity_buf: [16]u8 = undefined;

    const price_str = try std.fmt.bufPrint(&price_buf, "{d:.2}", .{price});
    const quantity_str = try std.fmt.bufPrint(&quantity_buf, "{d}", .{quantity});

    // Calculate buffer size needed using template slice length (known at runtime)
    const template_len = template.len; // Slice already knows its length!
    const replacement_len = name.len * 7 + price_str.len + quantity_str.len; // 7 name instances + price + quantity
    const placeholder_len = 9 * 2; // 9 "{}" placeholders
    const needed_buffer_size = template_len + replacement_len - placeholder_len;

    // Use reasonable buffer size based on typical template sizes
    // Cart template is ~1KB, so 2KB should handle all realistic cases
    const max_buffer_size = 2048;
    var output_buf: [max_buffer_size]u8 = undefined;

    if (needed_buffer_size > max_buffer_size) {
        return writer.print("Error: template too large for buffer", .{});
    }

    // Need to convert {} to proper Zig format specifiers first, or use manual replacement
    // For now, let's do manual replacement with stack buffer
    const values = [_][]const u8{ name, price_str, name, name, name, quantity_str, name, name, name };

    var result_len: usize = 0;
    var value_index: usize = 0;
    var i: usize = 0;

    while (i + 1 < template.len) {
        if (template[i] == '{' and template[i + 1] == '}') {
            if (value_index < values.len) {
                const value = values[value_index];
                @memcpy(output_buf[result_len..result_len + value.len], value);
                result_len += value.len;
                value_index += 1;
            }
            i += 2;
        } else {
            output_buf[result_len] = template[i];
            result_len += 1;
            i += 1;
        }
    }

    // Copy remaining template
    while (i < template.len) {
        output_buf[result_len] = template[i];
        result_len += 1;
        i += 1;
    }

    const result = output_buf[0..result_len];

    // Single writeAll call
    try writer.writeAll(result);
}

fn getCartItems(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    // std.debug.print("Cart items requested!\n", .{});

    if (app.cart.items.len == 0) {
        res.status = 200;
        res.header("Content-Type", "text/html; charset=utf-8");
        const writer = res.writer();
        try writer.writeAll("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>");
        return;
    }

    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    const writer = res.writer();

    // Render each cart item using template replacement (fixed version)
    for (app.cart.items) |cart_item| {
        try replaceTemplateToWriter(
            writer,
            app.preloaded_cart_item_template,
            cart_item.name,
            cart_item.price,
            cart_item.quantity,
        );
    }
}

fn addToCart(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const item_name = req.param("id") orelse return;
    // std.debug.print("Adding to cart: {s}\n", .{item_name});

    // Find the item in grocery list to get price
    const grocery_item = for (grocery_items) |item| {
        if (std.mem.eql(u8, item.name, item_name)) {
            break item;
        }
    } else {
        res.status = 404;
        return;
    };

    // Check if item already in cart
    for (app.cart.items) |*cart_item| {
        if (std.mem.eql(u8, cart_item.name, item_name)) {
            cart_item.quantity += 1;
            res.status = 200;
            return;
        }
    }

    // Add new item to cart
    try app.cart.append(app.allocator, CartItem{
        .name = grocery_item.name,
        .price = grocery_item.unit_price,
        .quantity = 1,
    });

    res.status = 200;
}

fn removeFromCart(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const item_name = req.param("id") orelse return;

    for (app.cart.items, 0..) |cart_item, i| {
        if (std.mem.eql(u8, cart_item.name, item_name)) {
            _ = app.cart.orderedRemove(i);
            break;
        }
    }

    // Return updated cart content
    try getCartItems(app, req, res);
}

pub fn sendFullPage(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.header("Content-Type", "text/html; charset=utf-8");
    res.body = app.initial_html;
}

// Optimized quantity-only endpoints - return just the quantity number
fn increaseQuantityOnly(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const item_name = req.param("id") orelse return;

    for (app.cart.items) |*cart_item| {
        if (std.mem.eql(u8, cart_item.name, item_name)) {
            cart_item.quantity += 1;

            // Return just the quantity number
            res.status = 200;
            res.header("Content-Type", "text/html; charset=utf-8");
            const writer = res.writer();
            try writer.print("{d}", .{cart_item.quantity});
            return;
        }
    }

    // Item not found - return current quantity (shouldn't happen)
    res.status = 404;
}

fn decreaseQuantityOnly(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const item_name = req.param("id") orelse return;

    for (app.cart.items, 0..) |*cart_item, i| {
        if (std.mem.eql(u8, cart_item.name, item_name)) {
            if (cart_item.quantity > 1) {
                cart_item.quantity -= 1;

                // Return just the quantity number
                res.status = 200;
                res.header("Content-Type", "text/html; charset=utf-8");
                const writer = res.writer();
                try writer.print("{d}", .{cart_item.quantity});
                return;
            } else {
                // Remove item if quantity becomes 0
                _ = app.cart.orderedRemove(i);

                // For zero quantity, we need to trigger full cart refresh
                // by returning an HTMX response that refreshes the whole cart
                res.status = 200;
                res.header("Content-Type", "text/html; charset=utf-8");
                res.header("HX-Trigger", "refresh-cart");
                const writer = res.writer();
                try writer.writeAll("0");
                return;
            }
        }
    }

    // Item not found
    res.status = 404;
}
