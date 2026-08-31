const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const hex = bsvz.primitives.hex;
const brc43 = bsvz.primitives.brc43;
const crypto_hash = bsvz.crypto.hash;
const sig_mod = bsvz.crypto.signature;

const services = @import("services/lib.zig");
const storage = @import("storage/lib.zig");
const signer = @import("signer/lib.zig");
const PrivilegedKeyManager = @import("keymanagement/privileged.zig").PrivilegedKeyManager;
const pending = @import("wallet/pending_sign_actions.zig");

pub const Chain = enum { main, @"test" };

pub const pending_sign_actions = pending;
pub const PendingSignActionsRepo = pending.PendingSignActionsRepo;

pub const WalletConfig = struct {
    private_key: ec.PrivateKey,
    chain: Chain,
    wallet_services: services.WalletServices,
    storage_manager: storage.WalletStorageManager,
    /// Optional pending-sign-actions repository (SQLite-backed). When set,
    /// createAction persists its assembled state under the storage reference
    /// so signAction/abortAction flows can retrieve it (Go SDK parity).
    pending_actions: ?*pending.PendingSignActionsRepo = null,
};

pub const ListOutputsArgs = struct {
    basket: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    spendable: ?bool = null,
    limit: ?u32 = null,
    offset: ?u32 = null,

    pub fn toJson(self: ListOutputsArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        if (self.basket) |basket| {
            try obj.put(allocator, "basket", .{ .string = basket });
        }
        if (self.tags) |tags| {
            var arr = std.json.Array.init(allocator);
            for (tags) |tag| {
                try arr.append(.{ .string = tag });
            }
            try obj.put(allocator, "tags", .{ .array = arr });
        }
        if (self.spendable) |spendable| {
            try obj.put(allocator, "spendable", .{ .bool = spendable });
        }
        if (self.limit) |limit| {
            try obj.put(allocator, "limit", .{ .integer = @intCast(limit) });
        }
        if (self.offset) |offset| {
            try obj.put(allocator, "offset", .{ .integer = @intCast(offset) });
        }

        return .{ .object = obj };
    }
};

pub const ListActionsArgs = struct {
    labels: ?[]const []const u8 = null,
    limit: ?u32 = null,
    offset: ?u32 = null,

    pub fn toJson(self: ListActionsArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        if (self.labels) |labels| {
            var arr = std.json.Array.init(allocator);
            for (labels) |label| {
                try arr.append(.{ .string = label });
            }
            try obj.put(allocator, "labels", .{ .array = arr });
        }
        if (self.limit) |limit| {
            try obj.put(allocator, "limit", .{ .integer = @intCast(limit) });
        }
        if (self.offset) |offset| {
            try obj.put(allocator, "offset", .{ .integer = @intCast(offset) });
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
    pending_actions: ?*pending.PendingSignActionsRepo = null,

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
            .pending_actions = config.pending_actions,
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
        defer {
            var mut = args_json;
            if (mut == .object) mut.object.deinit(self.allocator);
        }
        const result = try self.storage_manager.createAction(self.allocator, self.authId(), args_json);

        // Persist the pending sign action (Go SDK parity): the assembled
        // create-result plus the original args, keyed by storage reference.
        if (self.pending_actions) |repo| {
            const create_result = signer.types.CreateActionResult{ .raw = result };
            if (create_result.getReference()) |ref| {
                var result_buf = std.Io.Writer.Allocating.init(self.allocator);
                defer result_buf.deinit();
                var w: std.json.Stringify = .{ .writer = &result_buf.writer, .options = .{} };
                w.write(result) catch {
                    // Serialization failure is non-fatal for the action itself.
                    return .{ .raw = result };
                };
                var args_buf = std.Io.Writer.Allocating.init(self.allocator);
                defer args_buf.deinit();
                var aw: std.json.Stringify = .{ .writer = &args_buf.writer, .options = .{} };
                aw.write(args_json) catch {};

                const res_str = self.allocator.dupe(u8, result_buf.written()) catch "";
                const args_str = self.allocator.dupe(u8, args_buf.written()) catch "";
                defer if (res_str.len > 0) self.allocator.free(res_str);
                defer if (args_str.len > 0) self.allocator.free(args_str);
                if (res_str.len > 0 and args_str.len > 0) {
                    repo.save(.{
                        .reference = ref,
                        .identity_key = &self.identity_key,
                        .tx_json = res_str,
                        .create_args_json = args_str,
                        .input_beef = null,
                    }) catch |err| {
                        std.log.warn("pending sign action save failed for {s}: {s}", .{ ref, @errorName(err) });
                    };
                }
            }
        }

        return .{ .raw = result };
    }

    pub fn signAction(self: *Wallet, args: signer.types.SignActionArgs) !signer.types.SignActionResult {
        const args_json = try args.toJson(self.allocator);
        defer {
            var mut = args_json;
            if (mut == .object) mut.object.deinit(self.allocator);
        }
        const result = try self.storage_manager.processAction(self.allocator, self.authId(), args_json);

        // The pending action is consumed by a successful sign (Go SDK parity).
        if (self.pending_actions) |repo| {
            repo.delete(args.reference) catch |err| {
                std.log.warn("pending sign action delete failed for {s}: {s}", .{ args.reference, @errorName(err) });
            };
        }

        return .{ .raw = result };
    }

    pub fn abortAction(self: *Wallet, reference: []const u8) !std.json.Value {
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "reference", .{ .string = reference });
        const args_json: std.json.Value = .{ .object = obj };
        defer obj.deinit(self.allocator);

        // Abandoning releases the pending action (Go SDK parity).
        if (self.pending_actions) |repo| {
            repo.delete(reference) catch {};
        }

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

    /// List actions restricted to status 'failed' (TS SDK semantics:
    /// listActions with the reserved spec-op label appended; storage
    /// interprets the label and filters the status).
    /// With `unfail = true`, the matched 'failed' actions are moved to
    /// status 'unfail', queueing them for recovery by the Monitor.
    pub fn listFailedActions(self: *Wallet, args: ListActionsArgs, unfail: bool) !std.json.Value {
        const base_labels: []const []const u8 = args.labels orelse &[_][]const u8{};
        const labels = try self.allocator.alloc([]const u8, base_labels.len + 1 + @intFromBool(unfail));
        defer self.allocator.free(labels);
        @memcpy(labels[0..base_labels.len], base_labels);
        labels[base_labels.len] = storage.types.spec_op_failed_actions;
        if (unfail) labels[base_labels.len + 1] = storage.types.spec_op_failed_actions_unfail;

        const args_json = try (ListActionsArgs{
            .labels = labels,
            .limit = args.limit,
            .offset = args.offset,
        }).toJson(self.allocator);
        return self.storage_manager.listActions(self.allocator, self.authId(), args_json);
    }

    /// Relinquish an output from a basket: stop tracking it without spending.
    /// `txid` is the display-order hex txid; returns how many outputs were
    /// relinquished (0 or 1).
    pub fn relinquishOutput(self: *Wallet, basket: []const u8, txid: []const u8, vout: u32) !u64 {
        return self.storage_manager.relinquishOutput(self.allocator, self.authId(), basket, txid, vout);
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

    /// Derive a protocol-scoped public key using BRC-42/43.
    pub fn getDerivedPublicKey(self: *const Wallet, args: GetPublicKeyArgs) !GetPublicKeyResult {
        const invoice = try brc43.formatInvoice(self.allocator, args.security_level, args.protocol_id, args.key_id);
        defer self.allocator.free(invoice);

        const derived_pub = blk: {
            if (args.for_self) {
                const own_pub = try self.private_key.publicKey();
                const child = try self.private_key.deriveChild(own_pub, invoice);
                break :blk try child.publicKey();
            }
            const cp_hex = args.counterparty orelse return error.InvalidEncoding;
            const cp_pub = try ec.PublicKey.fromHex(cp_hex);
            break :blk try cp_pub.deriveChild(self.private_key, invoice);
        };

        const compressed = derived_pub.toCompressedSec1();
        var hex_buf: [66]u8 = undefined;
        _ = try hex.encodeLower(&compressed, &hex_buf);
        return .{ .public_key = hex_buf };
    }

    /// Returns a `PrivilegedKeyManager` bound to this wallet's master key, storage, and identity.
    pub fn privilegedKeyManager(self: *Wallet) PrivilegedKeyManager {
        return PrivilegedKeyManager.init(self.allocator, self.private_key, &self.storage_manager, &self.identity_key);
    }

    /// Encrypt `plaintext` under this wallet's BRC-42 privileged key (AES-GCM).
    /// Returns owned ciphertext (caller frees). See `PrivilegedKeyManager.encrypt`.
    pub fn encrypt(self: *Wallet, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        return self.privilegedKeyManager().encrypt(allocator, plaintext);
    }

    /// Decrypt ciphertext produced by `encrypt` with this wallet's privileged key.
    /// Returns owned plaintext (caller frees). See `PrivilegedKeyManager.decrypt`.
    pub fn decrypt(self: *Wallet, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        return self.privilegedKeyManager().decrypt(allocator, ciphertext);
    }
};

test "Wallet init derives identity key" {
    const allocator = std.testing.allocator;
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x01)));

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
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x01)));
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
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x01)));
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
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x01)));
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
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x01)));
    const cp_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x02)));
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
