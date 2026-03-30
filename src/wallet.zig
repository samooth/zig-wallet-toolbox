const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const hex = bsvz.primitives.hex;
const crypto_hash = bsvz.crypto.hash;
const sig_mod = bsvz.crypto.signature;
const key_deriver_mod = bsvz.primitives.key_deriver;

const services = @import("services/lib.zig");
const storage = @import("storage/lib.zig");
const signer = @import("signer/lib.zig");

pub const Chain = enum { main, @"test" };

pub const WalletConfig = struct {
    private_key: ec.PrivateKey,
    chain: Chain,
    wallet_services: services.WalletServices,
    storage_manager: storage.WalletStorageManager,
};

pub const ListOutputsArgs = struct {
    basket: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    spendable: ?bool = null,
    limit: ?u32 = null,
    offset: ?u32 = null,

    pub fn toJson(self: ListOutputsArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);

        if (self.basket) |basket| {
            try obj.put("basket", .{ .string = basket });
        }
        if (self.tags) |tags| {
            var arr = std.json.Array.init(allocator);
            for (tags) |tag| {
                try arr.append(.{ .string = tag });
            }
            try obj.put("tags", .{ .array = arr });
        }
        if (self.spendable) |spendable| {
            try obj.put("spendable", .{ .bool = spendable });
        }
        if (self.limit) |limit| {
            try obj.put("limit", .{ .integer = @intCast(limit) });
        }
        if (self.offset) |offset| {
            try obj.put("offset", .{ .integer = @intCast(offset) });
        }

        return .{ .object = obj };
    }
};

pub const ListActionsArgs = struct {
    labels: ?[]const []const u8 = null,
    limit: ?u32 = null,
    offset: ?u32 = null,

    pub fn toJson(self: ListActionsArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);

        if (self.labels) |labels| {
            var arr = std.json.Array.init(allocator);
            for (labels) |label| {
                try arr.append(.{ .string = label });
            }
            try obj.put("labels", .{ .array = arr });
        }
        if (self.limit) |limit| {
            try obj.put("limit", .{ .integer = @intCast(limit) });
        }
        if (self.offset) |offset| {
            try obj.put("offset", .{ .integer = @intCast(offset) });
        }

        return .{ .object = obj };
    }
};

pub const BalanceResult = struct {
    confirmed: i64,
    unconfirmed: i64,
};

pub const GetPublicKeyArgs = struct {
    protocol_id: []const u8 = "",
    key_id: []const u8 = "",
    security_level: u8 = 0,
    for_self: bool = true,
    counterparty: ?[]const u8 = null, // hex pubkey if not forSelf
};

pub const GetPublicKeyResult = struct {
    public_key: [66]u8, // hex-encoded compressed pubkey
};

pub const Wallet = struct {
    allocator: std.mem.Allocator,
    private_key: ec.PrivateKey,
    identity_key: [66]u8,
    chain: Chain,
    wallet_services: services.WalletServices,
    storage_manager: storage.WalletStorageManager,

    pub fn init(allocator: std.mem.Allocator, config: WalletConfig) !Wallet {
        const pub_key = try config.private_key.publicKey();
        const compressed = pub_key.toCompressedSec1();
        var identity_hex: [66]u8 = undefined;
        _ = try hex.encodeLower(&compressed, &identity_hex);

        return .{
            .allocator = allocator,
            .private_key = config.private_key,
            .identity_key = identity_hex,
            .chain = config.chain,
            .wallet_services = config.wallet_services,
            .storage_manager = config.storage_manager,
        };
    }

    pub fn deinit(self: *Wallet) void {
        self.storage_manager.deinit();
    }

    pub fn getPublicKey(self: *const Wallet) []const u8 {
        return &self.identity_key;
    }

    pub fn createSignature(self: *const Wallet, data: []const u8) !sig_mod.DerSignature {
        const digest = crypto_hash.hash256(data);
        return self.private_key.signDigest(digest.bytes);
    }

    pub fn verifySignature(_: *const Wallet, data: []const u8, signature: sig_mod.DerSignature, pubkey: ec.PublicKey) !bool {
        const digest = crypto_hash.hash256(data);
        return pubkey.verifyDigest(digest.bytes, signature);
    }

    fn authId(self: *const Wallet) storage.types.AuthId {
        return .{ .identity_key = &self.identity_key };
    }

    pub fn createAction(self: *Wallet, args: signer.types.CreateActionArgs) !signer.types.CreateActionResult {
        const args_json = try args.toJson(self.allocator);
        const result = try self.storage_manager.createAction(self.allocator, self.authId(), args_json);
        return .{ .raw = result };
    }

    pub fn signAction(self: *Wallet, args: signer.types.SignActionArgs) !signer.types.SignActionResult {
        const args_json = try args.toJson(self.allocator);
        const result = try self.storage_manager.processAction(self.allocator, self.authId(), args_json);
        return .{ .raw = result };
    }

    pub fn abortAction(self: *Wallet, reference: []const u8) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        try obj.put("reference", .{ .string = reference });
        const args_json: std.json.Value = .{ .object = obj };
        return self.storage_manager.abortAction(self.allocator, self.authId(), args_json);
    }

    pub fn listOutputs(self: *Wallet, args: ListOutputsArgs) !std.json.Value {
        const args_json = try args.toJson(self.allocator);
        return self.storage_manager.listOutputs(self.allocator, self.authId(), args_json);
    }

    pub fn listActions(self: *Wallet, args: ListActionsArgs) !std.json.Value {
        const args_json = try args.toJson(self.allocator);
        return self.storage_manager.listActions(self.allocator, self.authId(), args_json);
    }

    /// Get the wallet's balance by summing spendable outputs from the default basket.
    /// Returns confirmed and unconfirmed totals (unconfirmed is 0 for now).
    pub fn getBalance(self: *Wallet) !BalanceResult {
        const result = try self.listOutputs(.{
            .basket = "default",
            .limit = 1000,
            .spendable = true,
        });

        var confirmed: i64 = 0;

        if (result == .object) {
            if (result.object.get("outputs")) |outputs_val| {
                if (outputs_val == .array) {
                    for (outputs_val.array.items) |item| {
                        if (item == .object) {
                            const spendable = if (item.object.get("spendable")) |s| s == .bool and s.bool else false;
                            const sats: i64 = if (item.object.get("satoshis")) |s| switch (s) {
                                .integer => |i| i,
                                else => 0,
                            } else 0;
                            if (spendable) confirmed += sats;
                        }
                    }
                }
            }
        }

        return .{ .confirmed = confirmed, .unconfirmed = 0 };
    }

    /// Derive a protocol-scoped public key using BRC-42/43 via bsvz KeyDeriver.
    pub fn getDerivedPublicKey(self: *const Wallet, args: GetPublicKeyArgs) !GetPublicKeyResult {
        const kd = key_deriver_mod.KeyDeriver.init(self.private_key);

        const counterparty: key_deriver_mod.Counterparty = if (args.for_self)
            .{ .type_ = .self }
        else blk: {
            const cp_hex = args.counterparty orelse return error.InvalidEncoding;
            const cp_pub = try ec.PublicKey.fromHex(cp_hex);
            break :blk .{ .type_ = .other, .public_key = cp_pub };
        };

        const protocol = key_deriver_mod.Protocol{
            .security_level = args.security_level,
            .name = args.protocol_id,
        };

        const derived = try kd.derivePublicKey(
            self.allocator,
            protocol,
            args.key_id,
            counterparty,
            args.for_self,
        );

        const compressed = derived.toCompressedSec1();
        var hex_buf: [66]u8 = undefined;
        _ = try hex.encodeLower(&compressed, &hex_buf);
        return .{ .public_key = hex_buf };
    }
};

test "Wallet init derives identity key" {
    const allocator = std.testing.allocator;
    const private_key = try ec.PrivateKey.fromBytes([_]u8{0x01} ** 32);

    const mgr = storage.WalletStorageManager.init(allocator);

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = mgr,
    });
    defer wallet.deinit();

    const identity = wallet.getPublicKey();
    try std.testing.expectEqual(@as(usize, 66), identity.len);
    // Compressed pubkey hex starts with 02 or 03
    try std.testing.expect(identity[0] == '0' and (identity[1] == '2' or identity[1] == '3'));
}

test "Wallet createSignature produces valid DER" {
    const private_key = try ec.PrivateKey.fromBytes([_]u8{0x01} ** 32);
    const allocator = std.testing.allocator;

    const mgr = storage.WalletStorageManager.init(allocator);

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = mgr,
    });
    defer wallet.deinit();

    const der_sig = try wallet.createSignature("hello world");
    // DER signature starts with 0x30
    try std.testing.expectEqual(@as(u8, 0x30), der_sig.bytes[0]);
    try std.testing.expect(der_sig.len > 0 and der_sig.len <= 72);
}

test "Wallet verifySignature roundtrip" {
    const private_key = try ec.PrivateKey.fromBytes([_]u8{0x01} ** 32);
    const allocator = std.testing.allocator;

    const mgr = storage.WalletStorageManager.init(allocator);

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = mgr,
    });
    defer wallet.deinit();

    const message = "test message";
    const der_sig = try wallet.createSignature(message);
    const pub_key = try private_key.publicKey();
    const valid = try wallet.verifySignature(message, der_sig, pub_key);
    try std.testing.expect(valid);
}

test "Wallet getDerivedPublicKey for self" {
    const private_key = try ec.PrivateKey.fromBytes([_]u8{0x01} ** 32);
    const allocator = std.testing.allocator;

    const mgr = storage.WalletStorageManager.init(allocator);

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = mgr,
    });
    defer wallet.deinit();

    const result = try wallet.getDerivedPublicKey(.{
        .protocol_id = "testprotocol",
        .key_id = "12345",
        .security_level = 0,
        .for_self = true,
    });

    try std.testing.expectEqual(@as(usize, 66), result.public_key.len);
    try std.testing.expect(result.public_key[0] == '0' and (result.public_key[1] == '2' or result.public_key[1] == '3'));
}

test "Wallet getDerivedPublicKey for counterparty" {
    const allocator = std.testing.allocator;
    const private_key = try ec.PrivateKey.fromBytes([_]u8{0x01} ** 32);
    const cp_key = try ec.PrivateKey.fromBytes([_]u8{0x02} ** 32);
    const cp_pub = try cp_key.publicKey();
    var cp_hex: [66]u8 = undefined;
    _ = try hex.encodeLower(&cp_pub.toCompressedSec1(), &cp_hex);

    const mgr = storage.WalletStorageManager.init(allocator);

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = mgr,
    });
    defer wallet.deinit();

    const result = try wallet.getDerivedPublicKey(.{
        .protocol_id = "testprotocol",
        .key_id = "12345",
        .security_level = 0,
        .for_self = false,
        .counterparty = &cp_hex,
    });

    try std.testing.expectEqual(@as(usize, 66), result.public_key.len);
    try std.testing.expect(result.public_key[0] == '0' and (result.public_key[1] == '2' or result.public_key[1] == '3'));
}
