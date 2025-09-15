const std = @import("std");
const zap = @import("zap");
const builtin = @import("builtin");
const Mustache = zap.Mustache;
// const z = @import("zexplorer");

// Import our JWT implementation that's self-contained
const jwt = @import("jwt.zig");

// Import the template data type
const TemplateData = @import("read_html.zig").TemplateData;

// Context type for our Zap App
const AppContext = struct {
    templates: TemplateData,

    pub fn init(templates: TemplateData) AppContext {
        return .{ .templates = templates };
    }

    pub fn deinit(self: *const AppContext, allocator: std.mem.Allocator) void {
        self.templates.deinit(allocator);
    }
};

// Mustache template for grocery items - much faster!
const grocery_item_mustache =
    \\<div
    \\  class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer"
    \\  hx-get="/api/item-details/{{id}}"
    \\  hx-target="#item-details-card"
    \\  hx-swap="innerHTML"
    \\>
    \\  <div>
    \\    <span class="text-lg font-semibold text-gray-900">{{name}}</span
    \\    ><span class="text-sm text-gray-500 ml-2">${{price}}</span>
    \\  </div>
    \\  <button
    \\    class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors"
    \\    hx-post="/api/cart/add/{{id}}"
    \\    hx-swap="none"
    \\  >
    \\    Add to Cart
    \\  </button>
    \\</div>
;

fn formatGroceryItem(allocator: std.mem.Allocator, item_id: usize, name: []const u8, price: f64) ![]u8 {
    var mustache = Mustache.fromData(grocery_item_mustache) catch return error.OutOfMemory;
    defer mustache.deinit();

    const ret = mustache.build(.{
        .id = @as(isize, @intCast(item_id)),
        .name = name,
        .price = price,
    });
    defer ret.deinit();

    if (ret.str()) |s| {
        return allocator.dupe(u8, s);
    } else {
        return error.OutOfMemory;
    }
}


// Mustache template for cart items
const cart_item_mustache =
    \\<div class="flex justify-between items-center p-4 border-b">
    \\  <div>
    \\    <span class="font-semibold">{{name}}</span><br /><span
    \\      class="text-sm text-gray-500"
    \\      >${{price}}</span
    \\    >
    \\  </div>
    \\  <div class="flex items-center space-x-2">
    \\    <button
    \\      class="px-2 py-1 bg-red-500 text-white rounded"
    \\      hx-post="/api/cart/decrease-quantity/{{id}}"
    \\      hx-target="#cart-content"
    \\      hx-swap="innerHTML"
    \\    >
    \\      -
    \\    </button>
    \\    <span class="px-3 py-1 bg-gray-100 rounded">{{quantity}}</span>
    \\    <button
    \\      class="px-2 py-1 bg-green-500 text-white rounded"
    \\      hx-post="/api/cart/increase-quantity/{{id}}"
    \\      hx-target="#cart-content"
    \\      hx-swap="innerHTML"
    \\    >
    \\      +
    \\    </button>
    \\    <button
    \\      class="px-2 py-1 bg-red-600 text-white rounded ml-2"
    \\      hx-delete="/api/cart/remove/{{id}}"
    \\      hx-target="#cart-content"
    \\      hx-swap="innerHTML"
    \\    >
    \\      Remove
    \\    </button>
    \\  </div>
    \\</div>
;

fn formatCartItem(allocator: std.mem.Allocator, name: []const u8, price: f64, id: usize, quantity: usize) ![]u8 {
    var mustache = Mustache.fromData(cart_item_mustache) catch return error.OutOfMemory;
    defer mustache.deinit();

    const ret = mustache.build(.{
        .name = name,
        .price = price,
        .id = @as(isize, @intCast(id)),
        .quantity = @as(isize, @intCast(quantity)),
    });
    defer ret.deinit();

    if (ret.str()) |s| {
        return allocator.dupe(u8, s);
    } else {
        return error.OutOfMemory;
    }
}

// Mustache template for item details
const item_details_mustache =
    \\<div class="text-center">
    \\  <h3 class="text-2xl font-bold text-gray-800 mb-4">{{name}}</h3>
    \\  <div
    \\    class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center"
    \\  >
    \\    <svg
    \\      class="w-12 h-12 text-gray-400"
    \\      fill="none"
    \\      stroke="currentColor"
    \\      viewBox="0 0 24 24"
    \\    >
    \\      <path
    \\        stroke-linecap="round"
    \\        stroke-linejoin="round"
    \\        stroke-width="2"
    \\        d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"
    \\      ></path>
    \\    </svg>
    \\  </div>
    \\  <div class="bg-blue-50 rounded-lg p-6 mb-6">
    \\    <p class="text-3xl font-bold text-blue-600">${{price}}</p>
    \\    <p class="text-gray-600 mt-2">per unit</p>
    \\  </div>
    \\  <div class="space-y-3">
    \\    <button
    \\      class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold"
    \\      hx-post="/api/cart/add/{{id}}"
    \\      hx-swap="none"
    \\    >
    \\      Add to Cart
    \\    </button>
    \\    <button
    \\      class="w-full border border-gray-300 text-gray-700 py-2 px-6 rounded-lg hover:bg-gray-50 transition-colors"
    \\      onclick="alert('More details coming soon!')"
    \\    >
    \\      More Details
    \\    </button>
    \\  </div>
    \\</div>
;

fn formatItemDetails(allocator: std.mem.Allocator, name: []const u8, price: f64, id: usize) ![]u8 {
    var mustache = Mustache.fromData(item_details_mustache) catch return error.OutOfMemory;
    defer mustache.deinit();

    const ret = mustache.build(.{
        .name = name,
        .price = price,
        .id = @as(isize, @intCast(id)),
    });
    defer ret.deinit();

    if (ret.str()) |s| {
        return allocator.dupe(u8, s);
    } else {
        return error.OutOfMemory;
    }
}

// Import real grocery data
const grocery_items = @import("grocery_items.zig").grocery_list;
const GroceryItem = @import("grocery_items.zig").GroceryItem;

// Create the Zap App type
const App = zap.App.Create(AppContext);

// Helper function to generate cart HTML from cart items using templates
fn generateCartHTML(allocator: std.mem.Allocator, cart_items: []const jwt.CartItem) ![]u8 {
    if (cart_items.len == 0) {
        return allocator.dupe(u8, "<p>Your cart is empty</p>");
    }

    var cart_html: std.ArrayList(u8) = .empty;
    defer cart_html.deinit(allocator);

    for (cart_items) |item| {
        // Use the proper template with formatted string replacement
        const item_html = formatCartItem(allocator, item.name, item.price, item.id, item.quantity) catch return error.OutOfMemory;
        defer allocator.free(item_html);
        cart_html.appendSlice(allocator, item_html) catch return error.OutOfMemory;
    }

    return cart_html.toOwnedSlice(allocator);
}

// Helper function to generate grocery items HTML using templates
fn generateGroceryItemsHTML(allocator: std.mem.Allocator) ![]u8 {
    var items_html: std.ArrayList(u8) = .empty;
    defer items_html.deinit(allocator);

    for (grocery_items, 0..) |item, i| {
        const item_html = formatGroceryItem(allocator, i, item.name, item.unit_price) catch return error.OutOfMemory;
        defer allocator.free(item_html);
        items_html.appendSlice(allocator, item_html) catch return error.OutOfMemory;
    }

    return items_html.toOwnedSlice(allocator);
}

// JWT Helper Functions
fn getBearerToken(r: zap.Request) ?[]const u8 {
    // First try Authorization header (for k6 tests)
    if (r.getHeader("authorization")) |auth_header| {
        if (std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return auth_header[7..]; // Skip "Bearer "
        }
    }

    // Then try cookie (for browser users) - simple approach
    if (r.getHeader("cookie")) |cookie_header| {
        // Look for jwt_token=VALUE in cookie string
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

// Handle cart operations with proper JWT state management
fn handleCartOperation(r: zap.Request, operation: []const u8, allocator: std.mem.Allocator) void {

    // Get current JWT and verify it
    const token = getBearerToken(r) orelse {
        r.setStatus(.unauthorized);
        r.sendBody("Missing Authorization header") catch return;
        return;
    };

    const current_payload = jwt.verifyJWT(allocator, token) catch {
        r.setStatus(.unauthorized);
        r.sendBody("Invalid or expired JWT") catch return;
        return;
    };
    defer current_payload.deinit(allocator);

    // Extract item ID from path
    const path = r.path orelse {
        r.setStatus(.bad_request);
        return;
    };

    // Determine the operation path prefix
    const prefix = if (std.mem.eql(u8, operation, "add")) "/api/cart/add/" else if (std.mem.eql(u8, operation, "increase")) "/api/cart/increase-quantity/" else if (std.mem.eql(u8, operation, "decrease")) "/api/cart/decrease-quantity/" else if (std.mem.eql(u8, operation, "remove")) "/api/cart/remove/" else {
        r.setStatus(.bad_request);
        return;
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

    // Use real grocery data
    if (item_id >= grocery_items.len) {
        r.setStatus(.bad_request);
        return;
    }

    // Handle different cart operations
    var new_cart: std.ArrayList(jwt.CartItem) = .empty;
    defer new_cart.deinit(allocator);

    if (std.mem.eql(u8, operation, "add")) {
        // Copy existing cart
        for (current_payload.cart) |existing_item| {
            const cloned_item = jwt.CartItem{
                .id = existing_item.id,
                .name = allocator.dupe(u8, existing_item.name) catch {
                    r.setStatus(.internal_server_error);
                    return;
                },
                .quantity = existing_item.quantity,
                .price = existing_item.price,
            };
            new_cart.append(allocator, cloned_item) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        }

        // Check if item already exists in cart
        var found = false;
        for (new_cart.items) |*existing_item| {
            if (existing_item.id == item_id) {
                existing_item.quantity += 1;
                found = true;
                break;
            }
        }

        // Add new item if not found
        if (!found) {
            const grocery_item = grocery_items[item_id];
            const new_item = jwt.CartItem{
                .id = item_id,
                .name = allocator.dupe(u8, grocery_item.name) catch {
                    r.setStatus(.internal_server_error);
                    return;
                },
                .quantity = 1,
                .price = grocery_item.unit_price,
            };
            new_cart.append(allocator, new_item) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        }
    } else if (std.mem.eql(u8, operation, "increase")) {
        // Copy existing cart and increase quantity
        for (current_payload.cart) |existing_item| {
            var cloned_item = jwt.CartItem{
                .id = existing_item.id,
                .name = allocator.dupe(u8, existing_item.name) catch {
                    r.setStatus(.internal_server_error);
                    return;
                },
                .quantity = existing_item.quantity,
                .price = existing_item.price,
            };

            if (cloned_item.id == item_id) {
                cloned_item.quantity += 1;
            }

            new_cart.append(allocator, cloned_item) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        }
    } else if (std.mem.eql(u8, operation, "decrease")) {
        // Copy existing cart and decrease quantity or remove if quantity becomes 0
        for (current_payload.cart) |existing_item| {
            var cloned_item = jwt.CartItem{
                .id = existing_item.id,
                .name = allocator.dupe(u8, existing_item.name) catch {
                    r.setStatus(.internal_server_error);
                    return;
                },
                .quantity = existing_item.quantity,
                .price = existing_item.price,
            };

            if (cloned_item.id == item_id) {
                if (cloned_item.quantity > 1) {
                    cloned_item.quantity -= 1;
                } else {
                    // Skip this item (remove it)
                    allocator.free(cloned_item.name);
                    continue;
                }
            }

            new_cart.append(allocator, cloned_item) catch {
                r.setStatus(.internal_server_error);
                return;
            };
        }
    } else if (std.mem.eql(u8, operation, "remove")) {
        // Copy existing cart except the item to remove
        for (current_payload.cart) |existing_item| {
            if (existing_item.id != item_id) {
                const cloned_item = jwt.CartItem{
                    .id = existing_item.id,
                    .name = allocator.dupe(u8, existing_item.name) catch {
                        r.setStatus(.internal_server_error);
                        return;
                    },
                    .quantity = existing_item.quantity,
                    .price = existing_item.price,
                };

                new_cart.append(allocator, cloned_item) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            }
        }
    }

    // Clone user_id for new payload
    const user_id_clone = allocator.dupe(u8, current_payload.user_id) catch {
        r.setStatus(.internal_server_error);
        return;
    };

    const updated_payload = jwt.JWTPayload{
        .user_id = user_id_clone,
        .cart = new_cart.toOwnedSlice(allocator) catch {
            r.setStatus(.internal_server_error);
            return;
        },
        .exp = std.time.timestamp() + 3600, // Refresh expiry
    };
    defer updated_payload.deinit(allocator);

    const new_token = jwt.generateJWT(allocator, updated_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer allocator.free(new_token);

    r.setHeader("X-JWT-Token", new_token) catch {};

    // Also set updated JWT as cookie with HttpOnly for security
    const cookie_value = std.fmt.allocPrint(allocator, "jwt_token={s}; Path=/; Max-Age=3600; SameSite=Lax; HttpOnly", .{new_token}) catch {
        return;
    };
    defer allocator.free(cookie_value);
    r.setHeader("Set-Cookie", cookie_value) catch {};

    // For all cart operations, return the updated cart HTML so HTMX can refresh the display
    r.setStatus(.ok);
    r.setContentType(.HTML) catch return;

    // Generate updated cart HTML using template
    const cart_html = generateCartHTML(allocator, updated_payload.cart) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer allocator.free(cart_html);
    r.sendBody(cart_html) catch return;
}

// Main endpoint that handles all routes
const MainEndpoint = struct {
    pub fn get(self: *MainEndpoint, arena: std.mem.Allocator, context: *AppContext, r: zap.Request) !void {
        _ = self;
        return handleRequest(arena, context, r);
    }

    pub fn post(self: *MainEndpoint, arena: std.mem.Allocator, context: *AppContext, r: zap.Request) !void {
        _ = self;
        return handleRequest(arena, context, r);
    }

    pub fn delete(self: *MainEndpoint, arena: std.mem.Allocator, context: *AppContext, r: zap.Request) !void {
        _ = self;
        return handleRequest(arena, context, r);
    }
};

// Request handler that works with context
fn handleRequest(arena: std.mem.Allocator, context: *const AppContext, r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // Handle static CSS file
    if (std.mem.eql(u8, path, "/index.css")) {
        if (method == .GET) {
            r.setHeader("Content-Type", "text/css") catch {};
            r.setHeader("Cache-Control", "public, max-age=3600") catch {};
            r.sendFile("src/html/index.css") catch return;
            return;
        }
    }

    // Handle root route - smart JWT handling for both k6 and browser users
    if (std.mem.eql(u8, path, "/")) {
        if (method == .GET) {
            const allocator = arena;

            // Check if user already has a valid JWT (k6 case)
            var user_jwt: ?[]const u8 = null;
            if (getBearerToken(r)) |token| {
                // k6 test case - verify existing JWT
                if (jwt.verifyJWT(allocator, token)) |_| {
                    user_jwt = token; // Valid JWT, use it
                } else |_| {
                    // Invalid/expired token, will generate new one
                }
            }

            // Generate new JWT if user doesn't have valid one (browser case)
            var new_token: ?[]const u8 = null;
            var new_user_id: ?[]const u8 = null;
            if (user_jwt == null) {
                new_user_id = std.fmt.allocPrint(allocator, "user_{d}_{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) }) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };

                const new_payload = jwt.JWTPayload{
                    .user_id = new_user_id.?,
                    .cart = &[_]jwt.CartItem{}, // Empty cart for new users
                    .exp = std.time.timestamp() + 3600, // 1 hour expiry
                };

                new_token = jwt.generateJWT(allocator, new_payload) catch {
                    allocator.free(new_user_id.?);
                    r.setStatus(.internal_server_error);
                    return;
                };

                // Set JWT as header and cookie
                r.setHeader("X-JWT-Token", new_token.?) catch {};
                r.setHeader("HX-Set-Authorization: Bearer", new_token.?) catch {};

                // Set JWT as cookie for browser HTMX requests with HttpOnly for security
                const cookie_value = std.fmt.allocPrint(allocator, "jwt_token={s}; Path=/; Max-Age=3600; SameSite=Lax; HttpOnly", .{new_token.?}) catch {
                    return;
                };
                defer allocator.free(cookie_value);
                r.setHeader("Set-Cookie", cookie_value) catch {};
            }
            defer if (new_token) |token| allocator.free(token);
            defer if (new_user_id) |user_id| allocator.free(user_id);

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;

            // Set cache headers for the main page to improve performance
            r.setHeader("Cache-Control", "public, max-age=3600") catch {};
            r.setHeader("ETag", "\"htmx-zig-v1\"") catch {};

            // Send the HTML page (JWT authentication now handled automatically via HttpOnly cookies)
            r.sendBody(context.templates.initial_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/groceries")) {
        if (method == .GET) {
            // Return groceries page HTML
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(context.templates.groceries_page_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/shopping-list")) {
        if (method == .GET) {
            // Return shopping list page HTML
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(context.templates.shopping_list_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/items")) {
        if (method == .GET) {
            // Return grocery items list
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            // Generate items from real grocery data
            const allocator = arena;
            var items_html: std.ArrayList(u8) = .empty;
            defer items_html.deinit(allocator);

            for (grocery_items, 0..) |item, i| {
                const item_div = formatGroceryItem(allocator, i, item.name, item.unit_price) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
                defer allocator.free(item_div);
                items_html.appendSlice(allocator, item_div) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            }

            r.sendBody(items_html.items) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/cart")) {
        if (method == .GET) {
            const allocator = arena;

            // Get JWT token and parse cart contents
            const token = getBearerToken(r) orelse {
                // No token - return empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p>Your cart is empty</p>") catch return;
                return;
            };

            const payload = jwt.verifyJWT(allocator, token) catch {
                // Invalid token - return empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p>Your cart is empty</p>") catch return;
                return;
            };

            if (payload.cart.len == 0) {
                // Empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p>Your cart is empty</p>") catch return;
                return;
            }

            // Build cart HTML using template
            const cart_html = generateCartHTML(allocator, payload.cart) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer allocator.free(cart_html);

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(cart_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/item-details/default")) {
        if (method == .GET) {
            // Return default item details
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(context.templates.item_details_default_html) catch return;
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/item-details/")) {
        if (method == .GET) {
            // Extract item ID from path
            const item_id_str = path["/api/item-details/".len..];
            const item_id = std.fmt.parseInt(u32, item_id_str, 10) catch {
                r.setStatus(.bad_request);
                return;
            };

            // Use real grocery data
            if (item_id >= grocery_items.len) {
                r.setStatus(.not_found);
                return;
            }

            const grocery_item = grocery_items[item_id];
            const allocator = arena;
            const item_html = formatItemDetails(allocator, grocery_item.name, grocery_item.unit_price, item_id) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer allocator.free(item_html);

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(item_html) catch return;
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
        if (method == .POST) {
            handleCartOperation(r, "add", arena);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, "increase", arena);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, "decrease", arena);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/remove/")) {
        if (method == .DELETE) {
            handleCartOperation(r, "remove", arena);
            return;
        }
    }

    // Default 404 response
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

// Global context for HttpListener approach
var g_context: ?*const AppContext = null;

// Wrapper request handler for HttpListener
fn on_request_jwt(r: zap.Request) !void {
    const context = g_context orelse {
        r.setStatus(.internal_server_error);
        r.sendBody("Context not initialized") catch return;
        return;
    };
    // Use c_allocator for HttpListener approach - the arena allocator is only available in App endpoints
    return handleRequest(std.heap.c_allocator, context, r);
}

pub fn main() !void {
    var gpa: ?std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = null;
    const allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => blk: {
            gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
            break :blk gpa.?.allocator();
        },
        else => std.heap.c_allocator, // Fast mode uses c_allocator directly
    };

    // Load templates once at startup
    const templates_data = try @import("read_html.zig").read_html(allocator);

    // Create context with templates
    var app_context = AppContext.init(templates_data);
    g_context = &app_context;

    // Initialize Zap HTTP listener for JWT server
    var listener = zap.HttpListener.init(.{
        .port = 8081,
        .on_request = on_request_jwt,
        .log = false,
    });

    try listener.listen();

    std.log.info("JWT Server started on http://127.0.0.1:8081", .{});
    zap.start(.{ .threads = 2, .workers = 2 });

    // Clean up templates after server stops
    app_context.deinit(allocator);

    std.debug.print("\n\nSTOPPED\n\n", .{});
    if (gpa) |*g| {
        std.debug.print("Leaks detected: {}, {}\n\n", .{ g.detectLeaks(), g.deinit() != .ok });
    }
}