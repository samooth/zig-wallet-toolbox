const std = @import("std");

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
