const std = @import("std");
const zap = @import("zap");
const jwt = @import("jwt.zig");
const database = @import("database.zig");
const cart_manager = @import("cart_manager.zig");
const templates = @import("templates.zig");

// Grocery items are now loaded from database instead of hardcoded

// Global allocator, database manager and cart manager
var global_allocator: std.mem.Allocator = undefined;
var global_database: database.Database = undefined;
var global_cart_manager: cart_manager.CartManager = undefined;

// Cart action enum
const CartAction = enum { add, increase, decrease, remove };

// Note: Using sendFile for HTML and CSS to leverage automatic compression

// JWT Helper Functions
fn getCookieToken(r: zap.Request) ?[]const u8 {
    r.parseCookies(false);

    const cookie_result = r.getCookieStr(global_allocator, "jwt_token") catch {
        return null;
    };
    defer if (cookie_result) |cookie| global_allocator.free(cookie);

    if (cookie_result) |cookie| {
        return global_allocator.dupe(u8, cookie) catch null;
    }

    return null;
}

// JWT validation - returns payload if valid, null if invalid/missing
fn validateJWT(r: zap.Request) ?jwt.JWTPayload {
    if (getCookieToken(r)) |token| {
        defer global_allocator.free(token);
        if (jwt.verifyJWT(global_allocator, token)) |payload| {
            return payload;
        } else |_| {
            // JWT verification failed
            return null;
        }
    }
    return null; // No JWT cookie found
}

// Create new JWT - ONLY used in sendFullPage for GET /
fn createNewJWTUser() !jwt.JWTPayload {
    const user_id = try std.fmt.allocPrint(global_allocator, "user_{d}_{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) });
    // std.debug.print("DEBUG: Created NEW user_id: {s}\n", .{user_id});

    return jwt.JWTPayload{
        .user_id = user_id,
        .exp = std.time.timestamp() + 3600, // 1 hour expiry
    };
}

// Get or create JWT - ONLY used in sendFullPage
fn getOrCreateJWTForHomePage(r: zap.Request) !jwt.JWTPayload {
    if (validateJWT(r)) |payload| {
        // std.debug.print("DEBUG: Using existing user_id: {s}\n", .{payload.user_id});
        return payload;
    } else {
        return createNewJWTUser();
    }
}

// Main request handler
fn onRequest(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();
    // std.debug.print("REQUEST: {s} {s}\n", .{ @tagName(method), path });

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
            handleItemsList(r);
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
    } else if (std.mem.eql(u8, path, "/cart-count")) {
        if (method == .GET) {
            handleCartCount(r);
            return;
        }
    } else if (std.mem.eql(u8, path, "/cart-total")) {
        if (method == .GET) {
            handleCartTotal(r);
            return;
        }
    }

    // Default 404
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

// Route handler functions
fn sendFullPage(r: zap.Request) void {
    const payload = getOrCreateJWTForHomePage(r) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer jwt.deinitPayload(global_allocator, payload);

    const token = jwt.generateJWT(global_allocator, payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer global_allocator.free(token);

    // std.debug.print("Generated JWT: {s}\n", .{token});

    // Set JWT in cookie only (headers are useless for HTMX)
    r.setCookie(.{
        .http_only = true,
        .path = "/",
        .name = "jwt_token",
        .value = token,
        .same_site = .Lax,
        .max_age_s = 3600,
    }) catch {};

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

    // Get grocery item from database
    const main_db = global_cart_manager.getMainDatabase();
    const grocery_item_opt = main_db.getGroceryItem(global_allocator, item_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    const grocery_item = grocery_item_opt orelse {
        r.setStatus(.not_found);
        return;
    };
    defer global_allocator.free(grocery_item.name);

    // Validate JWT - redirect to / if missing/invalid
    const payload = validateJWT(r) orelse {
        r.setStatus(.found); // 302 redirect
        r.setHeader("Location", "/") catch {};
        return;
    };
    defer jwt.deinitPayload(global_allocator, payload);

    // JWT is already validated, no need to set cookie again

    // Perform database operation
    // std.debug.print("CART OP: {s} action for item_id {d} ({s})\n", .{ @tagName(action), item_id, grocery_item.name });

    switch (action) {
        .add => {
            global_cart_manager.addToCart(payload.user_id, item_id) catch {
                // std.debug.print("CART OP ERROR: {}\n", .{err});
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .increase => {
            global_cart_manager.increaseQuantity(payload.user_id, item_id) catch {
                // std.debug.print("CART OP ERROR: {}\n", .{err});
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .decrease => {
            global_cart_manager.decreaseQuantity(payload.user_id, item_id) catch {
                // std.debug.print("CART OP ERROR: {}\n", .{err});
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .remove => {
            global_cart_manager.removeFromCart(payload.user_id, item_id) catch {

                // std.debug.print("CART OP ERROR: {}\n", .{err});
                r.setStatus(.internal_server_error);
                return;
            };
        },
    }

    // std.debug.print("CART OP: Success\n", .{});

    r.setStatus(.ok);

    // Trigger cart count update for all actions
    r.setHeader("HX-Trigger", "updateCartCount") catch {};

    if (action == .increase or action == .decrease or action == .remove) {
        // For quantity updates, we need to check if item still exists and return appropriate response
        const cart_items = global_cart_manager.getCart(global_allocator, payload.user_id) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer {
            for (cart_items) |item| {
                global_allocator.free(item.name);
            }
            global_allocator.free(cart_items);
        }

        // Find the item to see its new quantity
        var found_quantity: ?u32 = null;
        for (cart_items) |cart_item| {
            if (cart_item.id == item_id) {
                found_quantity = cart_item.quantity;
                break;
            }
        }

        if (found_quantity == null) {
            // Item was removed - retarget to entire item and return empty response
            r.setContentType(.HTML) catch return;
            var retarget_buf: [32]u8 = undefined;
            const retarget_str = std.fmt.bufPrint(&retarget_buf, "#cart-item-{d}", .{item_id}) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            r.setHeader("HX-Retarget", retarget_str) catch {};
            r.setHeader("HX-Reswap", "outerHTML") catch {};
            r.setHeader("HX-Trigger", "cartUpdate") catch {};
            r.sendBody("") catch return;
        } else {
            // Return updated quantity
            var quantity_buf: [16]u8 = undefined;
            const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{found_quantity.?}) catch {
                r.setStatus(.internal_server_error);
                return;
            };

            r.setContentType(.HTML) catch return;
            r.sendBody(quantity_str) catch return;
        }
    }
}

fn generateCartHTMLFromDB(user_id: []const u8) ![]u8 {
    const cart_items = global_cart_manager.getCart(global_allocator, user_id) catch {
        return try global_allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Error loading cart.</p>");
    };
    defer {
        for (cart_items) |item| {
            global_allocator.free(item.name);
        }
        global_allocator.free(cart_items);
    }

    if (cart_items.len == 0) {
        return try global_allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Your cart is empty.</p>");
    }

    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(global_allocator);

    for (cart_items) |item| {
        const item_html = try std.fmt.allocPrint(global_allocator, templates.cart_item_template, .{ item.id, item.name, item.price, item.id, item.id, item.id, item.quantity, item.id, item.id, item.id, item.id });
        defer global_allocator.free(item_html);
        try cart_html.appendSlice(global_allocator, item_html);
    }

    return try cart_html.toOwnedSlice(global_allocator);
}

fn handleCartDisplay(r: zap.Request) void {
    const payload = validateJWT(r) orelse {
        r.setStatus(.found); // 302 redirect
        r.setHeader("Location", "/") catch {};
        return;
    };
    defer jwt.deinitPayload(global_allocator, payload);

    const cart_html = generateCartHTMLFromDB(payload.user_id) catch {
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

    // Get grocery item from database
    const main_db = global_cart_manager.getMainDatabase();
    const grocery_item_opt = main_db.getGroceryItem(global_allocator, item_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    const grocery_item = grocery_item_opt orelse {
        r.setStatus(.not_found);
        return;
    };
    defer global_allocator.free(grocery_item.name);

    // Use stack buffer - item details template ~800 bytes max
    var details_buffer: [1024]u8 = undefined;
    const item_html = std.fmt.bufPrint(&details_buffer, templates.item_details_template, .{ grocery_item.name, grocery_item.price, item_id }) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(item_html) catch return;
}

fn handleCartCount(r: zap.Request) void {
    const payload = validateJWT(r) orelse {
        r.setStatus(.found); // 302 redirect
        r.setHeader("Location", "/") catch {};
        return;
    };
    defer jwt.deinitPayload(global_allocator, payload);

    const count = global_cart_manager.getCartCount(payload.user_id) catch {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody("0") catch return;
        return;
    };

    var count_buf: [16]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(count_str) catch return;
}

fn handleItemsList(r: zap.Request) void {
    const main_db = global_cart_manager.getMainDatabase();
    const items = main_db.getAllGroceryItems(global_allocator) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer {
        for (items) |item| {
            global_allocator.free(item.name);
        }
        global_allocator.free(items);
    }

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;

    // Use allocator for template rendering
    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(global_allocator);

    for (items) |item| {
        const item_html = std.fmt.allocPrint(global_allocator, templates.grocery_item_template, .{ item.id, item.name, item.price, item.id }) catch {
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
}

fn handleCartTotal(r: zap.Request) void {
    const payload = validateJWT(r) orelse {
        r.setStatus(.found); // 302 redirect
        r.setHeader("Location", "/") catch {};
        return;
    };
    defer jwt.deinitPayload(global_allocator, payload);

    const total = global_cart_manager.getCartTotal(global_allocator, payload.user_id) catch {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody("0.00") catch return;
        return;
    };

    var total_buf: [32]u8 = undefined;
    const total_str = std.fmt.bufPrint(&total_buf, "${d:.2}", .{total}) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(total_str) catch return;
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
        // global_allocator = gpa.allocator();
        global_allocator = std.heap.c_allocator; // Use C allocator for simplicity in this example

        // Initialize SQLite database and cart manager
        global_database = database.Database.init(global_allocator, "htmz.sql3") catch |err| {
            std.log.err("Failed to initialize database: {}", .{err});
            return;
        };
        defer global_database.deinit();

        global_cart_manager = cart_manager.CartManager.init(global_allocator, &global_database) catch |err| {
            std.log.err("Failed to initialize cart manager: {}", .{err});
            return;
        };
        defer global_cart_manager.deinit();

        // Initialize Zap HTTP listener
        var listener = zap.HttpListener.init(.{
            .port = 8080,
            .on_request = onRequest,
            .log = false,
        });
        try listener.listen();

        std.log.info("Server started on http://127.0.0.1:8080", .{});
        zap.start(.{ .threads = 1, .workers = 1 });
    }
    const leaks = gpa.detectLeaks();
    std.debug.print("Leaks detected?: {}\n", .{leaks});
}
