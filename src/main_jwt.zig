const std = @import("std");
const zap = @import("zap");

// Import our JWT implementation that's self-contained
const jwt = @import("jwt.zig");

// Global allocator for memory tracking
var global_allocator: std.mem.Allocator = undefined;

// Import the initial HTML template
// const initial_html = @import("index.zig").index_html;
const initial_html = @embedFile("html/index.html");

// Optimized template constants for direct allocPrint rendering
const grocery_item_template_optimized =
    \\<div class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer" hx-get="/api/item-details/{d}" hx-target="#item-details-card" hx-swap="innerHTML"><div><span class="text-lg font-semibold text-gray-900">{s}</span><span class="text-sm text-gray-500 ml-2">${d:.2}</span></div><button class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
;

const cart_item_template_optimized =
    \\<div class="flex justify-between items-center p-4 border-b"><div><span class="font-semibold">{s}</span><br><span class="text-sm text-gray-500">${d:.2}</span></div><div class="flex items-center space-x-2"><button class="px-2 py-1 bg-red-500 text-white rounded" hx-post="/api/cart/decrease-quantity/{d}" hx-target="#cart-content" hx-swap="innerHTML">-</button><span class="px-3 py-1 bg-gray-100 rounded">{d}</span><button class="px-2 py-1 bg-green-500 text-white rounded" hx-post="/api/cart/increase-quantity/{d}" hx-target="#cart-content" hx-swap="innerHTML">+</button><button class="px-2 py-1 bg-red-600 text-white rounded ml-2" hx-delete="/api/cart/remove/{d}" hx-target="#cart-content" hx-swap="innerHTML">Remove</button></div></div>
;

const item_details_template_optimized =
    \\<div class="text-center"><h3 class="text-2xl font-bold text-gray-800 mb-4">{s}</h3><div class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center"><svg class="w-12 h-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"></path></svg></div><div class="bg-blue-50 rounded-lg p-6 mb-6"><p class="text-3xl font-bold text-blue-600">${d:.2}</p><p class="text-gray-600 mt-2">per unit</p></div>
    \\<button class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
;

// JWT Helper Functions
fn getBearerToken(r: zap.Request) ?[]const u8 {
    // Get JWT from cookie (both k6 and browser use cookies)
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
fn handleCartOperation(r: zap.Request, operation: []const u8) void {
    const allocator = global_allocator;

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
    defer jwt.deinitPayload(allocator, current_payload);

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

    // Get real item data
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

    if (item_id >= items.len) {
        r.setStatus(.bad_request);
        return;
    }

    const item_data = items[item_id];
    const cart_item = jwt.CartItem{
        .id = item_id,
        .name = item_data.name,
        .quantity = 1,
        .price = item_data.price,
    };

    // Create updated payload (simplified - allocate cart)
    const cart_items = allocator.alloc(jwt.CartItem, 1) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer allocator.free(cart_items);
    cart_items[0] = cart_item;

    const updated_payload = jwt.JWTPayload{
        .user_id = current_payload.user_id,
        .cart = cart_items, // Simplified: always return one item
        .exp = std.time.timestamp() + 3600, // Refresh expiry
    };

    const new_token = jwt.generateJWT(allocator, updated_payload) catch {
        r.setStatus(.internal_server_error);
        return;
    };
    defer allocator.free(new_token);

    r.setHeader("X-JWT-Token", new_token) catch {};

    // Also set updated JWT as cookie
    const cookie_value = std.fmt.allocPrint(allocator, "jwt_token={s}; HttpOnly; Path=/; Max-Age=3600; SameSite=Lax", .{new_token}) catch {
        return;
    };
    defer allocator.free(cookie_value);
    r.setHeader("Set-Cookie", cookie_value) catch {};

    if (std.mem.eql(u8, operation, "increase") or std.mem.eql(u8, operation, "decrease")) {
        // For quantity operations, return the mock quantity
        r.setStatus(.ok);
        r.setContentType(.HTML) catch return;
        r.sendBody("1") catch return;
    } else {
        // For add/remove operations, just return 200
        r.setStatus(.ok);
    }
}

// JWT-specific request handler
fn on_request_jwt(r: zap.Request) !void {
    const path = r.path orelse {
        r.setStatus(.bad_request);
        r.sendBody("No path") catch return;
        return;
    };

    const method = r.methodAsEnum();

    // Handle root route - smart JWT handling for both k6 and browser users
    if (std.mem.eql(u8, path, "/")) {
        if (method == .GET) {
            const allocator = global_allocator;

            // Check if user already has a valid JWT (k6 case)
            var user_jwt: ?[]const u8 = null;
            if (getBearerToken(r)) |token| {
                // k6 test case - verify existing JWT
                if (jwt.verifyJWT(allocator, token)) |valid_payload| {
                    jwt.deinitPayload(allocator, valid_payload); // Free the payload immediately
                    user_jwt = token; // Valid JWT, use it
                }
                // else |_| {
                //     // Invalid/expired token, will generate new one
                // }
            }

            // Generate new JWT if user doesn't have valid one (browser case)
            var new_token: ?[]const u8 = null;
            var new_user_id: ?[]const u8 = null;
            if (user_jwt == null) {
                new_user_id = std.fmt.allocPrint(allocator, "user_{d}_{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) }) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
                // Don't defer free here - we need it for JWT generation

                const new_payload = jwt.JWTPayload{
                    .user_id = new_user_id.?,
                    .cart = &[_]jwt.CartItem{}, // Empty cart for new users
                    .exp = std.time.timestamp() + 3600, // 1 hour expiry
                };

                new_token = jwt.generateJWT(allocator, new_payload) catch {
                    if (new_user_id) |user_id| allocator.free(user_id);
                    r.setStatus(.internal_server_error);
                    return;
                };

                // Set JWT as header and cookie
                r.setHeader("X-JWT-Token", new_token.?) catch {};

                // Set JWT as cookie for browser HTMX requests
                const cookie_value = std.fmt.allocPrint(allocator, "jwt_token={s}; HttpOnly; Path=/; Max-Age=3600; SameSite=Lax", .{new_token.?}) catch {
                    return;
                };
                defer allocator.free(cookie_value);
                r.setHeader("Set-Cookie", cookie_value) catch {};
            }
            defer if (new_token) |token| allocator.free(token);
            defer if (new_user_id) |user_id| allocator.free(user_id);

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;

            // Send the HTML page (JWT is now in cookies, no need for header injection)
            r.sendBody(initial_html) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/index.css")) {
        if (method == .GET) {
            // Serve the CSS file
            r.setStatus(.ok);
            r.setHeader("Content-Type", "text/css") catch return;
            r.sendFile("src/html/index.css") catch {
                r.setStatus(.not_found);
                r.sendBody("CSS file not found") catch return;
            };
            return;
        }
    } else if (std.mem.eql(u8, path, "/groceries")) {
        if (method == .GET) {
            // Return groceries page HTML
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody("<div class=\"flex flex-col md:flex-row gap-8 p-4\"><div class=\"md:w-1/2\"><h2 class=\"text-3xl font-bold text-gray-800 mb-6\">Grocery Items</h2><div class=\"space-y-4 max-h-[400px] overflow-y-auto pr-2\" hx-get=\"/api/items\" hx-trigger=\"load, every 60s\" hx-target=\"this\" hx-swap=\"innerHTML\"><p class=\"text-gray-500\">Loading items...</p></div></div><div id=\"item-details-card\" class=\"md:w-1/2 bg-gray-100 rounded-xl p-6 shadow-lg min-h-[300px] flex items-center justify-center transition-all duration-300\" hx-get=\"/item-details/default\" hx-trigger=\"load\" hx-target=\"this\" hx-swap=\"innerHTML\"></div></div>") catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/shopping-list")) {
        if (method == .GET) {
            // Return shopping list page HTML
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody("<div class=\"flex flex-col items-center\"><h2 class=\"text-3xl font-bold text-gray-800 mb-6\">Shopping List</h2><div id=\"cart-content\" class=\"w-full max-w-xl bg-white rounded-lg p-6 shadow-md max-h-[500px] overflow-y-auto\" hx-get=\"/api/cart\" hx-trigger=\"load, every 30s\" hx-target=\"this\" hx-swap=\"innerHTML\"><p class=\"text-gray-600 text-center\">Your cart is empty.</p></div></div>") catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/items")) {
        if (method == .GET) {
            // Return grocery items list
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            // Dynamic item list generation
            const allocator = global_allocator;
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

            var items_html: std.ArrayList(u8) = .empty;
            defer items_html.deinit(allocator);

            for (items, 0..) |item, i| {
                const item_id = @as(u32, @intCast(i));
                const item_html = std.fmt.allocPrint(allocator, grocery_item_template_optimized, .{ item_id, item.name, item.price, item_id }) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
                defer allocator.free(item_html);
                items_html.appendSlice(allocator, item_html) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            }

            r.sendBody(items_html.items) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/api/cart")) {
        if (method == .GET) {
            const allocator = global_allocator;

            // Get JWT token and parse cart contents
            const token = getBearerToken(r) orelse {
                // No token - return empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>") catch return;
                return;
            };

            const payload = jwt.verifyJWT(allocator, token) catch {
                // Invalid token - return empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>") catch return;
                return;
            };
            defer jwt.deinitPayload(allocator, payload);

            if (payload.cart.len == 0) {
                // Empty cart
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                r.sendBody("<p class=\"text-gray-600 text-center\">Your cart is empty.</p>") catch return;
                return;
            }

            // Build cart HTML with actual items using direct allocPrint
            var cart_html: std.ArrayList(u8) = .empty;
            defer cart_html.deinit(allocator);

            for (payload.cart) |item| {
                const item_html = std.fmt.allocPrint(allocator, cart_item_template_optimized, .{ item.name, item.price, item.id, item.quantity, item.id, item.id }) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
                defer allocator.free(item_html);
                cart_html.appendSlice(allocator, item_html) catch {
                    r.setStatus(.internal_server_error);
                    return;
                };
            }

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(cart_html.items) catch return;
            return;
        }
    } else if (std.mem.eql(u8, path, "/item-details/default")) {
        if (method == .GET) {
            // Return default item details
            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody("<div class=\"text-center text-gray-500\"><h3 class=\"text-xl font-semibold mb-4\">Select an item</h3><p class=\"text-gray-400\">Click on a grocery item to view its details here.</p></div>") catch return;
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

            // Simple item database (should match /api/items)
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

            if (item_id >= items.len) {
                r.setStatus(.not_found);
                return;
            }

            const item = items[item_id];
            const allocator = global_allocator;

            // Use direct allocPrint for item details
            var details_html: std.ArrayList(u8) = .empty;
            defer details_html.deinit(allocator);

            const item_html = std.fmt.allocPrint(allocator, item_details_template_optimized, .{ item.name, item.price, item_id }) catch {
                r.setStatus(.internal_server_error);
                return;
            };
            defer allocator.free(item_html);
            details_html.appendSlice(allocator, item_html) catch {
                r.setStatus(.internal_server_error);
                return;
            };

            r.setStatus(.ok);
            r.setContentType(.HTML) catch return;
            r.sendBody(details_html.items) catch return;
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/add/")) {
        if (method == .POST) {
            handleCartOperation(r, "add");
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/increase-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, "increase");
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/decrease-quantity/")) {
        if (method == .POST) {
            handleCartOperation(r, "decrease");
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/api/cart/remove/")) {
        if (method == .DELETE) {
            handleCartOperation(r, "remove");
            return;
        }
    }

    // Default 404 response
    r.setStatus(.not_found);
    r.sendBody("404 - Not Found") catch return;
}

pub fn main() !void {
    // Setup GPA for memory leak detection
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
        const allocator = gpa.allocator();
        // const allocator = std.heap.c_allocator; // Use C allocator for simplicity in this example

        // Store allocator globally for use in request handlers
        global_allocator = allocator;

        // Initialize Zap HTTP listener for JWT server
        var listener = zap.HttpListener.init(.{
            .port = 8080,
            .on_request = on_request_jwt,
            .log = false,
        });
        try listener.listen();

        std.log.info("JWT Server started on http://127.0.0.1:8080 with optimized worker config", .{});
        zap.start(.{ .threads = 8, .workers = 8 });
    }
    std.debug.print("Leaks detected: {}\n", .{gpa.detectLeaks()});
}
