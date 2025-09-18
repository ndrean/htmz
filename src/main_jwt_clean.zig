const std = @import("std");
const builtin = @import("builtin");
const zap = @import("zap");
const jwt = @import("jwt.zig");
const database = @import("database.zig");
const cart_manager = @import("cart_manager.zig");
const templates = @import("templates.zig");

// Grocery items are now loaded from database instead of hardcoded

// Application Context - replaces global variables
const AppContext = struct {
    allocator: std.mem.Allocator,
    database: *database.Database,
    cart_manager: *cart_manager.CartManager,

    pub fn init(allocator: std.mem.Allocator) !AppContext {
        // Heap allocation needed because cart_manager needs mutable reference to database
        const db = try allocator.create(database.Database);
        // used .Memory for simplicity, so path is userless in fact
        db.* = try database.Database.init(allocator, "htmz.sql3");

        const cm = try allocator.create(cart_manager.CartManager);
        cm.* = try cart_manager.CartManager.init(allocator, db);

        return AppContext{
            .allocator = allocator,
            .database = db,
            .cart_manager = cm,
        };
    }

    pub fn deinit(self: *AppContext) void {
        self.cart_manager.deinit();
        self.database.deinit();
        self.allocator.destroy(self.cart_manager);
        self.allocator.destroy(self.database);
    }
};

// Cart action enum
const CartAction = enum { add, increase, decrease, remove };

// Note: Using sendFile for HTML and CSS to leverage automatic compression

// JWT Helper Functions
fn getCookieToken(r: zap.Request, ctx: *AppContext) ?[]const u8 {
    r.parseCookies(false);

    const cookie_result = r.getCookieStr(ctx.allocator, "jwt_token") catch {
        return null;
    };
    defer if (cookie_result) |cookie| ctx.allocator.free(cookie);

    if (cookie_result) |cookie| {
        return ctx.allocator.dupe(u8, cookie) catch null;
    }

    return null;
}

// JWT validation - returns payload if valid, null if invalid/missing
fn validateJWT(r: zap.Request, ctx: *AppContext) ?jwt.JWTPayload {
    if (getCookieToken(r, ctx)) |token| {
        defer ctx.allocator.free(token);
        if (jwt.verifyJWT(ctx.allocator, token)) |payload| {
            return payload;
        } else |_| {
            // JWT verification failed
            return null;
        }
    }
    return null; // No JWT cookie found
}

// JWT validation for protected routes - returns payload or sends redirect
fn validateJWTOrRedirect(r: zap.Request, ctx: *AppContext) ?jwt.JWTPayload {
    if (validateJWT(r, ctx)) |payload| {
        return payload;
    } else {
        // Invalid/missing JWT - redirect to home page
        r.setStatus(.found); // 302 redirect
        r.setHeader("Location", "/") catch {};
        return null;
    }
}

// Create new JWT - ONLY used in sendFullPage for GET /
fn createNewJWTUser(ctx: *AppContext) !jwt.JWTPayload {
    const user_id = try std.fmt.allocPrint(
        ctx.allocator,
        "user_{d}_{d}",
        .{ std.time.timestamp(), std.crypto.random.int(u32) },
    );

    return jwt.JWTPayload{
        .user_id = user_id,
        .exp = std.time.timestamp() + 3600, // 1 hour expiry
    };
}

// Main request handler with context and early return style
fn onRequest(r: zap.Request, ctx: *AppContext) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // Public routes (no JWT required)
    if (std.mem.eql(u8, path, "/") and method == .GET) {
        sendFullPage(r, ctx);
        return;
    }

    if (std.mem.eql(u8, path, "/index.css") and method == .GET) {
        r.setStatus(.ok);
        r.setHeader("Content-Type", "text/css") catch return;
        r.setHeader("Cache-Control", "public, max-age=3600") catch return;
        r.sendFile("src/html/index.css") catch return;
        return;
    }

    if (std.mem.eql(u8, path, "/groceries") and method == .GET) {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody(templates.groceries_page_html) catch return;
        return;
    }

    if (std.mem.eql(u8, path, "/shopping-list") and method == .GET) {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody(templates.shopping_list_page_html) catch return;
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/item-details/") and method == .GET) {
        handleItemDetails(r, ctx);
        return;
    }

    if (std.mem.eql(u8, path, "/item-details/default") and method == .GET) {
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody(templates.item_details_default_html) catch return;
        return;
    }

    // Protected routes - JWT validation required
    const payload = validateJWTOrRedirect(r, ctx) orelse return;
    defer jwt.deinitPayload(ctx.allocator, payload);

    if (std.mem.eql(u8, path, "/api/items") and method == .GET) {
        handleItemsList(
            r,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.eql(u8, path, "/api/cart") and method == .GET) {
        handleCartDisplay(
            r,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/cart/add/") and method == .POST) {
        handleCartOperation(
            r,
            .add,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/") and method == .POST) {
        handleCartOperation(
            r,
            .increase,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/") and method == .POST) {
        handleCartOperation(
            r,
            .decrease,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.startsWith(u8, path, "/api/cart/remove/") and method == .DELETE) {
        handleCartOperation(
            r,
            .remove,
            ctx,
            payload,
        );
        return;
    }

    if (std.mem.eql(u8, path, "/cart-count") and method == .GET) {
        handleCartCount(r, ctx, payload);
        return;
    }

    if (std.mem.eql(u8, path, "/cart-total") and method == .GET) {
        handleCartTotal(r, ctx, payload);
        return;
    }

    // Default 404
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

// Route handler functions
fn sendFullPage(r: zap.Request, ctx: *AppContext) void {
    // Only create/set JWT if user doesn't have valid one
    if (validateJWT(r, ctx)) |payload| {
        defer jwt.deinitPayload(ctx.allocator, payload);
        // User already has valid session - just serve the page
    } else {
        // No valid JWT - create new session
        const payload = createNewJWTUser(ctx) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer jwt.deinitPayload(ctx.allocator, payload);

        const token = jwt.generateJWT(ctx.allocator, payload) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer ctx.allocator.free(token);

        // Set JWT in cookie only (headers are useless for HTMX)
        r.setCookie(.{
            .http_only = true,
            .path = "/",
            .name = "jwt_token",
            .value = token,
            .same_site = .Lax,
            .max_age_s = 3600,
        }) catch {};
    }

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    // Use sendFile for automatic compression via facil.io
    r.sendFile("src/html/index.html") catch return;
}

fn handleCartOperation(r: zap.Request, action: CartAction, ctx: *AppContext, payload: jwt.JWTPayload) void {
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

    switch (action) {
        .add => {
            ctx.cart_manager.addToCart(payload.user_id, item_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .increase => {
            ctx.cart_manager.increaseQuantity(payload.user_id, item_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .decrease => {
            ctx.cart_manager.decreaseQuantity(payload.user_id, item_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        },
        .remove => {
            ctx.cart_manager.removeFromCart(payload.user_id, item_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        },
    }

    r.setStatus(.ok);

    // Trigger cart count update for all actions
    r.setHeader("HX-Trigger", "updateCartCount") catch {};

    if (action == .increase or action == .decrease or action == .remove) {
        // For quantity updates, we need to check if item still exists and return appropriate response
        const cart_items = ctx.cart_manager.getCart(ctx.allocator, payload.user_id) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer {
            for (cart_items) |item| {
                ctx.allocator.free(item.name);
            }
            ctx.allocator.free(cart_items);
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

fn generateCartHTMLFromDB(user_id: []const u8, ctx: *AppContext) ![]u8 {
    const cart_items = ctx.cart_manager.getCart(ctx.allocator, user_id) catch {
        return try ctx.allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Error loading cart.</p>");
    };
    defer {
        for (cart_items) |item| {
            ctx.allocator.free(item.name);
        }
        ctx.allocator.free(cart_items);
    }

    if (cart_items.len == 0) {
        return try ctx.allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Your cart is empty.</p>");
    }

    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(ctx.allocator);

    for (cart_items) |item| {
        // COMMENTED: Using templates.zig for comparison
        const item_html = try std.fmt.allocPrint(ctx.allocator, templates.cart_item_template, .{ item.id, item.name, item.price, item.id, item.id, item.id, item.quantity, item.id, item.id, item.id, item.id });
        defer ctx.allocator.free(item_html);
        try cart_html.appendSlice(ctx.allocator, item_html);
    }

    return try cart_html.toOwnedSlice(ctx.allocator);
}

fn handleCartDisplay(r: zap.Request, ctx: *AppContext, payload: jwt.JWTPayload) void {
    const cart_html = generateCartHTMLFromDB(payload.user_id, ctx) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer ctx.allocator.free(cart_html);

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;
    r.sendBody(cart_html) catch return;
}

fn handleItemDetails(r: zap.Request, ctx: *AppContext) void {
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
    const grocery_item_opt = ctx.database.getGroceryItem(ctx.allocator, item_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    const grocery_item = grocery_item_opt orelse {
        r.setStatus(.not_found);
        return;
    };
    defer ctx.allocator.free(grocery_item.name);

    // COMMENTED: Using templates.zig for comparison
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

fn handleCartCount(r: zap.Request, ctx: *AppContext, payload: jwt.JWTPayload) void {
    const count = ctx.cart_manager.getCartCount(payload.user_id) catch {
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

fn handleItemsList(r: zap.Request, ctx: *AppContext, payload: jwt.JWTPayload) void {
    _ = payload; // Not used in this handler but required for consistency
    const items = ctx.database.getAllGroceryItems(ctx.allocator) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer {
        for (items) |item| {
            ctx.allocator.free(item.name);
        }
        ctx.allocator.free(items);
    }

    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;

    // Use allocator for template rendering
    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(ctx.allocator);

    for (items) |item| {
        // COMMENTED: Using templates.zig for comparison
        const item_html = std.fmt.allocPrint(ctx.allocator, templates.grocery_item_template, .{ item.id, item.name, item.price, item.id }) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer ctx.allocator.free(item_html);
        items_html.appendSlice(ctx.allocator, item_html) catch {
            r.setStatus(.internal_server_error);
            return;
        };
    }

    r.sendBody(items_html.items) catch return;
}

fn handleCartTotal(r: zap.Request, ctx: *AppContext, payload: jwt.JWTPayload) void {
    const total = ctx.cart_manager.getCartTotal(ctx.allocator, payload.user_id) catch {
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

// Global context for the Zap handler callback
var app_context: *AppContext = undefined;

// Wrapper for onRequest to pass context
fn onRequestWrapper(r: zap.Request) !void {
    try onRequest(r, app_context);
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
        const allocator = switch (builtin.mode) {
            .Debug, .ReleaseSafe => gpa.allocator(),
            .ReleaseFast, .ReleaseSmall => std.heap.c_allocator,
        };

        // Initialize application context
        const ctx = try allocator.create(AppContext);
        ctx.* = try AppContext.init(allocator);
        defer {
            ctx.deinit();
            allocator.destroy(ctx);
        }

        // Set global context for Zap callback
        app_context = ctx;

        // Initialize Zap HTTP listener
        var listener = zap.HttpListener.init(.{
            .port = 8080,
            .on_request = onRequestWrapper,
            .log = false,
        });
        try listener.listen();

        std.log.info("Server started on http://127.0.0.1:8080", .{});
        zap.start(.{ .threads = 1, .workers = 1 });
    }
    const leaks = gpa.detectLeaks();
    std.debug.print("Leaks detected?: {}\n", .{leaks});
}
