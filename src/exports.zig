//! C ABI exports for zig-wallet-toolbox — BRC-100 wallet operations.
//! Wallet state is managed via opaque handles. JSON strings used for args/results.
//! All functions return 0 on success, negative on failure.

const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const toolbox = @import("zig-wallet-toolbox");
const wallet_mod = toolbox.wallet;
const storage = toolbox.storage;
const services = toolbox.services;

const alloc = std.heap.page_allocator;

const OK: c_int = 0;
const ERR_INVALID_INPUT: c_int = -1;
const ERR_WALLET: c_int = -2;
const ERR_JSON: c_int = -3;
const ERR_ALLOC: c_int = -4;
const ERR_NOT_INIT: c_int = -5;

/// Opaque wallet handle for C consumers.
const WalletHandle = *wallet_mod.Wallet;

fn copyToOut(src: []const u8, out_buf: [*c]u8, out_len: *usize) c_int {
    @memcpy(out_buf[0..src.len], src);
    out_len.* = src.len;
    return OK;
}

fn jsonStringify(value: std.json.Value, out_buf: [*c]u8, out_len: *usize) c_int {
    // Use std.fmt to format JSON via the Value's format method
    const formatted = std.json.fmt(value, .{});
    const str = std.fmt.allocPrint(alloc, "{f}", .{formatted}) catch return ERR_ALLOC;
    defer alloc.free(str);
    return copyToOut(str, out_buf, out_len);
}

// ── Wallet lifecycle ────────────────────────────────────────────────────

/// Create a wallet from a 32-byte private key. Returns an opaque handle.
/// The wallet uses an in-memory storage manager (no persistence yet).
export fn bsvwallet_create(
    privkey: [*c]const u8,
    chain: c_int, // 0 = mainnet, 1 = testnet
    out_handle: *?*anyopaque,
) c_int {
    const pk = ec.PrivateKey.fromBytes(privkey[0..32].*) catch return ERR_INVALID_INPUT;
    const chain_val: wallet_mod.Chain = if (chain == 0) .main else .@"test";
    const mgr = storage.WalletStorageManager.init(alloc);

    const wallet_ptr = alloc.create(wallet_mod.Wallet) catch return ERR_ALLOC;
    wallet_ptr.* = wallet_mod.Wallet.init(alloc, .{
        .private_key = pk,
        .chain = chain_val,
        .wallet_services = undefined, // No services connected yet
        .storage_manager = mgr,
    }) catch {
        alloc.destroy(wallet_ptr);
        return ERR_WALLET;
    };

    out_handle.* = wallet_ptr;
    return OK;
}

/// Destroy a wallet and free its resources.
export fn bsvwallet_destroy(handle: ?*anyopaque) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    wallet.deinit();
    alloc.destroy(wallet);
    return OK;
}

// ── Wallet operations ───────────────────────────────────────────────────

/// Get the wallet's identity public key (66-char hex string).
/// out_buf must be >= 66 bytes. out_len receives 66.
export fn bsvwallet_get_public_key(
    handle: ?*anyopaque,
    out_buf: [*c]u8,
    out_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const pubkey = wallet.getPublicKey();
    return copyToOut(pubkey, out_buf, out_len);
}

/// Create a wallet action. args_json is a JSON string matching CreateActionArgs.
/// Result is a JSON string written to out_buf. out_buf should be >= 4096 bytes.
export fn bsvwallet_create_action(
    handle: ?*anyopaque,
    args_json: [*c]const u8,
    args_len: usize,
    out_buf: [*c]u8,
    out_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const json_str = args_json[0..args_len];

    // Parse the JSON args
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return ERR_JSON;
    defer parsed.deinit();

    // Extract fields for CreateActionArgs
    const description = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("description")) |d| {
                if (d == .string) break :blk d.string;
            }
        }
        break :blk "";
    };

    const result = wallet.createAction(.{
        .description = description,
        .outputs = &.{},
    }) catch return ERR_WALLET;

    return jsonStringify(result.raw, out_buf, out_len);
}

/// Sign a wallet action. args_json is a JSON string matching SignActionArgs.
/// Result is a JSON string.
export fn bsvwallet_sign_action(
    handle: ?*anyopaque,
    args_json: [*c]const u8,
    args_len: usize,
    out_buf: [*c]u8,
    out_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const json_str = args_json[0..args_len];

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return ERR_JSON;
    defer parsed.deinit();

    const reference = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("reference")) |r| {
                if (r == .string) break :blk r.string;
            }
        }
        break :blk "";
    };

    const result = wallet.signAction(.{
        .reference = reference,
        .spends = &.{},
    }) catch return ERR_WALLET;

    return jsonStringify(result.raw, out_buf, out_len);
}

/// List wallet outputs. args_json is optional JSON (pass empty string for defaults).
/// Result is a JSON string.
export fn bsvwallet_list_outputs(
    handle: ?*anyopaque,
    args_json: [*c]const u8,
    args_len: usize,
    out_buf: [*c]u8,
    out_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));

    var basket: ?[]const u8 = null;
    var limit: ?u32 = null;
    var offset: ?u32 = null;

    if (args_len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json[0..args_len], .{}) catch return ERR_JSON;
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("basket")) |b| {
                if (b == .string) basket = b.string;
            }
            if (parsed.value.object.get("limit")) |l| {
                if (l == .integer) limit = @intCast(l.integer);
            }
            if (parsed.value.object.get("offset")) |o| {
                if (o == .integer) offset = @intCast(o.integer);
            }
        }
    }

    const result = wallet.listOutputs(.{
        .basket = basket,
        .limit = limit,
        .offset = offset,
    }) catch return ERR_WALLET;

    return jsonStringify(result, out_buf, out_len);
}

/// List wallet actions. args_json is optional JSON.
/// Result is a JSON string.
export fn bsvwallet_list_actions(
    handle: ?*anyopaque,
    args_json: [*c]const u8,
    args_len: usize,
    out_buf: [*c]u8,
    out_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));

    var limit: ?u32 = null;
    var offset: ?u32 = null;

    if (args_len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json[0..args_len], .{}) catch return ERR_JSON;
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("limit")) |l| {
                if (l == .integer) limit = @intCast(l.integer);
            }
            if (parsed.value.object.get("offset")) |o| {
                if (o == .integer) offset = @intCast(o.integer);
            }
        }
    }

    const result = wallet.listActions(.{
        .limit = limit,
        .offset = offset,
    }) catch return ERR_WALLET;

    return jsonStringify(result, out_buf, out_len);
}

/// Create a DER signature over data. out_sig must be >= 72 bytes.
export fn bsvwallet_sign_data(
    handle: ?*anyopaque,
    data: [*c]const u8,
    data_len: usize,
    out_sig: [*c]u8,
    out_sig_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const sig = wallet.createSignature(data[0..data_len]) catch return ERR_WALLET;
    const sig_slice = sig.asSlice();
    return copyToOut(sig_slice, out_sig, out_sig_len);
}
