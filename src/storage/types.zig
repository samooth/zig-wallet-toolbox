const std = @import("std");

/// Serialize a list of key-share strings into a JSON array text (owned by allocator).
/// Shares may contain non-UTF-8 bytes (the raw integrity field of the keyshares backup
/// format), so each share is base64-encoded first; base64 is ASCII-safe and round-trips as a
/// JSON string (unlike raw binary, which std.json would serialize as a byte array).
pub fn serializeShares(allocator: std.mem.Allocator, shares: []const []const u8) ![]u8 {
    const encs = try allocator.alloc([]u8, shares.len);
    errdefer {
        for (encs) |e| allocator.free(e);
        allocator.free(encs);
    }

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    for (shares, 0..) |s, i| {
        const enc_len = std.base64.standard.Encoder.calcSize(s.len);
        const enc = try allocator.alloc(u8, enc_len);
        const enc_slice = std.base64.standard.Encoder.encode(enc, s);
        encs[i] = enc;
        try arr.append(.{ .string = enc_slice });
    }

    const val: std.json.Value = .{ .array = arr };
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(val, .{})});
}

/// Parse JSON-array-of-strings share text (base64-encoded) into an owned `[][]u8`
/// (caller frees both levels).
pub fn parseSharesJson(allocator: std.mem.Allocator, json_str: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const arr = if (parsed.value == .array) parsed.value.array.items else return error.InvalidKeyShares;
    var result = try allocator.alloc([]u8, arr.len);
    errdefer allocator.free(result);
    for (arr, 0..) |item, i| {
        if (item != .string) return error.InvalidKeyShares;
        const enc = item.string;
        const dec_len = std.base64.standard.Decoder.calcSizeForSlice(enc) catch return error.InvalidKeyShares;
        const dec = try allocator.alloc(u8, dec_len);
        std.base64.standard.Decoder.decode(dec, enc) catch {
            allocator.free(dec);
            return error.InvalidKeyShares;
        };
        result[i] = dec;
    }
    return result;
}

pub const AuthId = struct {
    identity_key: []const u8,
    storage_identity_key: ?[]const u8 = null,
};

pub const TransactionStatus = enum {
    unsigned,
    unprocessed,
    sending,
    unproven,
    completed,
    failed,
    nosend,
    nonfinal,
    /// Terminal-override status: assigned by `listFailedActions(unfail=true)`
    /// to queue a 'failed' action for attempted recovery by the Monitor.
    unfail,
};

/// `listActions` special-operation label: restricts results to status
/// 'failed' actions. Value matches the TS/Go SDK reserved constant exactly
/// so remote storage servers interpret it identically.
pub const spec_op_failed_actions = "97d4eb1e49215e3374cc2c1939a7c43a55e95c7427bf2d45ed63e3b4e0c88153";

/// `listActions` special-operation label for use together with
/// `spec_op_failed_actions`: moves matched 'failed' actions to 'unfail'
/// status, queueing them for Monitor recovery.
pub const spec_op_failed_actions_unfail = "unfail";

/// Statuses returned by plain (non-spec-op) `listActions` — matches the
/// TS/Go SDK filter set ('failed' is only visible via listFailedActions).
pub const list_actions_statuses = [_][]const u8{
    "completed", "unprocessed", "sending", "unproven", "unsigned", "nosend", "nonfinal",
};

pub const FindOrInsertUserResult = struct {
    user: TableUser,
    is_new: bool,
};

pub const TableUser = struct {
    user_id: u32,
    identity_key: []const u8,
    active_storage: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};
