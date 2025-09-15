//! JWT-based stateless HTTP server implementation
const std = @import("std");
pub const z = @import("zexplorer");
const grocery_items = @import("grocery_items.zig").grocery_list;
const GroceryItem = @import("grocery_items.zig").GroceryItem;
const jwt = @import("jwt.zig");
const zap = @import("zap");

// Global app context for request handling
var global_app: *App = undefined;

const App = struct {
    initial_html: []const u8,
    allocator: std.mem.Allocator,
    body_node: *z.DomNode,

    // Pre-loaded templates
    preloaded_grocery_items_html: []const u8,
    preloaded_groceries_page_html: []const u8,
    preloaded_shopping_list_html: []const u8,
    preloaded_item_details_default_html: []const u8,
    preloaded_item_details_template: []const u8,
    preloaded_cart_item_template: []const u8,
};

// JWT Helper Functions
fn getBearerToken(r: zap.Request) ?[]const u8 {
    const auth_header = r.getHeader("authorization") orelse return null;
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) return null;
    return auth_header[7..]; // Skip "Bearer "
}

fn getOrCreateJWTCart(r: zap.Request, app: *App) !jwt.JWTPayload {
    if (getBearerToken(r)) |token| {
        // Try to verify existing JWT
        if (jwt.verifyJWT(app.allocator, token)) |payload| {
            return payload;
        } else |_| {
            // Invalid/expired token, create new one
        }
    }

    // Create new empty cart
    const user_id = try std.fmt.allocPrint(app.allocator, "user_{d}_{d}", .{
        std.time.timestamp(),
        std.crypto.random.int(u32)
    });

    return jwt.JWTPayload{
        .user_id = user_id,
        .cart = &[_]jwt.CartItem{}, // Empty cart
        .exp = std.time.timestamp() + 3600, // 1 hour expiry
    };
}

fn updateCartInJWT(allocator: std.mem.Allocator, payload: jwt.JWTPayload, item_id: u32, action: enum { add, increase, decrease, remove }) !jwt.JWTPayload {
    // Find grocery item
    const grocery_item = if (item_id < grocery_items.len) grocery_items[item_id] else return error.ItemNotFound;

    // Clone cart array
    var new_cart = std.ArrayList(jwt.CartItem).init(allocator);
    defer new_cart.deinit();

    var found = false;
    for (payload.cart) |cart_item| {
        if (cart_item.id == item_id) {
            found = true;
            switch (action) {
                .add, .increase => try new_cart.append(.{
                    .id = item_id,
                    .name = grocery_item.name,
                    .quantity = cart_item.quantity + 1,
                    .price = grocery_item.unit_price,
                }),
                .decrease => {
                    if (cart_item.quantity > 1) {
                        try new_cart.append(.{
                            .id = item_id,
                            .name = grocery_item.name,
                            .quantity = cart_item.quantity - 1,
                            .price = grocery_item.unit_price,
                        });
                    }
                    // If quantity becomes 0, don't add to new cart (removes item)
                },
                .remove => {
                    // Don't add to new cart (removes item)
                },
            }
        } else {
            try new_cart.append(cart_item);
        }
    }

    // If item not found and action is add, add new item
    if (!found and action == .add) {
        try new_cart.append(.{
            .id = item_id,
            .name = grocery_item.name,
            .quantity = 1,
            .price = grocery_item.unit_price,
        });
    }

    return jwt.JWTPayload{
        .user_id = payload.user_id,
        .cart = try new_cart.toOwnedSlice(),
        .exp = std.time.timestamp() + 3600, // Refresh expiry
    };
}

// Route Handlers
fn sendFullPage(r: zap.Request, app: *App) void {
    // Generate initial JWT for new users
    const payload = getOrCreateJWTCart(r, app) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    const token = jwt.generateJWT(app.allocator, payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(token);

    // Set JWT as cookie or header
    r.setHeader("X-JWT-Token", token) catch {};

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(app.initial_html) catch return;
}

fn addToCartJWT(r: zap.Request, app: *App) void {
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

    // Get current cart from JWT
    const current_payload = getOrCreateJWTCart(r, app) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    // Update cart
    const new_payload = updateCartInJWT(app.allocator, current_payload, item_id, .add) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_payload.cart);

    // Generate new JWT
    const new_token = jwt.generateJWT(app.allocator, new_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_token);

    // Return new JWT token in header
    r.setHeader("X-JWT-Token", new_token) catch {};
    r.setStatus(.ok);
}

fn increaseQuantityJWT(r: zap.Request, app: *App) void {
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

    // Get current cart from JWT
    const current_payload = getOrCreateJWTCart(r, app) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    // Update cart
    const new_payload = updateCartInJWT(app.allocator, current_payload, item_id, .increase) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_payload.cart);

    // Find new quantity to return
    var new_quantity: u32 = 0;
    for (new_payload.cart) |cart_item| {
        if (cart_item.id == item_id) {
            new_quantity = cart_item.quantity;
            break;
        }
    }

    // Generate new JWT
    const new_token = jwt.generateJWT(app.allocator, new_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_token);

    // Return new JWT token and quantity
    r.setHeader("X-JWT-Token", new_token) catch {};

    var quantity_buf: [16]u8 = undefined;
    const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{new_quantity}) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(quantity_str) catch return;
}

fn decreaseQuantityJWT(r: zap.Request, app: *App) void {
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

    // Get current cart from JWT
    const current_payload = getOrCreateJWTCart(r, app) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    // Update cart
    const new_payload = updateCartInJWT(app.allocator, current_payload, item_id, .decrease) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_payload.cart);

    // Find new quantity to return
    var new_quantity: u32 = 0;
    for (new_payload.cart) |cart_item| {
        if (cart_item.id == item_id) {
            new_quantity = cart_item.quantity;
            break;
        }
    }

    // Generate new JWT
    const new_token = jwt.generateJWT(app.allocator, new_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_token);

    // Return new JWT token and quantity
    r.setHeader("X-JWT-Token", new_token) catch {};

    var quantity_buf: [16]u8 = undefined;
    const quantity_str = std.fmt.bufPrint(&quantity_buf, "{d}", .{new_quantity}) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(quantity_str) catch return;
}

fn removeFromCartJWT(r: zap.Request, app: *App) void {
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

    // Get current cart from JWT
    const current_payload = getOrCreateJWTCart(r, app) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    // Update cart
    const new_payload = updateCartInJWT(app.allocator, current_payload, item_id, .remove) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_payload.cart);

    // Generate new JWT
    const new_token = jwt.generateJWT(app.allocator, new_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer app.allocator.free(new_token);

    // Return new JWT token
    r.setHeader("X-JWT-Token", new_token) catch {};
    r.setStatus(.ok);
}

// Main request handler
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
    } else if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
        if (method == .POST) {
            addToCartJWT(r, global_app);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
        if (method == .POST) {
            increaseQuantityJWT(r, global_app);
            return;
        }
    }
    // Add more routes as needed...

    // Default 404 response
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

pub fn runServer(
    allocator: std.mem.Allocator,
    initial_html: []const u8,
    css_engine: *z.CssSelectorEngine,
    body_node: *z.DomNode,
    use_sqlite: bool,
) !void {
    _ = css_engine;
    _ = use_sqlite;

    // Initialize App context (no more HashMap!)
    var app = App{
        .initial_html = initial_html,
        .allocator = allocator,
        .body_node = body_node,
        .preloaded_grocery_items_html = "",
        .preloaded_groceries_page_html = "",
        .preloaded_shopping_list_html = "",
        .preloaded_item_details_default_html = "",
        .preloaded_item_details_template = "",
        .preloaded_cart_item_template = "",
    };

    // Store app context globally for the request handler
    global_app = &app;

    // Initialize Zap HTTP listener
    var listener = zap.HttpListener.init(.{
        .port = 8081, // Different port for JWT version
        .on_request = on_request,
        .log = false,
    });
    try listener.listen();

    std.log.info("Starting JWT-based server on http://127.0.0.1:8081", .{});
    zap.start(.{ .threads = 2, .workers = 2 });
}