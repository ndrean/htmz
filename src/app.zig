const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const jwt = @import("jwt.zig");
const database = @import("database.zig");
const cart_manager = @import("cart_manager.zig");
const templates = @import("templates.zig");
const ws_httpz = @import("ws_httpz.zig");

// Embed static files at compile time
const static_html = @embedFile("html/index.html.gz");
const static_css = @embedFile("html/index.css.gz");
const static_htmx = @embedFile("html/htmx.min.js.gz");
const static_ws = @embedFile("html/ws.min.js.gz");

/// Application Context. Owns database and cart manager
// Handler struct for httpz server with WebSocket support
const Handler = struct {
    app: *AppContext,

    pub const WebsocketHandler = ws_httpz.WSClient;
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    database: *database.Database,
    cart_manager: *cart_manager.CartManager,

    pub fn init(allocator: std.mem.Allocator) !AppContext {
        // Heap allocation needed because cart_manager needs mutable reference to database
        const db = try allocator.create(database.Database);
        // create database file with 2 connections in pool
        db.* = try database.Database.init(allocator, "htmz.sql3", 2);

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

// JWT Helper Functions for httpz
fn getCookieToken(req: *httpz.Request, allocator: std.mem.Allocator) ?[]const u8 {
    var cookies = req.cookies();
    if (cookies.get("jwt_token")) |token| {
        return allocator.dupe(u8, token) catch null;
    }
    return null;
}

// JWT validation - returns payload if valid, null if invalid/missing
fn validateJWT(req: *httpz.Request, allocator: std.mem.Allocator) ?jwt.JWTPayload {
    if (getCookieToken(req, allocator)) |token| {
        defer allocator.free(token);
        if (jwt.verifyJWT(allocator, token)) |payload| {
            return payload;
        } else |_| {
            // JWT verification failed
            return null;
        }
    }
    return null; // No JWT cookie found
}

// Create new JWT for new users
fn createNewJWTUser(allocator: std.mem.Allocator) !jwt.JWTPayload {
    const user_id = try std.fmt.allocPrint(
        allocator,
        "user_{d}_{d}",
        .{ std.time.timestamp(), std.crypto.random.int(u32) },
    );

    return jwt.JWTPayload{
        .user_id = user_id,
        .exp = std.time.timestamp() + 3600, // 1 hour from now
    };
}

pub fn indexHandler(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Check if user has valid JWT, create one if not
    if (validateJWT(req, res.arena)) |payload| {
        defer jwt.deinitPayload(res.arena, payload);
        // User already has valid session - just serve the page
    } else {
        // No valid JWT - create new session
        const payload = createNewJWTUser(res.arena) catch {
            res.status = 500;
            res.body = "500 - Internal Server Error";
            try res.write();
            return;
        };
        defer jwt.deinitPayload(res.arena, payload);

        const token = jwt.generateJWT(res.arena, payload) catch {
            res.status = 500;
            res.body = "500 - Internal Server Error";
            try res.write();
            return;
        };

        // Set JWT in cookie
        try res.setCookie("jwt_token", token, .{
            .http_only = true,
            .path = "/",
            .same_site = .lax,
            .max_age = 3600,
        });
    }

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.headers.add("content-encoding", "gzip");
    res.body = static_html;
    try res.write();
}

pub fn cssHandler(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.CSS;
    res.headers.add("content-encoding", "gzip");
    res.body = static_css;
    try res.write();
}

pub fn htmxHandler(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.JS;
    res.headers.add("content-encoding", "gzip");
    res.body = static_htmx;
    try res.write();
}

pub fn wsHandler(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.content_type = httpz.ContentType.JS;
    res.headers.add("content-encoding", "gzip");
    res.body = static_ws;
    try res.write();
}

pub fn cartCountHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    // Get cart count from cart manager
    const count = handler.app.cart_manager.getCartCount(user_id) catch 0;

    const count_str = std.fmt.allocPrint(res.arena, "{d}", .{count}) catch {
        res.status = 500;
        res.body = "500 - Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = count_str;
    try res.write();
}

pub fn groceriesHandler(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    // Serve the groceries page template which will load items via HTMX
    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = templates.groceries_page_html;
    try res.write();
}

pub fn apiItemsHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    // Get grocery items from database (using arena - no manual cleanup needed)
    const items = handler.app.database.getAllGroceryItems(res.arena) catch {
        res.status = 500;
        res.body = "500 - Database Error";
        try res.write();
        return;
    };
    // No defer needed - arena handles cleanup automatically

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;

    // Use arena for template rendering
    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(res.arena);

    const writer = items_html.writer(res.arena);
    for (items) |item| {
        std.fmt.format(
            writer,
            templates.grocery_item_template,
            .{ item.id, item.name, item.price, item.id },
        ) catch {
            res.status = 500;
            res.body = "500 - Template Error";
            try res.write();
            return;
        };
    }

    res.body = items_html.items;
    try res.write();
}

pub fn itemDetailsDefaultHandler(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    // Serve default item details with the default SVG
    const default_html = std.fmt.allocPrint(
        res.arena,
        templates.item_details_template,
        .{ "Select an item", templates.default_item_svg, 0.0, 0 },
    ) catch {
        res.status = 500;
        res.body = "500 - Template Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = default_html;
    try res.write();
}

/// retrieve SVG data from database and render item details page
pub fn apiItemDetailsHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get item ID from route parameter
    const item_id_str = req.param("id") orelse {
        res.status = 400;
        res.body = "400 - Missing item ID";
        try res.write();
        return;
    };

    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        res.status = 400;
        res.body = "400 - Invalid item ID";
        try res.write();
        return;
    };

    // Get grocery item from database (using arena - no manual cleanup needed)
    const grocery_item = handler.app.database.getGroceryItem(res.arena, item_id) catch {
        res.status = 500;
        res.body = "500 - Database Error";
        try res.write();
        return;
    } orelse {
        res.status = 404;
        res.body = "404 - Item Not Found";
        try res.write();
        return;
    };
    // No defer needed - arena handles cleanup automatically

    // Load SVG content if available
    const svg_html = if (grocery_item.svg_data) |svg_content| blk: {
        if (svg_content.len == 0) {
            break :blk templates.default_item_svg;
        }
        break :blk svg_content;
    } else templates.default_item_svg;

    // Use res.arena for memory allocation (httpz best practice)
    const item_html = std.fmt.allocPrint(
        res.arena,
        templates.item_details_template,
        .{ grocery_item.name, svg_html, grocery_item.price, item_id },
    ) catch {
        res.status = 500;
        res.body = "500 - Template Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = item_html;
    try res.write();
}

// Shopping cart handler
pub fn cartGetHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    // Get cart items from cart manager (using arena - no manual cleanup needed)
    const cart_items = handler.app.cart_manager.getCart(res.arena, user_id) catch {
        res.status = 500;
        res.body = "500 - Database Error";
        try res.write();
        return;
    };
    // No defer needed - arena handles cleanup automatically

    if (cart_items.len == 0) {
        res.status = 200;
        res.content_type = httpz.ContentType.HTML;
        res.body = "<p class=\"text-gray-600 text-center\">Your cart is empty.</p>";
        try res.write();
        return;
    }

    // Generate cart HTML using template (using arena)
    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(res.arena);

    const writer = cart_html.writer(res.arena);
    for (cart_items) |item| {
        std.fmt.format(
            writer,
            templates.cart_item_template,
            .{ item.id, item.name, item.price, item.id, item.id, item.id, item.quantity, item.id, item.id, item.id, item.id },
        ) catch {
            res.status = 500;
            res.body = "500 - Template Error";
            try res.write();
            return;
        };
    }

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = cart_html.items;
    try res.write();
}

pub fn cartAddHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    const item_id_str = req.param("id") orelse {
        res.status = 400;
        res.body = "400 - Missing item ID";
        try res.write();
        return;
    };

    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        res.status = 400;
        res.body = "400 - Invalid item ID";
        try res.write();
        return;
    };

    // Add item to cart
    handler.app.cart_manager.addToCart(user_id, item_id) catch {
        res.status = 500;
        res.body = "500 - Cart Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.headers.add("HX-Trigger", "updateCartCount, cartUpdate");
    res.body = "";
    try res.write();
}

pub fn cartIncreaseHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    const item_id_str = req.param("id") orelse {
        res.status = 400;
        res.body = "400 - Missing item ID";
        try res.write();
        return;
    };

    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        res.status = 400;
        res.body = "400 - Invalid item ID";
        try res.write();
        return;
    };

    // Increase quantity
    handler.app.cart_manager.increaseQuantity(user_id, item_id) catch {
        res.status = 500;
        res.body = "500 - Cart Error";
        try res.write();
        return;
    };

    // Get updated quantity to return (using arena - no manual cleanup needed)
    const cart_items = handler.app.cart_manager.getCart(res.arena, user_id) catch {
        res.status = 500;
        res.body = "500 - Database Error";
        try res.write();
        return;
    };
    // No defer needed - arena handles cleanup automatically

    // Find the item to return its quantity
    for (cart_items) |cart_item| {
        if (cart_item.id == item_id) {
            const quantity_str = std.fmt.allocPrint(res.arena, "{d}", .{cart_item.quantity}) catch {
                res.status = 500;
                res.body = "500 - Error";
                try res.write();
                return;
            };

            res.status = 200;
            res.content_type = httpz.ContentType.HTML;
            res.headers.add("HX-Trigger", "updateCartCount, cartUpdate");
            res.body = quantity_str;
            try res.write();
            return;
        }
    }

    // Item not found in cart
    res.status = 404;
    res.body = "404 - Item not in cart";
    try res.write();
}

pub fn cartDecreaseHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    const item_id_str = req.param("id") orelse {
        res.status = 400;
        res.body = "400 - Missing item ID";
        try res.write();
        return;
    };

    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        res.status = 400;
        res.body = "400 - Invalid item ID";
        try res.write();
        return;
    };

    // Decrease quantity
    handler.app.cart_manager.decreaseQuantity(user_id, item_id) catch {
        res.status = 500;
        res.body = "500 - Cart Error";
        try res.write();
        return;
    };

    // Get updated cart to check if item still exists (using arena - no manual cleanup needed)
    const cart_items = handler.app.cart_manager.getCart(res.arena, user_id) catch {
        res.status = 500;
        res.body = "500 - Database Error";
        try res.write();
        return;
    };
    // No defer needed - arena handles cleanup automatically

    // Check if item still exists
    for (cart_items) |cart_item| {
        if (cart_item.id == item_id) {
            // Item still exists, return updated quantity
            const quantity_str = std.fmt.allocPrint(res.arena, "{d}", .{cart_item.quantity}) catch {
                res.status = 500;
                res.body = "500 - Error";
                try res.write();
                return;
            };

            res.status = 200;
            res.content_type = httpz.ContentType.HTML;
            res.headers.add("HX-Trigger", "updateCartCount, cartUpdate");
            res.body = quantity_str;
            try res.write();
            return;
        }
    }

    // Item was removed (quantity reached 0) - retarget to entire cart item
    const retarget_str = std.fmt.allocPrint(res.arena, "#cart-item-{d}", .{item_id}) catch {
        res.status = 500;
        res.body = "500 - Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.headers.add("HX-Retarget", retarget_str);
    res.headers.add("HX-Reswap", "outerHTML");
    res.headers.add("HX-Trigger", "updateCartCount, cartUpdate");
    res.body = "";
    try res.write();
}

pub fn cartRemoveHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    const item_id_str = req.param("id") orelse {
        res.status = 400;
        res.body = "400 - Missing item ID";
        try res.write();
        return;
    };

    const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
        res.status = 400;
        res.body = "400 - Invalid item ID";
        try res.write();
        return;
    };

    // Remove item from cart
    handler.app.cart_manager.removeFromCart(user_id, item_id) catch {
        res.status = 500;
        res.body = "500 - Cart Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.headers.add("HX-Trigger", "updateCartCount, cartUpdate");
    res.body = "";
    try res.write();
}

pub fn shoppingListHandler(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;

    // Serve the shopping list page template which will load cart via HTMX
    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = templates.shopping_list_page_html;
    try res.write();
}

pub fn cartTotalHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Get user ID from JWT
    const payload = validateJWT(req, res.arena) orelse {
        res.status = 401;
        res.body = "401 - Unauthorized";
        try res.write();
        return;
    };
    defer jwt.deinitPayload(res.arena, payload);
    const user_id = payload.user_id;

    // Get cart total from cart manager (using arena)
    const total = handler.app.cart_manager.getCartTotal(res.arena, user_id) catch 0.0;

    const total_str = std.fmt.allocPrint(res.arena, "${d:.2}", .{total}) catch {
        res.status = 500;
        res.body = "500 - Error";
        try res.write();
        return;
    };

    res.status = 200;
    res.content_type = httpz.ContentType.HTML;
    res.body = total_str;
    try res.write();
}

pub fn presenceHandler(handler: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    return ws_httpz.websocketHandler(handler, req, res);
}

// Global references for proper shutdown - will be set in main()
var global_gpa: ?*std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .thread_safe = true,
}) = null;

var global_server: ?*httpz.Server(Handler) = null;

// Signal handler for graceful shutdown
fn signalHandler(_: c_int) callconv(.c) void {
    if (global_server) |server| {
        std.log.info("** SHUTDOWN SIGNAL RECEIVED **", .{});
        global_server = null;
        server.stop();
    }
}

// Cleanup function called after server.listen() returns
fn performCleanup() void {
    std.log.info("** PERFORMING CLEANUP **", .{});

    // Clean up the global WebSocket clients ArrayList and any remaining clients
    if (global_gpa) |gpa| {
        const allocator = switch (builtin.mode) {
            .Debug, .ReleaseSafe => gpa.allocator(),
            .ReleaseFast, .ReleaseSmall => std.heap.c_allocator,
        };
        // std.log.info("Cleaning up WebSocket clients...", .{});
        ws_httpz.deinitWebSocketClients(allocator);
    }

    std.log.info("** CLEANUP COMPLETE **", .{});
}

/// Cleanup handler to clear all carts => useful for testing with k6
pub fn cleanupCartsHandler(handler: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    // Clear all carts (useful after tests)
    handler.app.cart_manager.rwlock.lock();
    defer handler.app.cart_manager.rwlock.unlock();

    var iter = handler.app.cart_manager.user_carts.iterator();
    var count: u32 = 0;
    while (iter.next()) |entry| {
        handler.app.cart_manager.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
        count += 1;
    }
    handler.app.cart_manager.user_carts.clearAndFree();

    const result = std.fmt.allocPrint(res.arena, "Cleaned up {d} carts", .{count}) catch "Cleanup complete";
    res.status = 200;
    res.body = result;
    try res.write();
}

/// Cart statistics handler - shows logical cart count for memory leak tracking
pub fn cartStatsHandler(handler: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    handler.app.cart_manager.rwlock.lockShared();
    defer handler.app.cart_manager.rwlock.unlockShared();

    const user_count = handler.app.cart_manager.user_carts.count();
    var total_items: u32 = 0;

    var iter = handler.app.cart_manager.user_carts.iterator();
    while (iter.next()) |entry| {
        total_items += @intCast(entry.value_ptr.count());
    }

    const result = std.fmt.allocPrint(res.arena, "{{ \"users\": {d}, \"total_items\": {d} }}", .{ user_count, total_items }) catch "{ \"users\": 0, \"total_items\": 0 }";
    res.status = 200;
    res.content_type = httpz.ContentType.JSON;
    res.body = result;
    try res.write();
}

pub fn main() !void {
    // Setup GPA for memory tracking
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};

    // Set global references for shutdown access
    global_gpa = &gpa;

    // Setup signal handler for graceful shutdown (Ctrl+C)
    if (builtin.os.tag != .windows) {
        std.posix.sigaction(std.posix.SIG.INT, &.{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        std.log.info("Use Ctrl+C to shutdown gracefully", .{});
    }

    defer {
        std.log.info("** FINAL MEMORY LEAK DETECTION **", .{});
        if (builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall) {
            const leaks = gpa.detectLeaks();
            std.log.info("Pre-deinit leak check: {}", .{leaks});
        }
        const deinit_status = gpa.deinit();
        switch (deinit_status) {
            .ok => std.log.info("No memory leaks detected", .{}),
            .leak => std.log.err("!! Memory leaks detected !!", .{}),
        }
        std.log.info("** MEMORY ANALYSIS COMPLETE **", .{});
    }

    const allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => gpa.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.c_allocator,
    };

    var app = try AppContext.init(allocator);
    defer app.deinit();

    const config = httpz.Config{
        .port = 8880,
        .address = "0.0.0.0",
        .thread_pool = .{
            .count = 32,
            .buffer_size = 131_072,
            .backlog = 2_000,
        },
        .workers = .{
            .count = 2,
            .large_buffer_count = 32,
            .large_buffer_size = 131_072,
        },
    };

    var server = try httpz.Server(Handler).init(
        allocator,
        config,
        Handler{ .app = &app },
    );
    defer server.deinit();

    // Store global server reference for shutdown
    global_server = &server;

    var router = try server.router(.{});

    router.get("/", indexHandler, .{});
    router.get("/index.css", cssHandler, .{});
    router.get("/htmx.min.js", htmxHandler, .{});
    router.get("/ws.min.js", wsHandler, .{});
    router.get("/cart-count", cartCountHandler, .{});
    router.get("/groceries", groceriesHandler, .{});
    router.get("/api/items", apiItemsHandler, .{});
    router.get("/item-details/default", itemDetailsDefaultHandler, .{});
    router.get("/api/item-details/:id", apiItemDetailsHandler, .{});
    router.get("/api/cart", cartGetHandler, .{});
    router.post("/api/cart/add/:id", cartAddHandler, .{});
    router.post("/api/cart/increase-quantity/:id", cartIncreaseHandler, .{});
    router.post("/api/cart/decrease-quantity/:id", cartDecreaseHandler, .{});
    router.delete("/api/cart/remove/:id", cartRemoveHandler, .{});
    router.get("/shopping-list", shoppingListHandler, .{});
    router.get("/cart-total", cartTotalHandler, .{});
    router.get("/presence", presenceHandler, .{});
    router.get("/cleanup-carts", cleanupCartsHandler, .{});
    router.get("/cart-stats", cartStatsHandler, .{});

    std.log.info("httpz server listening on port 8880", .{});
    std.log.info("Press Ctrl+C to shutdown gracefully", .{});

    // This blocks until server.stop() is called from signal handler
    try server.listen();

    // Server stopped, perform cleanup
    performCleanup();
}
