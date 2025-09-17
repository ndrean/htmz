//! Simple session utilities for user authentication only
const std = @import("std");

const SECRET_KEY = "your-simple-secret-key-12345";

pub const JWTPayload = struct {
    user_id: []const u8,
    exp: i64,
};

pub fn generateJWT(allocator: std.mem.Allocator, payload: JWTPayload) ![]u8 {
    _ = payload; // We don't use payload in simplified version

    // Generate a simple random session string
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Convert to hex string manually
    var session_id: [32]u8 = undefined;
    for (random_bytes, 0..) |byte, i| {
        _ = std.fmt.bufPrint(session_id[i*2..i*2+2], "{x:0>2}", .{byte}) catch unreachable;
    }

    // Create simple signature: HMAC of session_id
    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, &session_id, SECRET_KEY);

    // Convert signature to hex
    var signature_hex: [64]u8 = undefined;
    for (signature, 0..) |byte, i| {
        _ = std.fmt.bufPrint(signature_hex[i*2..i*2+2], "{x:0>2}", .{byte}) catch unreachable;
    }

    // Combine session_id + signature (32 + 64 hex chars = 96 total)
    const token = try std.fmt.allocPrint(allocator, "{s}{s}", .{ session_id, signature_hex });

    return token;
}

pub fn verifyJWT(allocator: std.mem.Allocator, token: []const u8) !JWTPayload {
    // Token should be 96 hex chars (32 session + 64 signature)
    if (token.len != 96) {
        return error.InvalidToken;
    }

    // Check if all characters are valid hex
    for (token) |c| {
        if (!std.ascii.isHex(c)) {
            return error.InvalidToken;
        }
    }

    // Split session_id and signature
    const session_id = token[0..32];
    const signature_hex = token[32..96];

    // Convert signature from hex back to bytes
    var signature: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&signature, signature_hex) catch return error.InvalidToken;

    // Verify signature
    var expected_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_signature, session_id, SECRET_KEY);

    if (!std.mem.eql(u8, &signature, &expected_signature)) {
        return error.InvalidSignature;
    }

    // Create user_id from session_id
    const user_id = try std.fmt.allocPrint(allocator, "user_{s}", .{session_id});

    return JWTPayload{
        .user_id = user_id,
        .exp = std.time.timestamp() + 3600, // 1 hour from now
    };
}

pub fn deinitPayload(allocator: std.mem.Allocator, payload: JWTPayload) void {
    allocator.free(payload.user_id);
}