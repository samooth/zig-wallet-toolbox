const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const brc43 = bsvz.primitives.brc43;
const crypto_hash = bsvz.crypto.hash;
const util = @import("../util.zig");

const PrivateKey = ec.PrivateKey;
const PublicKey = ec.PublicKey;

const random_len = 16;
const hmac_len = 32;
const nonce_raw_len = random_len + hmac_len; // 48 bytes
const security_level = 2;
const protocol_name = "server hmac";

/// Creates a nonce and returns it as a base64 string.
///
/// Internal format: 16 random bytes || 32-byte HMAC = 48 bytes, base64-encoded.
///
/// Derivation steps:
///   1. Generate 16 random bytes
///   2. Compute invoice number via BRC-43: formatInvoice(2, "server hmac", keyID)
///      where keyID = the raw random bytes interpreted as a string
///   3. Derive a symmetric key using BRC-42 Type-42 key derivation:
///      - derivedPriv = privateKey.deriveChild(counterpartyPubKey, invoiceNumber)
///      - derivedPub = counterpartyPubKey.deriveChild(privateKey, invoiceNumber)
///      - symmetricKey = derivedPriv.deriveSharedSecret(derivedPub) X-coordinate
///   4. HMAC-SHA256(symmetricKey, randomBytes)
///   5. Return base64(randomBytes || hmacResult)
///
/// When counterparty is null, uses the private key's own public key (self).
pub fn createNonce(allocator: std.mem.Allocator, private_key: PrivateKey, counterparty: ?PublicKey) ![]const u8 {
    var random_bytes: [random_len]u8 = undefined;
    util.randomBytes(&random_bytes);

    const hmac_result = try deriveNonceHmac(allocator, private_key, counterparty, &random_bytes);

    var raw: [nonce_raw_len]u8 = undefined;
    @memcpy(raw[0..random_len], &random_bytes);
    @memcpy(raw[random_len..], &hmac_result);

    const b64_len = std.base64.standard.Encoder.calcSize(nonce_raw_len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(b64_buf, &raw);

    return b64_buf;
}

/// Verifies a nonce by re-deriving the HMAC and comparing (constant-time).
///
///   1. Base64-decode the nonce string to get 48 raw bytes
///   2. Split: first 16 bytes = random data, remaining 32 = expected HMAC
///   3. Re-derive HMAC using same steps as createNonce
///   4. Compare derived HMAC with expected HMAC (constant-time)
pub fn verifyNonce(allocator: std.mem.Allocator, private_key: PrivateKey, nonce_b64: []const u8, counterparty: ?PublicKey) !bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(nonce_b64) catch return false;
    if (decoded_len != nonce_raw_len) return false;

    var raw: [nonce_raw_len]u8 = undefined;
    std.base64.standard.Decoder.decode(&raw, nonce_b64) catch return false;

    const random_bytes = raw[0..random_len];
    const expected_hmac = raw[random_len..nonce_raw_len];

    const derived_hmac = try deriveNonceHmac(allocator, private_key, counterparty, random_bytes);

    return std.crypto.timing_safe.eql([hmac_len]u8, expected_hmac.*, derived_hmac);
}

/// Core HMAC derivation shared by create and verify.
fn deriveNonceHmac(
    allocator: std.mem.Allocator,
    private_key: PrivateKey,
    counterparty: ?PublicKey,
    random_bytes: *const [random_len]u8,
) ![hmac_len]u8 {
    const counterparty_key = counterparty orelse try private_key.publicKey();

    // BRC-43 invoice number: "2-server hmac-<raw bytes as string>"
    const invoice = try brc43.formatInvoice(allocator, security_level, protocol_name, random_bytes);
    defer allocator.free(invoice);

    // BRC-42 derive private child key
    const derived_priv = try private_key.deriveChild(counterparty_key, invoice);
    // BRC-42 derive public child key (counterparty side)
    const derived_pub = try counterparty_key.deriveChild(private_key, invoice);

    // Symmetric key = ECDH shared secret between derived keys (X coordinate)
    const shared_point = try derived_priv.deriveSharedSecret(derived_pub);
    const compressed = shared_point.toCompressedSec1();
    // X coordinate is bytes 1..33 of compressed SEC1 (byte 0 is the prefix)
    const symmetric_key = compressed[1..33];

    // HMAC-SHA256(symmetric_key, random_bytes)
    return crypto_hash.hmacSha256(random_bytes, symmetric_key);
}

test "createNonce and verifyNonce round-trip" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();

    const nonce = try createNonce(allocator, priv, null);
    defer allocator.free(nonce);

    // Nonce should be base64, 64 chars for 48 bytes
    try std.testing.expectEqual(@as(usize, 64), nonce.len);

    // Verify with same key should succeed
    const valid = try verifyNonce(allocator, priv, nonce, null);
    try std.testing.expect(valid);

    // Verify with different key should fail
    const other_priv = try PrivateKey.generate();
    const invalid = try verifyNonce(allocator, other_priv, nonce, null);
    try std.testing.expect(!invalid);
}

test "createNonce with explicit counterparty" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();
    const counterparty_priv = try PrivateKey.generate();
    const counterparty_pub = try counterparty_priv.publicKey();

    const nonce = try createNonce(allocator, priv, counterparty_pub);
    defer allocator.free(nonce);

    const valid = try verifyNonce(allocator, priv, nonce, counterparty_pub);
    try std.testing.expect(valid);

    // Wrong counterparty should fail verification
    const wrong_pub = try (try PrivateKey.generate()).publicKey();
    const invalid = try verifyNonce(allocator, priv, nonce, wrong_pub);
    try std.testing.expect(!invalid);
}

test "verifyNonce rejects invalid base64" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();

    const result = try verifyNonce(allocator, priv, "not-valid-base64!!!", null);
    try std.testing.expect(!result);
}

test "verifyNonce rejects wrong-length nonce" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();

    // 32 bytes base64 (too short)
    const result = try verifyNonce(allocator, priv, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", null);
    try std.testing.expect(!result);
}

test "verifyNonce rejects tampered nonce" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();

    const nonce = try createNonce(allocator, priv, null);
    defer allocator.free(nonce);

    // Tamper with one character (make a mutable copy)
    var tampered = try allocator.alloc(u8, nonce.len);
    defer allocator.free(tampered);
    @memcpy(tampered, nonce);
    // Flip a character in the HMAC portion (past the first ~21 chars which encode the random bytes)
    tampered[30] = if (tampered[30] == 'A') 'B' else 'A';

    const result = try verifyNonce(allocator, priv, tampered, null);
    try std.testing.expect(!result);
}
