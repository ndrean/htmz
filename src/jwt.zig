//! JWT utilities for stateless authentication
const std = @import("std");

const JWT_SECRET = "your-super-secret-key-12345";

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
    // Generate actual JWT with real payload data
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

    // Build cart JSON array
    var cart_json: std.ArrayList(u8) = .empty;
    defer cart_json.deinit(allocator);

    try cart_json.appendSlice(allocator, "[");
    for (payload.cart, 0..) |item, i| {
        if (i > 0) try cart_json.appendSlice(allocator, ",");
        const item_json = try std.fmt.allocPrint(allocator,
            "{{\"id\":{d},\"name\":\"{s}\",\"quantity\":{d},\"price\":{d:.2}}}",
            .{ item.id, item.name, item.quantity, item.price });
        defer allocator.free(item_json);
        try cart_json.appendSlice(allocator, item_json);
    }
    try cart_json.appendSlice(allocator, "]");

    const payload_json = try std.fmt.allocPrint(allocator,
        "{{\"user_id\":\"{s}\",\"cart\":{s},\"exp\":{d}}}",
        .{ payload.user_id, cart_json.items, payload.exp });
    defer allocator.free(payload_json);

    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    const payload_b64 = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);

    // Data to sign
    const data = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(data);

    // Sign with HMAC-SHA256
    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, data, JWT_SECRET);
    const signature_b64 = try base64UrlEncode(allocator, &signature);
    defer allocator.free(signature_b64);

    // Final JWT
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ data, signature_b64 });
}

pub fn verifyJWT(allocator: std.mem.Allocator, token: []const u8) !JWTPayload {
    // Split token
    var parts = std.mem.splitSequence(u8, token, ".");
    const header_b64 = parts.next() orelse return error.InvalidToken;
    const payload_b64 = parts.next() orelse return error.InvalidToken;
    const signature_b64 = parts.next() orelse return error.InvalidToken;

    // Verify signature
    const data = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(data);

    var expected_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_signature, data, JWT_SECRET);
    const expected_signature_b64 = try base64UrlEncode(allocator, &expected_signature);
    defer allocator.free(expected_signature_b64);

    if (!std.mem.eql(u8, signature_b64, expected_signature_b64)) {
        return error.InvalidSignature;
    }

    // Decode payload
    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    const parsed = try std.json.parseFromSlice(JWTPayload, allocator, payload_json, .{});
    defer parsed.deinit();

    // Check expiration
    const now = std.time.timestamp();
    if (parsed.value.exp < now) {
        return error.TokenExpired;
    }

    return parsed.value;
}