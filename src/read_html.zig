const std = @import("std");
const z = @import("zexplorer");

fn preloadTemplates(allocator: std.mem.Allocator, body_node: *z.DomNode) !struct {
    grocery_items_template: []const u8,
    groceries_page_html: []const u8,
    shopping_list_html: []const u8,
    item_details_default_html: []const u8,
    item_details_template: []const u8,
    cart_item_template: []const u8,
} {
    const item_template = z.getElementById(
        body_node,
        "grocery-item-template",
    );
    const grocery_item_template_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(item_template.?),
    );
    const grocery_item_template_copy = try allocator.dupe(u8, grocery_item_template_html);
    defer allocator.free(grocery_item_template_html);

    const groceries_template = z.getElementById(
        body_node,
        "groceries-page-template",
    );
    const groceries_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(groceries_template.?),
    );
    const groceries_html_copy = try allocator.dupe(u8, groceries_html);
    defer allocator.free(groceries_html);

    const shopping_template = z.getElementById(
        body_node,
        "shopping-list-template",
    );
    const shopping_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(shopping_template.?),
    );
    const shopping_html_copy = try allocator.dupe(u8, shopping_html);
    defer allocator.free(shopping_html);

    const default_template = z.getElementById(
        body_node,
        "item-details-default-template",
    );
    const default_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(default_template.?),
    );
    const default_html_copy = try allocator.dupe(u8, default_html);
    defer allocator.free(default_html);

    const details_template = z.getElementById(
        body_node,
        "item-details-template",
    );
    const details_template_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(details_template.?),
    );
    const details_template_html_copy = try allocator.dupe(u8, details_template_html);
    defer allocator.free(details_template_html);

    const cart_item_template = z.getElementById(
        body_node,
        "cart-item-template",
    );
    const cart_item_template_html = try z.innerTemplateHTML(
        allocator,
        z.elementToNode(cart_item_template.?),
    );
    const cart_item_template_html_copy = try allocator.dupe(u8, cart_item_template_html);
    defer allocator.free(cart_item_template_html);

    return .{
        .grocery_items_template = grocery_item_template_copy,
        .groceries_page_html = groceries_html_copy,
        .shopping_list_html = shopping_html_copy,
        .item_details_default_html = default_html_copy,
        .item_details_template = details_template_html_copy,
        .cart_item_template = cart_item_template_html_copy,
    };
}

pub const TemplateData = struct {
    initial_html: []const u8,
    grocery_items_template: []const u8,
    groceries_page_html: []const u8,
    shopping_list_html: []const u8,
    item_details_default_html: []const u8,
    item_details_template: []const u8,
    cart_item_template: []const u8,

    pub fn deinit(self: *const TemplateData, allocator: std.mem.Allocator) void {
        allocator.free(self.initial_html);
        allocator.free(self.grocery_items_template);
        allocator.free(self.groceries_page_html);
        allocator.free(self.shopping_list_html);
        allocator.free(self.item_details_default_html);
        allocator.free(self.item_details_template);
        allocator.free(self.cart_item_template);
    }
};

pub fn read_html(allocator: std.mem.Allocator) !TemplateData {
    const html = @embedFile("html/index.html");
    const doc = try z.createDocument();
    defer z.destroyDocument(doc);

    try z.parseString(doc, html);

    const html_node = z.documentRoot(doc).?;
    const html_elt = z.nodeToElement(html_node).?;

    try z.normalizeDOMwithOptions(
        allocator,
        html_elt,
        .{ .skip_comments = true },
    );
    const normed_html = try z.outerHTML(allocator, html_elt);
    const normed_html_copy = try allocator.dupe(u8, normed_html);
    defer allocator.free(normed_html);

    std.log.info("Intial size: {[initial]d}, normalized size: {[normed]d}\n", .{
        .normed = normed_html.len,
        .initial = html.len,
    });

    const templates_html = @embedFile(("html/templates.html"));
    const normed_templates_html = try z.normalizeHtmlStringWithOptions(
        allocator,
        templates_html,
        .{ .remove_whitespace_text_nodes = true },
    );
    defer allocator.free(normed_templates_html);

    const templates_doc = try z.createDocument();
    defer z.destroyDocument(templates_doc);
    try z.parseString(templates_doc, normed_templates_html);

    const templates_body = z.bodyNode(templates_doc).?;

    // var css_engine = try z.CssSelectorEngine.init(allocator);
    // defer css_engine.deinit();

    const template_struct = try preloadTemplates(allocator, templates_body);
    return .{
        .initial_html = normed_html_copy,
        .grocery_items_template = template_struct.grocery_items_template,
        .groceries_page_html = template_struct.groceries_page_html,
        .shopping_list_html = template_struct.shopping_list_html,
        .item_details_default_html = template_struct.item_details_default_html,
        .item_details_template = template_struct.item_details_template,
        .cart_item_template = template_struct.cart_item_template,
    };
}
