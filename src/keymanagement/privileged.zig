const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const keyshares = bsvz.primitives.keyshares;
const symmetric = bsvz.primitives.symmetric;
const util = @import("../util.zig");
const WalletStorageManager = @import("../storage/manager.zig").WalletStorageManager;

/// Invoice used to derive the privileged key from the wallet master key (BRC-42 child derivation).
/// This constant is specific to this implementation; align it with go-wallet-toolbox if
/// cross-implementation parity of the privileged key is required.
const PRIVILEGED_INVOICE = "bsv-wallet-toolbox:privileged-key";

/// secp256k1 field prime (from bsvz.keyshares.Curve).
const P = keyshares.Curve.p;

/// Modular arithmetic over the secp256k1 field prime, implemented with u512 intermediates so
/// it never overflows (unlike bsvz.keyshares' field helpers, which rely on wrapping that panics
/// under Zig's safe build modes).
fn modAdd(a: u256, b: u256) u256 {
    return @intCast((@as(u512, a) + b) % P);
}

fn modSub(a: u256, b: u256) u256 {
    if (a >= b) return a - b;
    return P - (b - a);
}

fn modMul(a: u256, b: u256) u256 {
    return @intCast((@as(u512, a) * b) % P);
}

fn modPow(base: u256, exp: u256) u256 {
    var result: u256 = 1;
    var b = base % P;
    var e = exp;
    while (e != 0) : (e >>= 1) {
        if ((e & 1) == 1) result = modMul(result, b);
        b = modMul(b, b);
    }
    return result;
}

fn modInv(a: u256) u256 {
    if (a == 0) return 0;
    return modPow(a, P - 2);
}

/// Lagrange interpolation: evaluate the degree-(threshold-1) polynomial defined by the first
/// `threshold` points at `x`. Recovers the shared secret when `x == 0`.
fn lagrangeValueAt(points: []const keyshares.Point, threshold: usize, x: u256) u256 {
    if (threshold == 0) return 0;
    var y: u256 = 0;
    var i: usize = 0;
    while (i < threshold) : (i += 1) {
        var term = points[i].y;
        var j: usize = 0;
        while (j < threshold) : (j += 1) {
            if (i == j) continue;
            const numerator = modSub(x, points[j].x);
            const denominator = modInv(modSub(points[i].x, points[j].x));
            term = modMul(term, modMul(numerator, denominator));
        }
        y = modAdd(y, term);
    }
    return y;
}

/// Split a 32-byte secret into `total` Shamir shares, of which `threshold` are required to
/// reconstruct it. Returns a `keyshares.KeyShares` whose `points` slice is owned by `allocator`
/// (the caller must free it). Serialization uses `bsvz.primitives.keyshares` (backup format);
/// the polynomial math is done with overflow-safe modular arithmetic.
pub fn splitShares(allocator: std.mem.Allocator, secret: [32]u8, total: usize, threshold: usize) !keyshares.KeyShares {
    if (threshold < 2) return error.InvalidThreshold;
    if (total < threshold) return error.InvalidThreshold;

    const s = std.mem.readInt(u256, &secret, .big);

    // Defining points: (0, secret) plus (threshold-1) points with fixed distinct x in
    // [total+1, total+threshold-1] and random y. The random y's make the polynomial random.
    var defining = try allocator.alloc(keyshares.Point, threshold);
    errdefer allocator.free(defining);

    defining[0] = keyshares.Point.new(0, s);
    var i: usize = 1;
    while (i < threshold) : (i += 1) {
        var ry: [32]u8 = undefined;
        util.randomBytes(&ry);
        const y = std.mem.readInt(u256, &ry, .big);
        const x: u256 = total + i;
        defining[i] = keyshares.Point.new(x, y);
    }

    // Generate `total` shares at distinct x in [1, total].
    var points = try allocator.alloc(keyshares.Point, total);
    errdefer allocator.free(points);
    var j: usize = 0;
    while (j < total) : (j += 1) {
        const x: u256 = j + 1;
        const y = lagrangeValueAt(defining, threshold, x);
        points[j] = keyshares.Point.new(x, y);
    }

    var integrity: [8]u8 = undefined;
    util.randomBytes(&integrity);
    // The bsvz backup format is dot-separated ("x.y.threshold.integrity") with the
    // integrity serialized as raw bytes; a '.' (0x2E) byte would corrupt parsing in
    // fromBackupFormat (split on '.' yields too many parts). Remap it to a safe byte
    // (~3.1% of random 8-byte values would otherwise be unparseable).
    for (&integrity) |*b| {
        if (b.* == '.') b.* = '0';
    }

    return keyshares.KeyShares{ .points = points, .threshold = threshold, .integrity = integrity };
}

/// Reconstruct the original 32-byte secret from `threshold` or more backup share strings
/// (as produced by `keyshares.KeyShares.toBackupFormat`).
pub fn reconstructSecret(allocator: std.mem.Allocator, backup_shares: []const []const u8) ![32]u8 {
    const ks = try keyshares.KeyShares.fromBackupFormat(allocator, backup_shares);
    defer allocator.free(ks.points);

    if (ks.points.len < ks.threshold) return error.NotEnoughShares;

    const secret_u256 = lagrangeValueAt(ks.points[0..ks.threshold], ks.threshold, 0);

    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, secret_u256, .big);
    return buf;
}

/// Manages a BRC-42 derived privileged key: splits it into Shamir shares (persisted via the
/// active storage provider) and reconstructs it from a threshold of shares on demand.
pub const PrivilegedKeyManager = struct {
    allocator: std.mem.Allocator,
    master_key: ec.PrivateKey,
    storage: *WalletStorageManager,
    identity_key: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        master_key: ec.PrivateKey,
        storage: *WalletStorageManager,
        identity_key: []const u8,
    ) PrivilegedKeyManager {
        return .{
            .allocator = allocator,
            .master_key = master_key,
            .storage = storage,
            .identity_key = identity_key,
        };
    }

    /// Derive the privileged key from the wallet master key via BRC-42 child derivation.
    pub fn derivePrivilegedKey(self: *const PrivilegedKeyManager) !ec.PrivateKey {
        const pubkey = try self.master_key.publicKey();
        return self.master_key.deriveChild(pubkey, PRIVILEGED_INVOICE);
    }

    /// Derive the privileged key, split it into `total` shares (threshold reconstruct), and
    /// persist them under the manager's identity key.
    pub fn splitAndStore(self: *PrivilegedKeyManager, total: usize, threshold: usize) !void {
        const pk = try self.derivePrivilegedKey();
        const secret = pk.toBytes();
        const shares = try splitShares(self.allocator, secret, total, threshold);
        defer self.allocator.free(shares.points);

        const backup = try shares.toBackupFormat(self.allocator);
        defer {
            for (backup) |s| self.allocator.free(s);
            self.allocator.free(backup);
        }

        try self.storage.storeKeyShares(self.allocator, .{ .identity_key = self.identity_key }, backup);
    }

    /// Load the persisted shares for this identity and reconstruct the privileged key.
    pub fn getPrivilegedKey(self: *PrivilegedKeyManager) !ec.PrivateKey {
        const backup = try self.storage.loadKeyShares(self.allocator, .{ .identity_key = self.identity_key });
        defer {
            for (backup) |s| self.allocator.free(s);
            self.allocator.free(backup);
        }
        const secret = try reconstructSecret(self.allocator, backup);
        return ec.PrivateKey.fromBytes(secret);
    }

    /// Encrypt `plaintext` under the wallet's privileged key (AES-GCM via the bsvz symmetric
    /// primitive). Returns owned ciphertext (caller frees). Does not require shares to be
    /// stored — the privileged key is derived directly from the master key (BRC-42).
    pub fn encrypt(self: *const PrivilegedKeyManager, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const pk = try self.derivePrivilegedKey();
        const key_bytes = pk.toBytes();
        const sk = symmetric.SymmetricKey.newFromBytes(&key_bytes);
        return sk.encrypt(allocator, plaintext);
    }

    /// Decrypt ciphertext produced by `encrypt` (or any BRC-42 privileged-key encryption).
    /// Returns owned plaintext (caller frees).
    pub fn decrypt(self: *const PrivilegedKeyManager, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        const pk = try self.derivePrivilegedKey();
        const key_bytes = pk.toBytes();
        const sk = symmetric.SymmetricKey.newFromBytes(&key_bytes);
        return sk.decrypt(allocator, ciphertext);
    }
};
