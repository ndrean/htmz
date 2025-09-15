const std = @import("std");
const builtin = @import("builtin");
const htmz = @import("htmz");
const httpz = @import("htmz").httpz;
const z = @import("htmz").z;
const initial_html = @import("index.zig").index_html;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator, const is_debug =
        switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ gpa.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };

    defer if (is_debug) {
        std.debug.print("\n\nLeaks detected: {}\n\n", .{gpa.deinit() != .ok});
    };

    const doc = try z.createDocFromString(initial_html);
    const html_node = z.documentRoot(doc).?;
    const html_elt = z.nodeToElement(html_node).?;
    const body_node = z.bodyNode(doc).?;

    try z.normalizeDOMwithOptions(
        allocator,
        html_elt,
        .{ .skip_comments = true },
    );
    const normed_html = try z.outerHTML(allocator, html_elt);

    // std.debug.print("intial: {d}, normalized: {d}\n", .{ initial_html.len, normed_html.len });
    defer z.destroyDocument(doc);

    var css_engine = try z.createCssEngine(allocator);
    defer css_engine.deinit();

    // try z.prettyPrint(allocator, html_node);

    // Configuration: set to true to use SQLite, false to use memory
    const use_sqlite = false; // SQLite API compatibility issues - using optimized memory mode

    try htmz.runServer(
        allocator,
        normed_html,
        &css_engine,
        body_node,
        use_sqlite,
    );
}
