# Context

This is a Zig project that uses the Zig webserver `Zap` (<https://github.com/zigzap/zap/blob/master/examples/app/basic.zig>) to serve HTML.
The client uses `HTMX` .

It is a dem shopping cart webapp. You have a grocery items list.
When you click on an item, it displays the item details, and you have an "add to cart" button" to populate your cart.
In the shopping list page, you get the selected items. You can increase/decrease the item count, and remove an item. when the count goes to 0, it is removed.

## JWT

I use a JWT, simply made from a random string. It is passed into a httpOnly, SameSite=Lax cookie "jwt-token".
Every request should validate the content.

A JWT is created when a user firstly connects. If k6 sends a request, k6 creates a JWT and uses it in each request.

The module "src/jwt.zig" manages the JWT.

## Zig 0.15.1

The Zig version is 0.15.1

This means:

- in this Zig version, **ArrayList are instantiated** as `list: std.arrayList(T) = .empty` and `defer lists.deinit(allocator)` and then use `list.append(allocator, item)`
- **always** pass an anonymous struct when using `std.debug.print("...", .{})`.

## HTML Files

The main "index.html" is in the src/html folder. It loads "index.css".
If changes are made to "index.html", you need to run "gzip" as Zap/facil.io can serve .gz.

The templates strings are in the module "src/templates.zig".

## SQLite - Grocery list

The grocery items are in a SQLite database. It is craeted once for all.
When the webserver starts, this table is used to populate the grocery list for display.
This list is not cached.

## Shopping cart

SQLite does not really work in concurrent mode. I cannot really use it to save a shopping cart in concurrent mode. One shopping cart database for each user is a possible strategy but heavy.

Instead, we could use Redis. For now, we build a HashMap.

The price should be read from SQLite.

This HashMap can grow unbound in this demo.

We diplay the total item count in a badge, next to the "Shopping List" nav link element.

The total value of the shopping list should be displayed in the shopping list.
