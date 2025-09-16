//! Binary token utilities for stateless authentication
const std = @import("std");

const TOKEN_SECRET = "your-super-secret-key-12345";

// Compact binary cart item (2 bytes total)
const CartItemBinary = packed struct {
    id: u8,        // item ID (0-7 for our 8 items)
    quantity: u8,  // quantity (1-255)
};

pub const CartItem = struct {
    id: u32,
    name: []const u8,
    quantity: u32,
    price: f32,
};

pub const JWTPayload = struct {
    user_id: []const u8,
    cart: []CartItem,
    exp: i64,
};

// Binary token structure
const BinaryTokenHeader = packed struct {
    user_id_len: u32,
    cart_count: u8,
    exp: u64,  // timestamp
};

fn serializeBinaryToken(allocator: std.mem.Allocator, payload: JWTPayload) ![]u8 {
    const header = BinaryTokenHeader{
        .user_id_len = @intCast(payload.user_id.len),
        .cart_count = @intCast(payload.cart.len),
        .exp = @intCast(payload.exp),
    };

    // Calculate total size
    const total_size = @sizeOf(BinaryTokenHeader) + payload.user_id.len + (payload.cart.len * @sizeOf(CartItemBinary));

    var token_data = try allocator.alloc(u8, total_size);
    var offset: usize = 0;

    // Write header
    @memcpy(token_data[offset..offset + @sizeOf(BinaryTokenHeader)], std.mem.asBytes(&header));
    offset += @sizeOf(BinaryTokenHeader);

    // Write user_id
    @memcpy(token_data[offset..offset + payload.user_id.len], payload.user_id);
    offset += payload.user_id.len;

    // Write cart items
    for (payload.cart) |item| {
        const binary_item = CartItemBinary{
            .id = @intCast(item.id),
            .quantity = @intCast(item.quantity),
        };
        @memcpy(token_data[offset..offset + @sizeOf(CartItemBinary)], std.mem.asBytes(&binary_item));
        offset += @sizeOf(CartItemBinary);
    }

    return token_data;
}

fn deserializeBinaryToken(allocator: std.mem.Allocator, token_data: []const u8) !JWTPayload {
    if (token_data.len < @sizeOf(BinaryTokenHeader)) return error.InvalidToken;

    var offset: usize = 0;

    // Read header
    const header = std.mem.bytesToValue(BinaryTokenHeader, token_data[offset..offset + @sizeOf(BinaryTokenHeader)]);
    offset += @sizeOf(BinaryTokenHeader);

    // Check if we have enough data
    const expected_size = @sizeOf(BinaryTokenHeader) + header.user_id_len + (header.cart_count * @sizeOf(CartItemBinary));
    if (token_data.len != expected_size) return error.InvalidToken;

    // Read user_id
    const user_id = try allocator.dupe(u8, token_data[offset..offset + header.user_id_len]);
    offset += header.user_id_len;

    // Read cart items
    var cart = try allocator.alloc(CartItem, header.cart_count);
    for (0..header.cart_count) |i| {
        const binary_item = std.mem.bytesToValue(CartItemBinary, token_data[offset..offset + @sizeOf(CartItemBinary)]);
        offset += @sizeOf(CartItemBinary);

        // Convert to full CartItem (we'll need item names from a lookup table)
        cart[i] = CartItem{
            .id = binary_item.id,
            .name = getItemName(binary_item.id), // Will implement this
            .quantity = binary_item.quantity,
            .price = getItemPrice(binary_item.id), // Will implement this
        };
    }

    return JWTPayload{
        .user_id = user_id,
        .cart = cart,
        .exp = @intCast(header.exp),
    };
}

// Helper functions to get item data by ID
fn getItemName(id: u8) []const u8 {
    const items = [_][]const u8{
        "Apples", "Bananas", "Bread", "Milk", "Eggs", "Cheese", "Chicken", "Rice"
    };
    if (id < items.len) return items[id];
    return "Unknown";
}

fn getItemPrice(id: u8) f32 {
    const prices = [_]f32{
        2.99, 1.99, 3.49, 4.99, 3.99, 5.49, 8.99, 2.49
    };
    if (id < prices.len) return prices[id];
    return 0.0;
}

pub fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, data);
    return encoded;
}

pub fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(data);
    const decoded = try allocator.alloc(u8, decoded_len);
    try decoder.decode(decoded, data);
    return decoded;
}

pub fn generateJWT(allocator: std.mem.Allocator, payload: JWTPayload) ![]u8 {
    // Serialize to binary format
    const binary_data = try serializeBinaryToken(allocator, payload);
    defer allocator.free(binary_data);

    // Sign the binary data with HMAC-SHA256
    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, binary_data, TOKEN_SECRET);

    // Combine binary data + signature
    const total_len = binary_data.len + signature.len;
    var token_with_sig = try allocator.alloc(u8, total_len);
    @memcpy(token_with_sig[0..binary_data.len], binary_data);
    @memcpy(token_with_sig[binary_data.len..], &signature);

    // Base64 encode the entire token for HTTP cookie safety
    const final_token = try base64UrlEncode(allocator, token_with_sig);
    allocator.free(token_with_sig);

    return final_token;
}

pub fn verifyJWT(allocator: std.mem.Allocator, token: []const u8) !JWTPayload {
    // Decode from base64
    const token_with_sig = try base64UrlDecode(allocator, token);
    defer allocator.free(token_with_sig);

    // Check minimum size (header + signature)
    if (token_with_sig.len < @sizeOf(BinaryTokenHeader) + 32) {
        return error.InvalidToken;
    }

    // Split data and signature
    const data_len = token_with_sig.len - 32;
    const binary_data = token_with_sig[0..data_len];
    const signature = token_with_sig[data_len..data_len + 32];

    // Verify signature
    var expected_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_signature, binary_data, TOKEN_SECRET);

    if (!std.mem.eql(u8, signature, &expected_signature)) {
        return error.InvalidSignature;
    }

    // Deserialize binary data
    const payload = try deserializeBinaryToken(allocator, binary_data);

    // Check expiration
    const now = std.time.timestamp();
    if (payload.exp < now) {
        deinitPayload(allocator, payload);
        return error.TokenExpired;
    }

    return payload;
}

pub fn deinitPayload(allocator: std.mem.Allocator, payload: JWTPayload) void {
    // Free the cloned user_id
    allocator.free(payload.user_id);

    // Free the cloned cart items
    for (payload.cart) |item| {
        allocator.free(item.name);
    }
    allocator.free(payload.cart);
}