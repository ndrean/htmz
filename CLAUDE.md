This is a Zig project that uses the Zig webserver `http.zig` and the library `zexplorer` to serve as a backend to a HTMX client.


The Zig version is 0.15.1

Some rules:
- in this Zig version, **ArrayList are instantiated** as `list: std.arrayList(T) = .empty` and `defer lists.deinit(allocator)` and then use `list.append(allocator, item)`
- **always** pass an anonymous struct when using `std.debug.print("...", .{})`.
