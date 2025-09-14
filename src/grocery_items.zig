const std = @import("std");

pub const GroceryItem = struct {
    name: []const u8,
    unit_price: f32,
};

pub const grocery_list = [_]GroceryItem{
    .{ .name = "Apples", .unit_price = 1.99 },
    .{ .name = "Bananas", .unit_price = 0.59 },
    .{ .name = "Milk", .unit_price = 3.49 },
    .{ .name = "Bread", .unit_price = 2.79 },
    .{ .name = "Eggs", .unit_price = 4.29 },
    .{ .name = "Chicken Breast", .unit_price = 8.99 },
    .{ .name = "Rice", .unit_price = 5.50 },
    .{ .name = "Pasta", .unit_price = 1.89 },
    .{ .name = "Cereal", .unit_price = 4.19 },
    .{ .name = "Orange Juice", .unit_price = 3.99 },
    .{ .name = "Cheese", .unit_price = 5.75 },
    .{ .name = "Yogurt", .unit_price = 1.50 },
    .{ .name = "Onions", .unit_price = 1.05 },
    .{ .name = "Potatoes", .unit_price = 2.99 },
    .{ .name = "Carrots", .unit_price = 1.35 },
    .{ .name = "Tomatoes", .unit_price = 2.49 },
    .{ .name = "Lettuce", .unit_price = 1.79 },
    .{ .name = "Ground Beef", .unit_price = 7.89 },
    .{ .name = "Butter", .unit_price = 4.50 },
    .{ .name = "Coffee", .unit_price = 9.25 },
};
