//! New ZZZ-based HTTP server implementation
const std = @import("std");
pub const z = @import("zexplorer");
const sqlite = @import("sqlite");
const grocery_items = @import("grocery_items.zig").grocery_list;
const GroceryItem = @import("grocery_items.zig").GroceryItem;

const zap = @import("zap");

// Global app context for request handling
var global_app: *App = undefined;

// URL decode function to handle %20 -> space, etc.
fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            // Parse hex characters
            const hex_str = encoded[i + 1 .. i + 3];
            if (std.fmt.parseInt(u8, hex_str, 16)) |byte_val| {
                try decoded.append(allocator, byte_val);
                i += 3;
            } else |_| {
                // Invalid hex, treat as literal %
                try decoded.append(allocator, encoded[i]);
                i += 1;
            }
        } else if (encoded[i] == '+') {
            // + is also a space in URL encoding
            try decoded.append(allocator, ' ');
            i += 1;
        } else {
            try decoded.append(allocator, encoded[i]);
            i += 1;
        }
    }

    return decoded.toOwnedSlice(allocator);
}

// Data abstraction layer - works for both memory and SQLite
fn getItemById(data_source: DataSource, id: u32) ?GroceryItem {
    switch (data_source) {
        .memory => {
            // In memory mode, ID is the array index
            if (id >= grocery_items.len) return null;
            return grocery_items[id];
        },
        .sqlite => |_| {
            // In SQLite mode, ID would be the database primary key
            // For now, fallback to memory behavior until SQLite is implemented
            if (id >= grocery_items.len) return null;
            return grocery_items[id];
        },
    }
}

fn findItemIdByName(name: []const u8) ?u32 {
    // Helper function to find ID by name (useful for internal lookups)
    for (grocery_items, 0..) |item, index| {
        if (std.mem.eql(u8, item.name, name)) {
            return @as(u32, @intCast(index));
        }
    }
    return null;
}

// Session management functions
fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    // Simple session ID: timestamp + random number
    const timestamp = std.time.timestamp();
    const random = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "sess_{d}_{d}", .{ timestamp, random });
}

fn getSessionId(r: zap.Request) ?[]const u8 {
    // Try to get session ID from cookie first, then from X-Session-Id header
    if (r.getCookieStr(global_app.allocator, "session_id") catch null) |cookie_value| {
        return cookie_value;
    }

    // Fallback to custom header (for load testing)
    if (r.getHeader("x-session-id")) |header_value| {
        return header_value;
    }

    return null;
}

fn getOrCreateSessionCart(app: *App, session_id: []const u8) !*std.ArrayList(CartItem) {
    // Check if session already has a cart
    if (app.session_carts.getPtr(session_id)) |cart_ptr| {
        return cart_ptr;
    }

    // Create new cart for this session
    const new_cart: std.ArrayList(CartItem) = .empty;

    // Copy the session_id string to ensure it persists
    const owned_session_id = try app.allocator.dupe(u8, session_id);
    try app.session_carts.put(owned_session_id, new_cart);

    // Return pointer to the cart in the map
    return app.session_carts.getPtr(owned_session_id).?;
}

pub fn bPrint(i: usize) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("Run `zig build test` to run the tests: {d}\n", .{i});
    try stdout.flush();
}

const CartItem = struct {
    item_id: u32,
    name: []const u8, // Keep name for display purposes
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
    body_node: *z.DomNode,
    session_carts: std.StringHashMap(std.ArrayList(CartItem)), // session_id -> cart

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

pub fn runServer(
    allocator: std.mem.Allocator,
    initial_html: []const u8,
    css_engine: *z.CssSelectorEngine,
    body_node: *z.DomNode,
    use_sqlite: bool,
) !void {
    // std.debug.print("Starting Zap-based HTTP server...\n", .{});

    // Preload templates
    const preloaded = try preloadTemplates(
        allocator,
        body_node,
        css_engine,
    );

    // Initialize data source
    const data_source_type: DataSourceType = if (use_sqlite) .sqlite else .memory;
    const data_source: DataSource = switch (data_source_type) {
        .memory => .{
            .memory = std.StringHashMap([]const u8).init(allocator),
        },
        .sqlite => blk: {
            const db = try sqlite.Db.init(.{
                // .mode = .{ .File = "cart.db" },
                .mode = .Memory,
                .open_flags = .{
                    .write = true,
                    .create = true,
                },
            });
            break :blk .{ .sqlite = db };
        },
    };

    // Initialize App context
    var app = App{
        .initial_html = initial_html,
        .allocator = allocator,
        .body_node = body_node,

        .session_carts = std.StringHashMap(std.ArrayList(CartItem)).init(allocator),

        .preloaded_grocery_items_html = preloaded.grocery_items_template,
        .preloaded_groceries_page_html = preloaded.groceries_page_html,
        .preloaded_shopping_list_html = preloaded.shopping_list_html,
        .preloaded_item_details_default_html = preloaded.item_details_default_html,
        .preloaded_item_details_template = preloaded.item_details_template,
        .preloaded_cart_item_template = preloaded.cart_item_template,
        .data_source_type = data_source_type,
        .data_source = data_source,
    };
    defer {
        // Clean up all session carts
        var cart_iterator = app.session_carts.iterator();
        while (cart_iterator.next()) |entry| {
            // Free the allocated session ID key
            allocator.free(entry.key_ptr.*);
            // Free the cart ArrayList
            entry.value_ptr.deinit(allocator);
        }
        app.session_carts.deinit();
    }

    // Store app context globally for the request handler
    global_app = &app;

    // Initialize Zap HTTP listener
    var listener = zap.HttpListener.init(.{
        .port = 8080,
        .on_request = on_request,
        .log = false,
    });
    try listener.listen();

    // std.log.info("Starting Zap server on http://127.0.0.1:8080", .{});
    zap.start(.{ .threads = 2, .workers = 2 });
}

/// extract all the raw templates from the initial HTML
fn preloadTemplates(allocator: std.mem.Allocator, body_node: *z.DomNode, _: *z.CssSelectorEngine) !struct {
    grocery_items_template: []const u8,
    groceries_page_html: []const u8,
    shopping_list_html: []const u8,
    item_details_default_html: []const u8,
    item_details_template: []const u8,
    cart_item_template: []const u8,
} {
    const doc = z.ownerDocument(body_node);
    const item_template = try z.querySelector(allocator, doc, "#grocery-item-template");
    const grocery_item_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(item_template.?));

    const groceries_template = try z.querySelector(allocator, doc, "#groceries-page-template");
    const groceries_html = try z.innerTemplateHTML(allocator, z.elementToNode(groceries_template.?));

    const shopping_template = try z.querySelector(allocator, doc, "#shopping-list-template");
    const shopping_html = try z.innerTemplateHTML(allocator, z.elementToNode(shopping_template.?));

    const default_template = try z.querySelector(allocator, doc, "#item-details-default-template");
    const default_html = try z.innerTemplateHTML(allocator, z.elementToNode(default_template.?));

    const details_template = try z.querySelector(allocator, doc, "#item-details-template");
    const details_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(details_template.?));

    const cart_item_template = try z.querySelector(allocator, doc, "#cart-item-template");
    const cart_item_template_html = try z.innerTemplateHTML(allocator, z.elementToNode(cart_item_template.?));

    return .{
        .grocery_items_template = grocery_item_template_html,
        .groceries_page_html = groceries_html,
        .shopping_list_html = shopping_html,
        .item_details_default_html = default_html,
        .item_details_template = details_template_html,
        .cart_item_template = cart_item_template_html,
    };
}

/// Stack buffer template interpolation
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
    const template_len = template.len;
    const replacement_len = name.len * 7 + price_str.len + quantity_str.len;
    const placeholder_len = 9 * 2; // 9 "{}" placeholders
    const needed_buffer_size = template_len + replacement_len - placeholder_len;

    // Use reasonable buffer size based on typical template sizes
    const max_buffer_size = 2048;
    var output_buf: [max_buffer_size]u8 = undefined;

    if (needed_buffer_size > max_buffer_size) {
        return writer.print("Error: template too large for buffer", .{});
    }

    // Manual replacement with stack buffer
    const values = [_][]const u8{ name, price_str, name, name, name, quantity_str, name, name, name };

    var result_len: usize = 0;
    var value_index: usize = 0;
    var i: usize = 0;

    while (i + 1 < template.len) {
        if (template[i] == '{' and template[i + 1] == '}') {
            if (value_index < values.len) {
                const value = values[value_index];
                @memcpy(output_buf[result_len .. result_len + value.len], value);
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

// Helper function to ensure session exists, redirect to "/" if not
fn ensureSession(r: zap.Request) bool {
    const session_id = getSessionId(r);
    if (session_id != null) {
        return true; // Session exists
    }

    // No session, redirect to root
    r.setStatus(.found); // 302 redirect
    r.setHeader("Location", "/") catch return false;
    return false;
}

// Zap Handler Functions
fn sendFullPage(r: zap.Request, app: *App) void {
    // Check if session already exists
    var session_id = getSessionId(r);

    if (session_id == null) {
        // Generate new session ID for first-time users
        const new_session_id = generateSessionId(app.allocator) catch {
            r.setStatus(.internal_server_error);
            return;
        };

        // Set session cookie (expires in 24 hours)
        const cookie_header = std.fmt.allocPrint(app.allocator,
            "session_id={s}; HttpOnly; Path=/; Max-Age=86400", .{new_session_id}) catch {
            app.allocator.free(new_session_id);
            r.setStatus(.internal_server_error);
            return;
        };
        defer app.allocator.free(cookie_header);

        r.setHeader("Set-Cookie", cookie_header) catch return;
        session_id = new_session_id;
    }

    // Initialize empty cart for this session (if not exists)
    _ = getOrCreateSessionCart(app, session_id.?) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(app.initial_html) catch return;
}

fn getGroceriesPage(r: zap.Request, app: *App) void {
    // Ensure session exists, redirect to "/" if not
    if (!ensureSession(r)) return;

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(app.preloaded_groceries_page_html) catch return;
}

fn getShoppingListPage(r: zap.Request, app: *App) void {
    // Ensure session exists, redirect to "/" if not
    if (!ensureSession(r)) return;

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(app.preloaded_shopping_list_html) catch return;
}

fn getItemDetailsDefault(r: zap.Request, app: *App) void {
    // Ensure session exists, redirect to "/" if not
    if (!ensureSession(r)) return;

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(app.preloaded_item_details_default_html) catch return;
}

fn getGroceryItems(r: zap.Request, app: *App) void {
    // Ensure session exists, redirect to "/" if not
    if (!ensureSession(r)) return;

    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(app.allocator);

    const writer = items_html.writer(app.allocator);

    // Generate grocery items using ID-based URLs
    for (grocery_items, 0..) |item, index| {
        const item_id = @as(u32, @intCast(index));
        writer.print(
            \\<div class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer">
            \\<div><span class="text-lg font-semibold text-gray-900">{s}</span><span class="text-sm text-gray-500 ml-2">${d:.2}</span></div>
            \\<button class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button>
            \\</div>
        , .{ item.name, item.unit_price, item_id }) catch {
            r.setStatus(.internal_server_error);
            return;
        };
    }

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(items_html.items) catch return;
}

fn getCartItems(r: zap.Request, app: *App) void {
    // Get or create session cart
    const session_id = getSessionId(r) orelse blk: {
        // Generate new session ID if none exists
        const new_session_id = generateSessionId(app.allocator) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        // Set as cookie in response
        r.setCookie(.{
            .name = "session_id",
            .value = new_session_id,
            .http_only = true,
            .max_age_s = 3600, // 1 hour
        }) catch {};
        break :blk new_session_id;
    };

    const session_cart = getOrCreateSessionCart(app, session_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    if (session_cart.items.len == 0) {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>") catch return;
        return;
    }

    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(app.allocator);

    const writer = cart_html.writer(app.allocator);

    // Render each cart item using the optimized template replacement
    for (session_cart.items) |cart_item| {
        replaceTemplateToWriter(
            writer,
            app.preloaded_cart_item_template,
            cart_item.name,
            cart_item.price,
            cart_item.quantity,
        ) catch {
            r.setStatus(.internal_server_error);
            return;
        };
    }

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(cart_html.items) catch return;
}

fn getItemDetails(r: zap.Request, app: *App) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/item-details/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_name_encoded = path[prefix.len..];
    const item_name = urlDecode(app.allocator, item_name_encoded) catch {
        r.setStatus(.bad_request);
        return;
    };
    defer app.allocator.free(item_name);

    // Find the item in grocery_items
    for (grocery_items) |item| {
        if (std.mem.eql(u8, item.name, item_name)) {
            var details_html: std.ArrayList(u8) = .empty;
            defer details_html.deinit(app.allocator);

            const writer = details_html.writer(app.allocator);
            writer.print(
                \\<div class="text-center">
                \\<h3 class="text-2xl font-bold text-gray-800 mb-4">{s}</h3>
                \\<div class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center">
                \\<svg class="w-12 h-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                \\<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"></path>
                \\</svg>
                \\</div>
                \\<div class="bg-blue-50 rounded-lg p-6 mb-6">
                \\<p class="text-3xl font-bold text-blue-600">${d:.2}</p>
                \\<p class="text-gray-600 mt-2">per unit</p>
                \\</div>
                \\<div class="space-y-3">
                \\<button class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold" hx-post="/api/cart/add/{s}" hx-swap="none">Add to Cart</button>
                \\</div>
                \\</div>
            , .{ item.name, item.unit_price, item.name }) catch {
                r.setStatus(.internal_server_error);
                return;
            };

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(details_html.items) catch return;
            return;
        }
    }

    r.setStatus(.not_found);
}

fn addToCart(r: zap.Request, app: *App) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/cart/add/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    // Find grocery item using data abstraction layer
    const grocery_item = getItemById(app.data_source, item_id) orelse {
        r.setStatus(.not_found);
        return;
    };

    // Get or create session cart
    const session_id = getSessionId(r) orelse blk: {
        // Generate new session ID if none exists
        const new_session_id = generateSessionId(app.allocator) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        // Set as cookie in response
        r.setCookie(.{
            .name = "session_id",
            .value = new_session_id,
            .http_only = true,
            .max_age_s = 3600, // 1 hour
        }) catch {};
        break :blk new_session_id;
    };

    const session_cart = getOrCreateSessionCart(app, session_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    // Check if item already in cart
    for (session_cart.items) |*cart_item| {
        if (cart_item.item_id == item_id) {
            cart_item.quantity += 1;
            r.setStatus(.ok);
            return;
        }
    }

    // Add new item to cart
    session_cart.append(app.allocator, CartItem{
        .item_id = item_id,
        .name = grocery_item.name,
        .price = grocery_item.unit_price,
        .quantity = 1,
    }) catch {
        r.setStatus(.internal_server_error);
        return;
    };


    r.setStatus(.ok);
}

fn increaseQuantityOnly(r: zap.Request, app: *App) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/cart/increase-quantity/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    // Validate that the item_id exists
    if (getItemById(app.data_source, item_id) == null) {
        r.setStatus(.not_found);
        return;
    }

    // Get session cart
    const session_id = getSessionId(r) orelse {
        r.setStatus(.bad_request); // No session means no cart
        return;
    };

    const session_cart = getOrCreateSessionCart(app, session_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };


    for (session_cart.items) |*cart_item| {
        if (cart_item.item_id == item_id) {
            cart_item.quantity += 1;

            // Return just the quantity number
            var quantity_buf: [16]u8 = undefined;
            const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{cart_item.quantity}) catch {
                r.setStatus(.internal_server_error);
                return;
            };

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(quantity_str) catch return;
            return;
        }
    }

    r.setStatus(.not_found);
}

fn decreaseQuantityOnly(r: zap.Request, app: *App) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/cart/decrease-quantity/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    // Validate that the item_id exists
    if (getItemById(app.data_source, item_id) == null) {
        r.setStatus(.not_found);
        return;
    }

    // Get session cart
    const session_id = getSessionId(r) orelse {
        r.setStatus(.bad_request); // No session means no cart
        return;
    };

    const session_cart = getOrCreateSessionCart(app, session_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    for (session_cart.items, 0..) |*cart_item, i| {
        if (cart_item.item_id == item_id) {
            if (cart_item.quantity > 1) {
                cart_item.quantity -= 1;

                // Return just the quantity number
                var quantity_buf: [16]u8 = undefined;
                const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{cart_item.quantity}) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };

                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody(quantity_str) catch return;
                return;
            } else {
                // Remove item if quantity becomes 0
                _ = session_cart.orderedRemove(i);

                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("0") catch return;
                return;
            }
        }
    }

    r.setStatus(.not_found);
}

fn removeFromCart(r: zap.Request, app: *App) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/cart/remove/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    // Validate that the item_id exists
    if (getItemById(app.data_source, item_id) == null) {
        r.setStatus(.not_found);
        return;
    }

    // Get session cart
    const session_id = getSessionId(r) orelse {
        r.setStatus(.bad_request); // No session means no cart
        return;
    };

    const session_cart = getOrCreateSessionCart(app, session_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    for (session_cart.items, 0..) |cart_item, i| {
        if (cart_item.item_id == item_id) {
            _ = session_cart.orderedRemove(i);
            break;
        }
    }

    // Return updated cart content by calling getCartItems
    getCartItems(r, app);
}

// Main request handler function that routes requests to appropriate handlers
fn on_request(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // Route handling
    if (std.mem.eql(u8, path, "/")) {
        if (method == .GET) {
            sendFullPage(r, global_app);
            return;
        }
    } else if (std.mem.eql(u8, path, "/groceries")) {
        if (method == .GET) {
            getGroceriesPage(r, global_app);
            return;
        }
    } else if (std.mem.eql(u8, path, "/shopping-list")) {
        if (method == .GET) {
            getShoppingListPage(r, global_app);
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/items")) {
        if (method == .GET) {
            getGroceryItems(r, global_app);
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/cart")) {
        if (method == .GET) {
            getCartItems(r, global_app);
            return;
        }
    } else if (std.mem.eql(u8, path, "/item-details/default")) {
        if (method == .GET) {
            getItemDetailsDefault(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/item-details/")) {
        if (method == .GET) {
            getItemDetails(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
        if (method == .POST) {
            addToCart(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
        if (method == .POST) {
            increaseQuantityOnly(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/")) {
        if (method == .POST) {
            decreaseQuantityOnly(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/remove/")) {
        if (method == .DELETE) {
            removeFromCart(r, global_app);
            return;
        }
    }

    // Default 404 response
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}
