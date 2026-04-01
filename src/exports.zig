//! C ABI exports for zig-wallet-toolbox — BRC-100 wallet operations.
//! Wallet state is managed via opaque handles. JSON strings used for args/results.
//! All functions return 0 on success, negative on failure.

const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const hex = bsvz.primitives.hex;
const crypto_hash = bsvz.crypto.hash;
const script_builder = bsvz.script.builder;
const Opcode = bsvz.script.opcode.Opcode;
const p2pkh = bsvz.script.templates.p2pkh;
const toolbox = @import("zig-wallet-toolbox");
const wallet_mod = toolbox.wallet;
const signer_types = toolbox.signer.types;
const storage = toolbox.storage;
const services = toolbox.services;
const auth = toolbox.auth;

const alloc = std.heap.page_allocator;

const OK: c_int = 0;
const ERR_INVALID_INPUT: c_int = -1;
const ERR_WALLET: c_int = -2;
const ERR_JSON: c_int = -3;
const ERR_ALLOC: c_int = -4;
const ERR_NOT_INIT: c_int = -5;
const ERR_BUFFER_TOO_SMALL: c_int = -6;
const ERR_HTTP: c_int = -7;

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

/// Create a wallet connected to a remote 1sat-stack backend.
/// privkey: 32-byte private key, backend_url: null-terminated URL string.
/// This sets up authenticated BRC-100 communication with the backend.
export fn bsvwallet_create_remote(
    privkey: [*c]const u8,
    chain: c_int,
    backend_url: [*c]const u8,
    backend_url_len: usize,
    out_handle: *?*anyopaque,
) c_int {
    const pk = ec.PrivateKey.fromBytes(privkey[0..32].*) catch return ERR_INVALID_INPUT;
    const chain_val: wallet_mod.Chain = if (chain == 0) .main else .@"test";
    var url_slice = backend_url[0..backend_url_len];
    // Strip trailing slash to avoid double-slash in URL
    while (url_slice.len > 0 and url_slice[url_slice.len - 1] == '/') {
        url_slice = url_slice[0 .. url_slice.len - 1];
    }

    // Build the wallet storage URL: {backend}/1sat/wallet
    const wallet_url = std.fmt.allocPrint(alloc, "{s}/1sat/wallet", .{url_slice}) catch return ERR_ALLOC;

    // Create auth client for this private key
    const af_ptr = alloc.create(auth.AuthFetch) catch {
        alloc.free(wallet_url);
        return ERR_ALLOC;
    };
    af_ptr.* = auth.AuthFetch.init(alloc, pk);

    // Create remote storage client pointing at the wallet storage endpoint
    const remote_ptr = alloc.create(storage.RemoteStorageClient) catch {
        af_ptr.deinit();
        alloc.destroy(af_ptr);
        alloc.free(wallet_url);
        return ERR_ALLOC;
    };
    remote_ptr.* = storage.RemoteStorageClient.init(alloc, af_ptr, wallet_url);

    // Set up storage manager with the remote provider as active
    var mgr = storage.WalletStorageManager.init(alloc);
    mgr.setActive(remote_ptr.storageProvider());

    // Set up OneSat services for chain queries
    const onesat_chain: services.OneSatServices.Chain = if (chain == 0) .main else .@"test";
    var onesat = services.OneSatServices.init(alloc, onesat_chain, url_slice);

    const wallet_ptr = alloc.create(wallet_mod.Wallet) catch {
        alloc.destroy(remote_ptr);
        af_ptr.deinit();
        alloc.destroy(af_ptr);
        return ERR_ALLOC;
    };
    wallet_ptr.* = wallet_mod.Wallet.init(alloc, .{
        .private_key = pk,
        .chain = chain_val,
        .wallet_services = onesat.walletServices(),
        .storage_manager = mgr,
    }) catch {
        alloc.destroy(wallet_ptr);
        alloc.destroy(remote_ptr);
        af_ptr.deinit();
        alloc.destroy(af_ptr);
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
    var basket_owned: ?[]u8 = null;
    var limit: ?u32 = null;
    var offset: ?u32 = null;

    if (args_len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json[0..args_len], .{}) catch return ERR_JSON;
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("basket")) |b| {
                if (b == .string) {
                    // Must dupe — parsed will be freed before wallet.listOutputs uses the slice
                    basket_owned = alloc.dupe(u8, b.string) catch null;
                    basket = basket_owned;
                }
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
    }) catch |err| {
        std.log.err("bsvwallet_list_outputs: {s}", .{@errorName(err)});
        if (basket_owned) |b| alloc.free(b);
        return ERR_WALLET;
    };
    if (basket_owned) |b| alloc.free(b);

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

/// Get the wallet's balance (sum of spendable outputs).
/// Writes confirmed satoshis to out_confirmed, unconfirmed to out_unconfirmed.
export fn bsvwallet_get_balance(
    handle: ?*anyopaque,
    out_confirmed: *i64,
    out_unconfirmed: *i64,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const balance = wallet.getBalance() catch return ERR_WALLET;
    out_confirmed.* = balance.confirmed;
    out_unconfirmed.* = balance.unconfirmed;
    return OK;
}

/// Get balance without a pre-existing wallet handle. Creates a temporary
/// remote wallet connection, fetches the balance, and tears down.
/// privkey: 32-byte private key, backend_url + backend_url_len: remote URL.
export fn bsvwallet_get_balance_remote(
    privkey: [*c]const u8,
    chain: c_int,
    backend_url: [*c]const u8,
    backend_url_len: usize,
    out_confirmed: *i64,
    out_unconfirmed: *i64,
) c_int {
    var handle: ?*anyopaque = null;
    const rc = bsvwallet_create_remote(privkey, chain, backend_url, backend_url_len, &handle);
    if (rc != OK) return rc;
    defer _ = bsvwallet_destroy(handle);

    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const balance = wallet.getBalance() catch return ERR_WALLET;
    out_confirmed.* = balance.confirmed;
    out_unconfirmed.* = balance.unconfirmed;
    return OK;
}

/// Derive a protocol-scoped public key (BRC-42/43) from an existing wallet handle.
/// protocol_id + protocol_id_len: protocol name.
/// key_id + key_id_len: key identifier.
/// security_level: 0, 1, or 2.
/// for_self: true to derive for self, false for counterparty.
/// counterparty + counterparty_len: hex pubkey (ignored if for_self, pass 0 length).
/// out_pubkey: 66-byte buffer for hex-encoded compressed pubkey.
/// out_pubkey_len: set to 66 on success.
export fn bsvwallet_get_derived_public_key(
    handle: ?*anyopaque,
    protocol_id: [*c]const u8,
    protocol_id_len: usize,
    key_id: [*c]const u8,
    key_id_len: usize,
    security_level: u8,
    for_self: bool,
    counterparty: [*c]const u8,
    counterparty_len: usize,
    out_pubkey: [*c]u8,
    out_pubkey_len: *usize,
) c_int {
    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));

    const cp_slice: ?[]const u8 = if (counterparty_len > 0)
        counterparty[0..counterparty_len]
    else
        null;

    const result = wallet.getDerivedPublicKey(.{
        .protocol_id = protocol_id[0..protocol_id_len],
        .key_id = key_id[0..key_id_len],
        .security_level = security_level,
        .for_self = for_self,
        .counterparty = cp_slice,
    }) catch return ERR_WALLET;

    return copyToOut(&result.public_key, out_pubkey, out_pubkey_len);
}

// ── Authenticated HTTP (BRC-100) ───────────────────────────────────────

/// Opaque auth client handle for C consumers.
const AuthHandle = *auth.AuthFetch;

/// Create an authenticated HTTP client from a 32-byte private key.
/// Returns an opaque handle via out_handle.
export fn bsvauth_create(
    privkey: [*c]const u8,
    out_handle: *?*anyopaque,
) c_int {
    const pk = ec.PrivateKey.fromBytes(privkey[0..32].*) catch return ERR_INVALID_INPUT;

    const af_ptr = alloc.create(auth.AuthFetch) catch return ERR_ALLOC;
    af_ptr.* = auth.AuthFetch.init(alloc, pk);

    out_handle.* = af_ptr;
    return OK;
}

/// Destroy an authenticated HTTP client and free its resources.
export fn bsvauth_destroy(handle: ?*anyopaque) c_int {
    const af: AuthHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    af.deinit();
    alloc.destroy(af);
    return OK;
}

/// Make an authenticated GET request.
/// out_body must be pre-allocated by the caller; out_body_len is set to the
/// actual response body length. Returns ERR_BUFFER_TOO_SMALL (-6) if the
/// response body exceeds *out_body_len (which is read as the buffer capacity
/// on entry).
export fn bsvauth_get(
    handle: ?*anyopaque,
    url: [*c]const u8,
    url_len: usize,
    out_status: *u16,
    out_body: [*c]u8,
    out_body_len: *usize,
) c_int {
    const af: AuthHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const url_slice = url[0..url_len];

    var resp = af.get(url_slice) catch return ERR_HTTP;
    defer resp.deinit();

    out_status.* = resp.status;

    const capacity = out_body_len.*;
    if (resp.body.len > capacity) {
        out_body_len.* = resp.body.len;
        return ERR_BUFFER_TOO_SMALL;
    }

    return copyToOut(resp.body, out_body, out_body_len);
}

/// Make an authenticated POST request with a JSON body.
/// out_body must be pre-allocated by the caller; out_body_len is set to the
/// actual response body length. Returns ERR_BUFFER_TOO_SMALL (-6) if the
/// response body exceeds *out_body_len.
export fn bsvauth_post_json(
    handle: ?*anyopaque,
    url: [*c]const u8,
    url_len: usize,
    body: [*c]const u8,
    body_len: usize,
    out_status: *u16,
    out_body: [*c]u8,
    out_body_len: *usize,
) c_int {
    const af: AuthHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const url_slice = url[0..url_len];
    const body_slice = body[0..body_len];

    var resp = af.postJson(url_slice, body_slice) catch return ERR_HTTP;
    defer resp.deinit();

    out_status.* = resp.status;

    const capacity = out_body_len.*;
    if (resp.body.len > capacity) {
        out_body_len.* = resp.body.len;
        return ERR_BUFFER_TOO_SMALL;
    }

    return copyToOut(resp.body, out_body, out_body_len);
}

// ── Remote transaction building ────────────────────────────────────────

/// Create a wallet action without a pre-existing handle. Creates a temporary
/// remote wallet connection, calls createAction, and tears down.
/// args_json is a JSON string: {"description":"...","outputs":[{"lockingScript":"hex","satoshis":N}],...}
/// Result JSON is written to out_buf.
export fn bsvwallet_create_action_remote(
    privkey: [*c]const u8,
    chain: c_int,
    backend_url: [*c]const u8,
    backend_url_len: usize,
    args_json: [*c]const u8,
    args_json_len: usize,
    out_buf: [*c]u8,
    out_buf_len: *usize,
) c_int {
    var handle: ?*anyopaque = null;
    const rc = bsvwallet_create_remote(privkey, chain, backend_url, backend_url_len, &handle);
    if (rc != OK) return rc;
    defer _ = bsvwallet_destroy(handle);

    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const json_str = args_json[0..args_json_len];

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return ERR_JSON;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return ERR_JSON;

    const description = blk: {
        if (root.get("description")) |d| {
            if (d == .string) break :blk d.string;
        }
        break :blk "";
    };

    // Parse outputs array
    const outputs_val = root.get("outputs") orelse return ERR_JSON;
    const outputs_arr = if (outputs_val == .array) outputs_val.array.items else return ERR_JSON;

    // Build ActionOutput slice on page_allocator
    const outputs = alloc.alloc(signer_types.ActionOutput, outputs_arr.len) catch return ERR_ALLOC;
    defer alloc.free(outputs);

    for (outputs_arr, 0..) |item, i| {
        if (item != .object) return ERR_JSON;
        const obj = item.object;

        const locking_script = blk: {
            if (obj.get("lockingScript")) |ls| {
                if (ls == .string) break :blk ls.string;
            }
            return ERR_JSON;
        };
        const satoshis: u64 = blk: {
            if (obj.get("satoshis")) |s| {
                if (s == .integer) break :blk @intCast(s.integer);
            }
            return ERR_JSON;
        };

        const out_desc: ?[]const u8 = blk: {
            if (obj.get("description")) |d| {
                if (d == .string) break :blk d.string;
            }
            break :blk null;
        };
        const basket: ?[]const u8 = blk: {
            if (obj.get("basket")) |b| {
                if (b == .string) break :blk b.string;
            }
            break :blk null;
        };

        outputs[i] = .{
            .locking_script = locking_script,
            .satoshis = satoshis,
            .description = out_desc,
            .basket = basket,
        };
    }

    // Parse optional labels
    var labels_buf: [64][]const u8 = undefined;
    var labels_slice: ?[]const []const u8 = null;
    if (root.get("labels")) |labels_val| {
        if (labels_val == .array) {
            const larr = labels_val.array.items;
            const count = @min(larr.len, labels_buf.len);
            for (larr[0..count], 0..) |lbl, i| {
                if (lbl == .string) {
                    labels_buf[i] = lbl.string;
                } else {
                    labels_buf[i] = "";
                }
            }
            labels_slice = labels_buf[0..count];
        }
    }

    // Parse optional options
    var options: signer_types.CreateActionOptions = .{};
    if (root.get("options")) |opts_val| {
        if (opts_val == .object) {
            const opts = opts_val.object;
            if (opts.get("noSend")) |v| {
                if (v == .bool) options.no_send = v.bool;
            }
            if (opts.get("signAndProcess")) |v| {
                if (v == .bool) options.sign_and_process = v.bool;
            }
            if (opts.get("acceptDelayedBroadcast")) |v| {
                if (v == .bool) options.accept_delayed_broadcast = v.bool;
            }
            if (opts.get("returnTXIDOnly")) |v| {
                if (v == .bool) options.return_txid_only = v.bool;
            }
            if (opts.get("randomizeOutputs")) |v| {
                if (v == .bool) options.randomize_outputs = v.bool;
            }
        }
    }

    const result = wallet.createAction(.{
        .description = description,
        .outputs = outputs,
        .labels = labels_slice,
        .options = options,
    }) catch return ERR_WALLET;

    return jsonStringify(result.raw, out_buf, out_buf_len);
}

/// Sign a wallet action without a pre-existing handle. Creates a temporary
/// remote wallet connection, calls signAction, and tears down.
/// args_json: {"reference":"...","spends":{"0":{"unlockingScript":"hex"},...},...}
/// Result JSON is written to out_buf.
export fn bsvwallet_sign_action_remote(
    privkey: [*c]const u8,
    chain: c_int,
    backend_url: [*c]const u8,
    backend_url_len: usize,
    args_json: [*c]const u8,
    args_json_len: usize,
    out_buf: [*c]u8,
    out_buf_len: *usize,
) c_int {
    var handle: ?*anyopaque = null;
    const rc = bsvwallet_create_remote(privkey, chain, backend_url, backend_url_len, &handle);
    if (rc != OK) return rc;
    defer _ = bsvwallet_destroy(handle);

    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));
    const json_str = args_json[0..args_json_len];

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch return ERR_JSON;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return ERR_JSON;

    const reference = blk: {
        if (root.get("reference")) |r| {
            if (r == .string) break :blk r.string;
        }
        break :blk "";
    };

    // Parse spends object: {"0": {"unlockingScript":"hex", ...}, ...}
    const spends_val = root.get("spends") orelse return ERR_JSON;
    var spends_count: usize = 0;
    if (spends_val == .object) {
        spends_count = spends_val.object.count();
    } else {
        return ERR_JSON;
    }

    const spends = alloc.alloc(signer_types.SignActionSpend, spends_count) catch return ERR_ALLOC;
    defer alloc.free(spends);

    var spend_idx: usize = 0;
    var it = spends_val.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        if (val != .object) return ERR_JSON;
        const spend_obj = val.object;

        const input_index: u32 = std.fmt.parseInt(u32, key, 10) catch return ERR_JSON;

        const unlocking_script = blk: {
            if (spend_obj.get("unlockingScript")) |us| {
                if (us == .string) break :blk us.string;
            }
            return ERR_JSON;
        };

        const sequence_number: ?u32 = blk: {
            if (spend_obj.get("sequenceNumber")) |sn| {
                if (sn == .integer) break :blk @intCast(sn.integer);
            }
            break :blk null;
        };

        spends[spend_idx] = .{
            .input_index = input_index,
            .unlocking_script = unlocking_script,
            .sequence_number = sequence_number,
        };
        spend_idx += 1;
    }

    // Parse optional options
    var options: signer_types.SignActionOptions = .{};
    if (root.get("options")) |opts_val| {
        if (opts_val == .object) {
            const opts = opts_val.object;
            if (opts.get("acceptDelayedBroadcast")) |v| {
                if (v == .bool) options.accept_delayed_broadcast = v.bool;
            }
            if (opts.get("returnTXIDOnly")) |v| {
                if (v == .bool) options.return_txid_only = v.bool;
            }
            if (opts.get("noSend")) |v| {
                if (v == .bool) options.no_send = v.bool;
            }
        }
    }

    const result = wallet.signAction(.{
        .reference = reference,
        .spends = spends[0..spend_idx],
        .options = options,
    }) catch return ERR_WALLET;

    return jsonStringify(result.raw, out_buf, out_buf_len);
}

/// Create an ordinal inscription and broadcast it without a pre-existing handle.
/// Builds a P2PKH + inscription envelope locking script, then calls createAction.
/// content + content_len: raw inscription content bytes.
/// content_type + ct_len: MIME type (e.g. "text/plain").
/// app_name + name_len: optional application name for labeling (0 len to skip).
/// Result JSON with txid/reference is written to out_buf.
export fn bsvwallet_inscribe_remote(
    privkey: [*c]const u8,
    chain: c_int,
    backend_url: [*c]const u8,
    backend_url_len: usize,
    content: [*c]const u8,
    content_len: usize,
    content_type: [*c]const u8,
    ct_len: usize,
    app_name: [*c]const u8,
    name_len: usize,
    out_buf: [*c]u8,
    out_buf_len: *usize,
) c_int {
    var handle: ?*anyopaque = null;
    const rc = bsvwallet_create_remote(privkey, chain, backend_url, backend_url_len, &handle);
    if (rc != OK) return rc;
    defer _ = bsvwallet_destroy(handle);

    const wallet: WalletHandle = @ptrCast(@alignCast(handle orelse return ERR_NOT_INIT));

    // Derive an inscription key via BRC-42/43 protocol "1sat-ordinals"
    const derived = wallet.getDerivedPublicKey(.{
        .protocol_id = "1sat-ordinals",
        .key_id = "1",
        .security_level = 0,
        .for_self = true,
    }) catch return ERR_WALLET;

    // Decode the derived hex pubkey to raw bytes
    var pubkey_raw: [33]u8 = undefined;
    _ = hex.decodeInto(&derived.public_key, &pubkey_raw) catch return ERR_INVALID_INPUT;

    // Hash160 to get the pubkey hash for P2PKH prefix
    const pubkey_hash = crypto_hash.hash160(&pubkey_raw);
    const p2pkh_prefix = p2pkh.encode(pubkey_hash);

    // Build inscription envelope: P2PKH prefix + OP_FALSE OP_IF "ord" ... OP_ENDIF
    const content_slice = content[0..content_len];
    const ct_slice = content_type[0..ct_len];

    var script_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer script_buf.deinit(alloc);

    // Append P2PKH prefix
    script_buf.appendSlice(alloc, &p2pkh_prefix) catch return ERR_ALLOC;

    // OP_FALSE OP_IF
    script_builder.appendOpcodes(&script_buf, alloc, &.{
        @intFromEnum(Opcode.OP_0),
        @intFromEnum(Opcode.OP_IF),
    }) catch return ERR_ALLOC;

    // Push "ord" marker
    script_builder.appendPushData(&script_buf, alloc, &.{ 0x6f, 0x72, 0x64 }) catch return ERR_ALLOC;

    // OP_1 (content type field)
    script_builder.appendOpcodes(&script_buf, alloc, &.{@intFromEnum(Opcode.OP_1)}) catch return ERR_ALLOC;

    // Push content type
    script_builder.appendPushData(&script_buf, alloc, ct_slice) catch return ERR_ALLOC;

    // OP_0 (content field)
    script_builder.appendOpcodes(&script_buf, alloc, &.{@intFromEnum(Opcode.OP_0)}) catch return ERR_ALLOC;

    // Push content (split into 520-byte chunks if needed)
    const MAX_PUSH: usize = 520;
    if (content_slice.len <= MAX_PUSH) {
        script_builder.appendPushData(&script_buf, alloc, content_slice) catch return ERR_ALLOC;
    } else {
        var offset: usize = 0;
        while (offset < content_slice.len) {
            const end = @min(offset + MAX_PUSH, content_slice.len);
            script_builder.appendPushData(&script_buf, alloc, content_slice[offset..end]) catch return ERR_ALLOC;
            offset = end;
        }
    }

    // OP_ENDIF
    script_builder.appendOpcodes(&script_buf, alloc, &.{@intFromEnum(Opcode.OP_ENDIF)}) catch return ERR_ALLOC;

    // Hex-encode the locking script
    const script_hex = alloc.alloc(u8, script_buf.items.len * 2) catch return ERR_ALLOC;
    defer alloc.free(script_hex);
    _ = hex.encodeLower(script_buf.items, script_hex) catch return ERR_ALLOC;

    // Build the label (use app_name if provided)
    var label_buf: [1][]const u8 = undefined;
    var labels_slice: ?[]const []const u8 = null;
    if (name_len > 0) {
        label_buf[0] = app_name[0..name_len];
        labels_slice = &label_buf;
    }

    // Build outputs: single 1-sat inscription output
    var outputs: [1]signer_types.ActionOutput = .{.{
        .locking_script = script_hex,
        .satoshis = 1,
        .description = "1sat ordinal inscription",
        .basket = "ordinals",
    }};

    const description = if (name_len > 0) app_name[0..name_len] else "inscribe";

    const result = wallet.createAction(.{
        .description = description,
        .outputs = &outputs,
        .labels = labels_slice,
    }) catch return ERR_WALLET;

    return jsonStringify(result.raw, out_buf, out_buf_len);
}
