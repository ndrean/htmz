const std = @import("std");
const htmz = @import("htmz");
const httpz = @import("htmz").httpz;
const z = @import("htmz").z;
const initial_html = @import("index.zig").index_html;

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const allocator = gpa.allocator();
    const allocator = std.heap.c_allocator;
    // Prints to stderr, ignoring potential errors.
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    // try htmz.bPrint(42);
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

    std.debug.print("intial: {d}, normalized: {d}\n", .{ initial_html.len, normed_html.len });
    defer z.destroyDocument(doc);

    var css_engine = try z.createCssEngine(allocator);
    defer css_engine.deinit();

    try z.prettyPrint(allocator, html_node);

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
