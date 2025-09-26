//! Simple session utilities for user authentication only
const std = @import("std");

const DEFAULT_SECRET_KEY = "secret-key-12345-dev-only";

fn getSecretKey(allocator: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(allocator, "SECRET_KEY") catch DEFAULT_SECRET_KEY;
}

pub const JWTPayload = struct {
    user_id: []const u8,
    exp: i64,
};

/// We generate a simplified JWT-like token for session management
///
/// The token is not a standard JWT, but a custom format for simplicity
///
/// The token is a hex string of 96 characters (48 bytes)
/// The token consists of:
/// - a random session_id, random 16-byte value represented as 32 hex characters
/// - followed by its HMAC-SHA256 signature using SECRET_KEY, represented as 64 hex characters
///
/// Hex characters are safe in HTTP headers and cookies.
///
/// Total token length is 96 hex characters. No padding, no base64, just hex.
pub fn generateJWT(allocator: std.mem.Allocator, _: JWTPayload) ![]u8 {

    // Generate a simple random session string
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Convert to hex string manually
    var session_id: [32]u8 = undefined;
    for (random_bytes, 0..) |byte, i| {
        _ = std.fmt.bufPrint(session_id[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }

    // Create simple signature: HMAC of session_id
    const secret_key = getSecretKey(allocator);
    defer if (secret_key.ptr != DEFAULT_SECRET_KEY.ptr) allocator.free(secret_key);

    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, &session_id, secret_key);

    // Convert signature to hex
    var signature_hex: [64]u8 = undefined;
    for (signature, 0..) |byte, i| {
        _ = std.fmt.bufPrint(signature_hex[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }

    // Combine session_id + signature (32 + 64 hex chars = 96 total)
    const token = try std.fmt.allocPrint(allocator, "{s}{s}", .{ session_id, signature_hex });

    return token;
}

/// Verify the JWT token and return the payload if valid
/// In this simplified version, we only check the signature and return a dummy user_id
/// In a real implementation, you would decode the payload and verify the exp field
/// Here, we assume the user_id is embedded in the session_id for demonstration purposes
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
    const secret_key = getSecretKey(allocator);
    defer if (secret_key.ptr != DEFAULT_SECRET_KEY.ptr) allocator.free(secret_key);

    var expected_signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_signature, session_id, secret_key);

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
