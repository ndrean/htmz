const std = @import("std");
const builtin = @import("builtin");
const zap = @import("zap");
const jwt = @import("jwt.zig");
const database = @import("database.zig");
const cart_manager = @import("cart_manager.zig");
const templates = @import("templates.zig");

/// Application Context. Owns database and cart manager
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

// ===== ENDPOINTS =====
// Each endpoint receives AppContext for DB and Cart access
// Each request gets its own endpoint instance and
// memory allocation and resource management is contained per request

/// Home Endpoint - handles homepage and JWT creation
pub const HomeEndpoint = struct {
    app_context: *AppContext,
    path: []const u8 = "/",
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    pub fn init(ctx: *AppContext) HomeEndpoint {
        return HomeEndpoint{ .app_context = ctx };
    }

    pub fn get(self: *HomeEndpoint, r: zap.Request) !void {
        // Only create/set JWT if user doesn't have valid one
        if (validateJWT(r, self.app_context)) |payload| {
            defer jwt.deinitPayload(self.app_context.allocator, payload);
            // User already has valid session - just serve the page
        } else {
            // No valid JWT - create new session
            const payload = createNewJWTUser(self.app_context) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer jwt.deinitPayload(self.app_context.allocator, payload);

            const token = jwt.generateJWT(self.app_context.allocator, payload) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer self.app_context.allocator.free(token);

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
        // Use sendFile: facil.io sends gz if exists
        r.sendFile("src/html/index.html") catch return;
    }
};

/// Public Pages Endpoint - handles template pages and item details
pub const PagesEndpoint = struct {
    app_context: *AppContext,
    path: []const u8 = "/groceries",
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    pub fn init(ctx: *AppContext) PagesEndpoint {
        return PagesEndpoint{ .app_context = ctx };
    }

    pub fn get(self: *PagesEndpoint, r: zap.Request) !void {
        const path = r.path orelse {
            r.setStatus(.bad_request);
            return;
        };

        if (std.mem.eql(u8, path, "/groceries")) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.groceries_page_html) catch return;
            return;
        }

        if (std.mem.eql(u8, path, "/shopping-list")) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.shopping_list_page_html) catch return;
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/item-details/")) {
            self.handleItemDetails(r);
            return;
        }

        if (std.mem.eql(u8, path, "/item-details/default")) {
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(templates.item_details_default_html) catch return;
            return;
        }

        r.setStatus(.not_found);
    }

    fn handleItemDetails(self: *PagesEndpoint, r: zap.Request) void {
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
        const grocery_item_opt = self.app_context.database.getGroceryItem(self.app_context.allocator, item_id) catch {
            r.setStatus(.internal_server_error);
            return;
        };

        const grocery_item = grocery_item_opt orelse {
            r.setStatus(.not_found);
            return;
        };
        defer self.app_context.allocator.free(grocery_item.name);

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
};

/// Cart Endpoint - handles all cart operations (JWT protected)
pub const CartEndpoint = struct {
    app_context: *AppContext,
    path: []const u8 = "/api/cart",
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    pub fn init(ctx: *AppContext) CartEndpoint {
        return CartEndpoint{ .app_context = ctx };
    }

    pub fn get(self: *CartEndpoint, r: zap.Request) !void {
        const payload = validateJWTOrRedirect(r, self.app_context) orelse return;
        defer jwt.deinitPayload(self.app_context.allocator, payload);

        const cart_html = self.generateCartHTMLFromDB(payload.user_id) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer self.app_context.allocator.free(cart_html);

        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody(cart_html) catch return;
    }

    pub fn post(self: *CartEndpoint, r: zap.Request) !void {
        const payload = validateJWTOrRedirect(r, self.app_context) orelse return;
        defer jwt.deinitPayload(self.app_context.allocator, payload);

        const path = r.path orelse {
            r.setStatus(.bad_request);
            return;
        };

        // Route cart operations based on path
        if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
            self.handleCartOperation(r, .add, payload);
        } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
            self.handleCartOperation(r, .increase, payload);
        } else if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/")) {
            self.handleCartOperation(r, .decrease, payload);
        } else {
            r.setStatus(.not_found);
        }
    }

    pub fn delete(self: *CartEndpoint, r: zap.Request) !void {
        const payload = validateJWTOrRedirect(r, self.app_context) orelse return;
        defer jwt.deinitPayload(self.app_context.allocator, payload);

        const path = r.path orelse {
            r.setStatus(.bad_request);
            return;
        };

        if (std.mem.startsWith(u8, path, "/api/cart/remove/")) {
            self.handleCartOperation(r, .remove, payload);
        } else {
            r.setStatus(.not_found);
        }
    }

    fn handleCartOperation(self: *CartEndpoint, r: zap.Request, action: CartAction, payload: jwt.JWTPayload) void {
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
                self.app_context.cart_manager.addToCart(payload.user_id, item_id) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            },
            .increase => {
                self.app_context.cart_manager.increaseQuantity(payload.user_id, item_id) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            },
            .decrease => {
                self.app_context.cart_manager.decreaseQuantity(payload.user_id, item_id) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            },
            .remove => {
                self.app_context.cart_manager.removeFromCart(payload.user_id, item_id) catch {
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
            const cart_items = self.app_context.cart_manager.getCart(self.app_context.allocator, payload.user_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer {
                for (cart_items) |item| {
                    self.app_context.allocator.free(item.name);
                }
                self.app_context.allocator.free(cart_items);
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

    fn generateCartHTMLFromDB(self: *CartEndpoint, user_id: []const u8) ![]u8 {
        const cart_items = self.app_context.cart_manager.getCart(self.app_context.allocator, user_id) catch {
            return try self.app_context.allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Error loading cart.</p>");
        };
        defer {
            for (cart_items) |item| {
                self.app_context.allocator.free(item.name);
            }
            self.app_context.allocator.free(cart_items);
        }

        if (cart_items.len == 0) {
            return try self.app_context.allocator.dupe(u8, "<p class=\"text-gray-600 text-center\">Your cart is empty.</p>");
        }

        var cart_html: std.ArrayList(u8) = .empty;
        defer cart_html.deinit(self.app_context.allocator);

        for (cart_items) |item| {
            const item_html = try std.fmt.allocPrint(self.app_context.allocator, templates.cart_item_template, .{ item.id, item.name, item.price, item.id, item.id, item.id, item.quantity, item.id, item.id, item.id, item.id });
            defer self.app_context.allocator.free(item_html);
            try cart_html.appendSlice(self.app_context.allocator, item_html);
        }

        return try cart_html.toOwnedSlice(self.app_context.allocator);
    }
};

// Items Endpoint - handles grocery items list (JWT protected)
pub const ItemsEndpoint = struct {
    app_context: *AppContext,
    path: []const u8 = "/api/items",
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    pub fn init(ctx: *AppContext) ItemsEndpoint {
        return ItemsEndpoint{ .app_context = ctx };
    }

    pub fn get(self: *ItemsEndpoint, r: zap.Request) !void {
        const payload = validateJWTOrRedirect(r, self.app_context) orelse return;
        defer jwt.deinitPayload(self.app_context.allocator, payload);

        const items = self.app_context.database.getAllGroceryItems(self.app_context.allocator) catch {
            r.setStatus(.internal_server_error);
            return;
        };
        defer {
            for (items) |item| {
                self.app_context.allocator.free(item.name);
            }
            self.app_context.allocator.free(items);
        }

        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;

        // Use allocator for template rendering
        var items_html: std.ArrayList(u8) = .empty;
        defer items_html.deinit(self.app_context.allocator);

        for (items) |item| {
            const item_html = std.fmt.allocPrint(self.app_context.allocator, templates.grocery_item_template, .{ item.id, item.name, item.price, item.id }) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer self.app_context.allocator.free(item_html);
            items_html.appendSlice(self.app_context.allocator, item_html) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        }

        r.sendBody(items_html.items) catch return;
    }
};

// Cart Stats Endpoint - handles cart count and total (JWT protected)
pub const CartStatsEndpoint = struct {
    app_context: *AppContext,
    path: []const u8 = "/cart-count",
    error_strategy: zap.Endpoint.ErrorStrategy = .log_to_response,

    pub fn init(ctx: *AppContext) CartStatsEndpoint {
        return CartStatsEndpoint{ .app_context = ctx };
    }

    pub fn get(self: *CartStatsEndpoint, r: zap.Request) !void {
        const payload = validateJWTOrRedirect(r, self.app_context) orelse return;
        defer jwt.deinitPayload(self.app_context.allocator, payload);

        const path = r.path orelse {
            r.setStatus(.bad_request);
            return;
        };

        if (std.mem.eql(u8, path, "/cart-count")) {
            const count = self.app_context.cart_manager.getCartCount(payload.user_id) catch {
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
        } else if (std.mem.eql(u8, path, "/cart-total")) {
            const total = self.app_context.cart_manager.getCartTotal(self.app_context.allocator, payload.user_id) catch {
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
        } else {
            r.setStatus(.not_found);
        }
    }
};

// Global context for the Zap handler callback
var app_context: *AppContext = undefined;

// Simple handler that uses endpoints
fn simpleHandler(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // Route to endpoints
    if (std.mem.eql(u8, path, "/") and method == .GET) {
        var home_endpoint = HomeEndpoint.init(app_context);
        try home_endpoint.get(r);
        return;
    }

    if (std.mem.eql(u8, path, "/index.css") and method == .GET) {
        // var static_endpoint = CssEndpoint.init(app_context);
        // try static_endpoint.get(r);
        // return;
        r.setStatus(.ok);
        r.setHeader("Content-Type", "text/css") catch return;
        r.setHeader("Cache-Control", "public, max-age=3600") catch return;
        r.sendFile("src/html/index.css") catch return;
        return;
    }
    if (std.mem.eql(u8, path, "/htmx.min.js") and method == .GET) {
        r.setStatus(.ok);
        r.setHeader("Content-Type", "application/javascript") catch return;
        r.setHeader("Cache-Control", "public, max-age=3600") catch return;
        r.sendFile("src/html/htmx.min.js") catch return;
        return;
    }
    if (std.mem.eql(u8, path, "/ws.min.js") and method == .GET) {
        r.setStatus(.ok);
        r.setHeader("Content-Type", "application/javascript") catch return;
        r.setHeader("Cache-Control", "public, max-age=3600") catch return;
        r.sendFile("src/html/ws.min.js") catch return;
        return;
    }

    // Pages routes
    if ((std.mem.eql(u8, path, "/groceries") or
        std.mem.eql(u8, path, "/shopping-list") or
        std.mem.eql(u8, path, "/item-details/default") or
        std.mem.startsWith(u8, path, "/api/item-details/")) and method == .GET)
    {
        var pages_endpoint = PagesEndpoint.init(app_context);
        try pages_endpoint.get(r);
        return;
    }

    // Items API routes
    if (std.mem.eql(u8, path, "/api/items") and method == .GET) {
        var items_endpoint = ItemsEndpoint.init(app_context);
        try items_endpoint.get(r);
        return;
    }

    // JWT protected routes below-------------------
    // Cart routes
    if (std.mem.startsWith(u8, path, "/api/cart")) {
        var cart_endpoint = CartEndpoint.init(app_context);
        if (method == .GET) {
            try cart_endpoint.get(r);
        } else if (method == .POST) {
            try cart_endpoint.post(r);
        } else if (method == .DELETE) {
            try cart_endpoint.delete(r);
        }
        return;
    }

    // Cart stats routes
    if ((std.mem.eql(u8, path, "/cart-count") or std.mem.eql(u8, path, "/cart-total")) and method == .GET) {
        var cart_stats_endpoint = CartStatsEndpoint.init(app_context);
        try cart_stats_endpoint.get(r);

        return;
    }

    // Default 404
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
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

        // For now, let's use the simple HttpListener until we fix the endpoint path conflicts
        var listener = zap.HttpListener.init(.{
            .port = 8080,
            .on_request = simpleHandler,
            .log = false,
            .public_folder = "html",
        });

        // Store context for handler access
        app_context = ctx;

        try listener.listen();

        std.log.info("Server started on http://127.0.0.1:8080", .{});
        zap.start(.{ .threads = 2, .workers = 1 });
    }
    const leaks = gpa.detectLeaks();
    std.debug.print("Leaks detected?: {}\n", .{leaks});
}
