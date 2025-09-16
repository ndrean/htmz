const std = @import("std");
const zap = @import("zap");
const jwt = @import("jwt.zig");
// const index = @import("index.zig");
const templates = @import("templates.zig");

// Hardcoded templates for simple interpolation
// const grocery_item_template =
//     \\<div class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer" hx-get="/api/item-details/{d}" hx-target="#item-details-card" hx-swap="innerHTML"><div><span class="text-lg font-semibold text-gray-900">{s}</span><span class="text-sm text-gray-500 ml-2">${d:.2}</span></div><button class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
// ;

// const cart_item_template =
//     \\<div class="flex justify-between items-center p-4 border-b"><div><span class="font-semibold">{s}</span><br><span class="text-sm text-gray-500">${d:.2}</span></div><div class="flex items-center space-x-2"><button class="px-2 py-1 bg-red-500 text-white rounded" hx-post="/api/cart/decrease-quantity/{d}" hx-target="#qty-{d}" hx-swap="innerHTML">-</button><span id="qty-{d}" class="px-3 py-1 bg-gray-100 rounded">{d}</span><button class="px-2 py-1 bg-green-500 text-white rounded" hx-post="/api/cart/increase-quantity/{d}" hx-target="#qty-{d}" hx-swap="innerHTML">+</button><button class="px-2 py-1 bg-red-600 text-white rounded ml-2" hx-delete="/api/cart/remove/{d}" hx-target="#cart-content" hx-swap="innerHTML">Remove</button></div></div>
// ;

// const item_details_template =
//     \\<div class="text-center"><h3 class="text-2xl font-bold text-gray-800 mb-4">{s}</h3><div class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center"><svg class="w-12 h-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"></path></svg></div><div class="bg-blue-50 rounded-lg p-6 mb-6"><p class="text-3xl font-bold text-blue-600">${d:.2}</p><p class="text-gray-600 mt-2">per unit</p></div><button class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
// ;

// // HTML response constants
// const groceries_page_html =
//     \\<div class="flex flex-col md:flex-row gap-8 p-4"><div class="md:w-1/2"><h2 class="text-3xl font-bold text-gray-800 mb-6">Grocery Items</h2><div class="space-y-4 max-h-[400px] overflow-y-auto pr-2" hx-get="/api/items" hx-trigger="load, every 60s" hx-target="this" hx-swap="innerHTML"><p class="text-gray-500">Loading items...</p></div></div><div id="item-details-card" class="md:w-1/2 bg-gray-100 rounded-xl p-6 shadow-lg min-h-[300px] flex items-center justify-center transition-all duration-300" hx-get="/item-details/default" hx-trigger="load" hx-target="this" hx-swap="innerHTML"></div></div>
// ;

// const shopping_list_page_html =
//     \\<div class="flex flex-col items-center"><h2 class="text-3xl font-bold text-gray-800 mb-6">Shopping List</h2><div id="cart-content" class="w-full max-w-xl bg-white rounded-lg p-6 shadow-md max-h-[500px] overflow-y-auto" hx-get="/api/cart" hx-trigger="load, every 30s" hx-target="this" hx-swap="innerHTML"><p class="text-gray-600 text-center">Your cart is empty.</p></div></div>
// ;

// const item_details_default_html =
//     \\<div class="text-center text-gray-500"><h3 class="text-xl font-semibold mb-4">Select an item</h3><p class="text-gray-400">Click on a grocery item to view its details here.</p></div>
// ;

// Simple grocery items data
const items = [_]struct { name: []const u8, price: f32 }{
    .{ .name = "Apples", .price = 2.99 },
    .{ .name = "Bananas", .price = 1.99 },
    .{ .name = "Bread", .price = 3.49 },
    .{ .name = "Milk", .price = 4.99 },
    .{ .name = "Eggs", .price = 3.99 },
    .{ .name = "Cheese", .price = 5.49 },
    .{ .name = "Chicken", .price = 8.99 },
    .{ .name = "Rice", .price = 2.49 },
};

// Global allocator
var global_allocator: std.mem.Allocator = undefined;

// Cart action enum
const CartAction = enum { add, increase, decrease, remove };

// Note: Using sendFile for HTML and CSS to leverage automatic compression

// JWT Helper Functions
fn getBearerToken(r: zap.Request) ?[]const u8 {
    // Get JWT from cookie (both k6 and browser use cookies)
    if (r.getHeader("cookie")) |cookie_header| {
        var cookies = std.mem.splitSequence(u8, cookie_header, ";");
        while (cookies.next()) |cookie| {
            const trimmed = std.mem.trim(u8, cookie, " ");
            if (std.mem.startsWith(u8, trimmed, "jwt_token=")) {
                return trimmed["jwt_token=".len..];
            }
        }
    }

    return null;
}

fn getOrCreateJWTCart(r: zap.Request) !jwt.JWTPayload {
    if (getBearerToken(r)) |token| {
        // Try to verify existing JWT
        if (jwt.verifyJWT(global_allocator, token)) |payload| {
            return payload;
        } else |_| {
            // Invalid/expired token, create new one
        }
    }

    // Create new empty cart
    const user_id = try std.fmt.allocPrint(global_allocator, "user_{d}_{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) });

    return jwt.JWTPayload{
        .user_id = user_id,
        .cart = &[_]jwt.CartItem{}, // Empty cart
        .exp = std.time.timestamp() + 3600, // 1 hour expiry
    };
}

fn updateCartInJWT(payload: jwt.JWTPayload, item_id: u32, action: CartAction) !jwt.JWTPayload {
    // Validate item_id
    if (item_id >= items.len) return error.ItemNotFound;
    const grocery_item = items[item_id];

    // Clone cart array
    var new_cart: std.ArrayList(jwt.CartItem) = .empty;
    defer new_cart.deinit(global_allocator);

    var found = false;
    for (payload.cart) |cart_item| {
        if (cart_item.id == item_id) {
            found = true;
            switch (action) {
                .add, .increase => try new_cart.append(global_allocator, .{
                    .id = item_id,
                    .name = grocery_item.name,
                    .quantity = cart_item.quantity + 1,
                    .price = grocery_item.price,
                }),
                .decrease => {
                    if (cart_item.quantity > 1) {
                        try new_cart.append(global_allocator, .{
                            .id = item_id,
                            .name = grocery_item.name,
                            .quantity = cart_item.quantity - 1,
                            .price = grocery_item.price,
                        });
                    }
                    // If quantity becomes 0, don't add to new cart (removes item)
                },
                .remove => {
                    // Don't add to new cart (removes item)
                },
            }
        } else {
            try new_cart.append(global_allocator, cart_item);
        }
    }

    // Handle cases where item was not found in cart
    if (!found) {
        switch (action) {
            .add, .increase => {
                // Add new item with quantity 1
                try new_cart.append(global_allocator, .{
                    .id = item_id,
                    .name = grocery_item.name,
                    .quantity = 1,
                    .price = grocery_item.price,
                });
            },
            .decrease, .remove => {
                // Can't decrease/remove item that doesn't exist
                return error.ItemNotInCart;
            },
        }
    }

    return jwt.JWTPayload{
        .user_id = payload.user_id,
        .cart = try new_cart.toOwnedSlice(global_allocator),
        .exp = std.time.timestamp() + 3600, // Refresh expiry
    };
}

// Main request handler
fn onRequest(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // JWT-based routing
    if (std.mem.eql(u8, path, "/")) {
        if (method == .GET) {
            sendFullPage(r);
            return;
        }
    } else if (std.mem.eql(u8, path, "/index.css")) {
        if (method == .GET) {
            r.setStatus(.ok);
            r.setHeader("Content-Type", "text/css") catch return;
            r.setHeader("Cache-Control", "public, max-age=3600") catch return;
            // Use sendFile for automatic compression via facil.io
            r.sendFile("src/html/index.css") catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/groceries")) {
        if (method == .GET) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.groceries_page_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/shopping-list")) {
        if (method == .GET) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.shopping_list_page_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/items")) {
        if (method == .GET) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;

            // Use allocator for template rendering
            var items_html: std.ArrayList(u8) = .empty;
            defer items_html.deinit(global_allocator);

            for (items, 0..) |item, i| {
                const item_id = @as(u32, @intCast(i));
                const item_html = std.fmt.allocPrint(global_allocator, templates.grocery_item_template, .{ item_id, item.name, item.price, item_id }) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
                defer global_allocator.free(item_html);
                items_html.appendSlice(global_allocator, item_html) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            }

            r.sendBody(items_html.items) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/cart")) {
        if (method == .GET) {
            handleCartDisplay(r);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
        if (method == .POST) {
            handleCartOperation(r, .add);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, .increase);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, .decrease);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/remove/")) {
        if (method == .DELETE) {
            handleCartOperation(r, .remove);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/item-details/")) {
        if (method == .GET) {
            handleItemDetails(r);
            return;
        }
    } else if (std.mem.eql(u8, path, "/item-details/default")) {
        if (method == .GET) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.item_details_default_html) catch return;
            return;
        }
    }

    // Default 404
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

// Route handler functions
fn sendFullPage(r: zap.Request) void {
    const payload = getOrCreateJWTCart(r) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    // Note: No deinitPayload needed - we use string literals, not heap-allocated strings

    const token = jwt.generateJWT(global_allocator, payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer global_allocator.free(token);

    // Set JWT in cookie only (headers are useless for HTMX)

    const cookie_value = std.fmt.allocPrint(global_allocator, "jwt_token={s}; HttpOnly; Path=/; Max-Age=3600; SameSite=Lax", .{token}) catch {
        return;
    };
    defer global_allocator.free(cookie_value);
    r.setHeader("Set-Cookie", cookie_value) catch {};

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    // Use sendFile for automatic compression via facil.io
    r.sendFile("src/html/index.html") catch return;
}

fn handleCartOperation(r: zap.Request, action: CartAction) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    // Extract item ID from path
    const prefix = switch (action) {
        .add => "/api/cart/add/",
        .increase => "/api/cart/increase-quantity/",
        .decrease => "/api/cart/decrease-quantity/",
        .remove => "/api/cart/remove/",
    };

    if (!std.mem.startsWith(u8, path, prefix)) {
        r.setStatus(.bad_request);
        return;
    }

    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    // Get current JWT payload
    const current_payload = getOrCreateJWTCart(r) catch {
        r.setStatus(.unauthorized);
        return;
    };
    // Note: No deinitPayload needed - we use string literals, not heap-allocated strings

    // Update cart
    const updated_payload = updateCartInJWT(current_payload, item_id, action) catch {
        r.setStatus(.bad_request);
        return;
    };
    // Note: No deinitPayload needed - we use string literals, not heap-allocated strings

    // Generate new JWT
    const new_token = jwt.generateJWT(global_allocator, updated_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer global_allocator.free(new_token);

    // Set updated JWT in cookie only (headers are useless for HTMX)

    const cookie_value = std.fmt.allocPrint(global_allocator, "jwt_token={s}; HttpOnly; Path=/; Max-Age=3600; SameSite=Lax", .{new_token}) catch {
        return;
    };
    defer global_allocator.free(cookie_value);
    r.setHeader("Set-Cookie", cookie_value) catch {};

    r.setStatus(.ok);
    if (action == .increase or action == .decrease or action == .remove) {
        // Find new quantity
        var new_quantity: u32 = 0;
        for (updated_payload.cart) |cart_item| {
            if (cart_item.id == item_id) {
                new_quantity = cart_item.quantity;
                break;
            }
        }

        if (new_quantity == 0) {
            // Item was removed - refresh entire cart instead of showing "0"
            r.setContentType(.HTML) catch return;
            r.setHeader("HX-Retarget", "#cart-content") catch {};
            const cart_html = generateCartHTML(updated_payload) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer global_allocator.free(cart_html);
            r.sendBody(cart_html) catch return;
        } else {
            // Normal quantity update - return just the number
            var quantity_buf: [16]u8 = undefined;
            const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{new_quantity}) catch {
                r.setStatus(.internal_server_error);
                return;
            };

            r.setContentType(.HTML) catch return;
            r.sendBody(quantity_str) catch return;
        }
    }
}

fn generateCartHTML(payload: jwt.JWTPayload) ![]u8 {
    if (payload.cart.len == 0) {
        return try global_allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Your cart is empty.</p>");
    }

    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(global_allocator);

    for (payload.cart) |item| {
        const item_html = try std.fmt.allocPrint(global_allocator, templates.cart_item_template, .{ item.name, item.price, item.id, item.id, item.id, item.quantity, item.id, item.id, item.id });
        defer global_allocator.free(item_html);
        try cart_html.appendSlice(global_allocator, item_html);
    }

    return try cart_html.toOwnedSlice(global_allocator);
}

fn handleCartDisplay(r: zap.Request) void {
    const payload = getOrCreateJWTCart(r) catch {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>") catch return;
        return;
    };
    // Note: No deinitPayload needed - we use string literals, not heap-allocated strings

    const cart_html = generateCartHTML(payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer global_allocator.free(cart_html);

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(cart_html) catch return;
}

fn handleItemDetails(r: zap.Request) void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    const prefix = "/api/item-details/";
    const item_id_str = path[prefix.len..];
    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        r.setStatus(.bad_request);
        return;
    };

    if (item_id >= items.len) {
        r.setStatus(.not_found);
        return;
    }

    const item = items[item_id];

    // Use stack buffer - item details template ~800 bytes max
    var details_buffer: [1024]u8 = undefined;
    const item_html = std.fmt.bufPrint(&details_buffer, templates.item_details_template, .{ item.name, item.price, item_id }) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(item_html) catch return;
}

pub fn main() !void {
    // Setup GPA for memory tracking
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leaks detected!", .{});
        }
    }

    {
        global_allocator = gpa.allocator();
        // global_allocator = std.heap.c_allocator; // Use C allocator for simplicity in this example

        // Initialize Zap HTTP listener
        var listener = zap.HttpListener.init(.{
            .port = 8080,
            .on_request = onRequest,
            .log = false,
        });
        try listener.listen();

        std.log.info("Clean JWT Server started on http://127.0.0.1:8080 with Context pattern", .{});
        zap.start(.{ .threads = 2, .workers = 2 });
    }
    std.debug.print("Leak detected: {}\n", .{gpa.detectLeaks()});
}
