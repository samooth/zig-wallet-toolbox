const std = @import("std");
const sqlite = @import("sqlite");

/// Row structs for zig-sqlite with custom type binding/reading.
/// User table row
pub const UserRow = struct {
    user_id: u32,
    identity_key: []const u8,
    active_storage: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn bind(self: UserRow, _: std.mem.Allocator) !struct { user_id: u32, identity_key: []const u8, active_storage: []const u8, created_at: i64, updated_at: i64 } {
        return .{ .user_id = self.user_id, .identity_key = self.identity_key, .active_storage = self.active_storage, .created_at = self.created_at, .updated_at = self.updated_at };
    }

    pub fn read(_: std.mem.Allocator, row: struct { user_id: u32, identity_key: []const u8, active_storage: []const u8, created_at: i64, updated_at: i64 }) !UserRow {
        return .{
            .user_id = row.user_id,
            .identity_key = row.identity_key,
            .active_storage = row.active_storage,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

/// Transaction (wallet action) table row
pub const TransactionRow = struct {
    id: u32,
    user_id: u32,
    status: []const u8,
    reference: []const u8,
    is_outgoing: bool,
    satoshis: i64,
    description: ?[]const u8,
    version: u32,
    lock_time: u32,
    txid: ?[]const u8,
    input_beef: ?[]const u8,
    created_at: i64,
    updated_at: i64,

    pub fn bind(self: TransactionRow, _: std.mem.Allocator) !struct {
        id: u32,
        user_id: u32,
        status: []const u8,
        reference: []const u8,
        is_outgoing: bool,
        satoshis: i64,
        description: ?[]const u8,
        version: u32,
        lock_time: u32,
        txid: ?[]const u8,
        input_beef: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    } {
        return .{
            .id = self.id,
            .user_id = self.user_id,
            .status = self.status,
            .reference = self.reference,
            .is_outgoing = self.is_outgoing,
            .satoshis = self.satoshis,
            .description = self.description,
            .version = self.version,
            .lock_time = self.lock_time,
            .txid = self.txid,
            .input_beef = self.input_beef,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
        };
    }

    pub fn read(_: std.mem.Allocator, row: struct {
        id: u32,
        user_id: u32,
        status: []const u8,
        reference: []const u8,
        is_outgoing: bool,
        satoshis: i64,
        description: ?[]const u8,
        version: u32,
        lock_time: u32,
        txid: ?[]const u8,
        input_beef: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    }) !TransactionRow {
        return .{
            .id = row.id,
            .user_id = row.user_id,
            .status = row.status,
            .reference = row.reference,
            .is_outgoing = row.is_outgoing,
            .satoshis = row.satoshis,
            .description = row.description,
            .version = row.version,
            .lock_time = row.lock_time,
            .txid = row.txid,
            .input_beef = row.input_beef,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

/// Output (UTXO/change) table row
pub const OutputRow = struct {
    id: u32,
    user_id: u32,
    transaction_id: u32,
    spent_by: ?u32,
    vout: u32,
    satoshis: i64,
    locking_script: []u8,
    custom_instructions: ?[]const u8,
    derivation_prefix: ?[]const u8,
    derivation_suffix: ?[]const u8,
    basket_name: ?[]const u8,
    spendable: bool,
    change: bool,
    description: ?[]const u8,
    provided_by: ?[]const u8,
    purpose: ?[]const u8,
    type: ?[]const u8,
    sender_identity_key: ?[]const u8,
    created_at: i64,
    updated_at: i64,

    pub fn bind(self: OutputRow, _: std.mem.Allocator) !struct {
        id: u32,
        user_id: u32,
        transaction_id: u32,
        spent_by: ?u32,
        vout: u32,
        satoshis: i64,
        locking_script: []u8,
        custom_instructions: ?[]const u8,
        derivation_prefix: ?[]const u8,
        derivation_suffix: ?[]const u8,
        basket_name: ?[]const u8,
        spendable: bool,
        change: bool,
        description: ?[]const u8,
        provided_by: ?[]const u8,
        purpose: ?[]const u8,
        type: ?[]const u8,
        sender_identity_key: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    } {
        return .{
            .id = self.id,
            .user_id = self.user_id,
            .transaction_id = self.transaction_id,
            .spent_by = self.spent_by,
            .vout = self.vout,
            .satoshis = self.satoshis,
            .locking_script = self.locking_script,
            .custom_instructions = self.custom_instructions,
            .derivation_prefix = self.derivation_prefix,
            .derivation_suffix = self.derivation_suffix,
            .basket_name = self.basket_name,
            .spendable = self.spendable,
            .change = self.change,
            .description = self.description,
            .provided_by = self.provided_by,
            .purpose = self.purpose,
            .type = self.type,
            .sender_identity_key = self.sender_identity_key,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
        };
    }

    pub fn read(_: std.mem.Allocator, row: struct {
        id: u32,
        user_id: u32,
        transaction_id: u32,
        spent_by: ?u32,
        vout: u32,
        satoshis: i64,
        locking_script: []u8,
        custom_instructions: ?[]const u8,
        derivation_prefix: ?[]const u8,
        derivation_suffix: ?[]const u8,
        basket_name: ?[]const u8,
        spendable: bool,
        change: bool,
        description: ?[]const u8,
        provided_by: ?[]const u8,
        purpose: ?[]const u8,
        type: ?[]const u8,
        sender_identity_key: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    }) !OutputRow {
        return .{
            .id = row.id,
            .user_id = row.user_id,
            .transaction_id = row.transaction_id,
            .spent_by = row.spent_by,
            .vout = row.vout,
            .satoshis = row.satoshis,
            .locking_script = row.locking_script,
            .custom_instructions = row.custom_instructions,
            .derivation_prefix = row.derivation_prefix,
            .derivation_suffix = row.derivation_suffix,
            .basket_name = row.basket_name,
            .spendable = row.spendable,
            .change = row.change,
            .description = row.description,
            .provided_by = row.provided_by,
            .purpose = row.purpose,
            .type = row.type,
            .sender_identity_key = row.sender_identity_key,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

/// Known transaction (merkle proof/status) table row
pub const KnownTxRow = struct {
    id: u32,
    user_id: u32,
    txid: []const u8,
    status: []const u8,
    raw_tx: ?[]u8,
    beef: ?[]u8,
    merkle_path: ?[]u8,
    block_height: ?u32,
    block_hash: ?[]const u8,
    attempts: u32,
    max_rebroadcast_attempts: u32,
    was_broadcast: bool,
    created_at: i64,
    updated_at: i64,

    pub fn bind(self: KnownTxRow, _: std.mem.Allocator) !struct {
        id: u32,
        user_id: u32,
        txid: []const u8,
        status: []const u8,
        raw_tx: ?[]u8,
        beef: ?[]u8,
        merkle_path: ?[]u8,
        block_height: ?u32,
        block_hash: ?[]const u8,
        attempts: u32,
        max_rebroadcast_attempts: u32,
        was_broadcast: bool,
        created_at: i64,
        updated_at: i64,
    } {
        return .{
            .id = self.id,
            .user_id = self.user_id,
            .txid = self.txid,
            .status = self.status,
            .raw_tx = self.raw_tx,
            .beef = self.beef,
            .merkle_path = self.merkle_path,
            .block_height = self.block_height,
            .block_hash = self.block_hash,
            .attempts = self.attempts,
            .max_rebroadcast_attempts = self.max_rebroadcast_attempts,
            .was_broadcast = self.was_broadcast,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
        };
    }

    pub fn read(_: std.mem.Allocator, row: struct {
        id: u32,
        user_id: u32,
        txid: []const u8,
        status: []const u8,
        raw_tx: ?[]u8,
        beef: ?[]u8,
        merkle_path: ?[]u8,
        block_height: ?u32,
        block_hash: ?[]const u8,
        attempts: u32,
        max_rebroadcast_attempts: u32,
        was_broadcast: bool,
        created_at: i64,
        updated_at: i64,
    }) !KnownTxRow {
        return .{
            .id = row.id,
            .user_id = row.user_id,
            .txid = row.txid,
            .status = row.status,
            .raw_tx = row.raw_tx,
            .beef = row.beef,
            .merkle_path = row.merkle_path,
            .block_height = row.block_height,
            .block_hash = row.block_hash,
            .attempts = row.attempts,
            .max_rebroadcast_attempts = row.max_rebroadcast_attempts,
            .was_broadcast = row.was_broadcast,
            .created_at = row.created_at,
            .updated_at = row.updated_at,
        };
    }
};

/// OutputBasket table row
pub const OutputBasketRow = struct {
    user_id: u32,
    name: []const u8,
    created_at: i64,

    pub fn bind(self: OutputBasketRow, _: std.mem.Allocator) !struct {
        user_id: u32,
        name: []const u8,
        created_at: i64,
    } {
        return .{ .user_id = self.user_id, .name = self.name, .created_at = self.created_at };
    }

    pub fn read(_: std.mem.Allocator, row: struct {
        user_id: u32,
        name: []const u8,
        created_at: i64,
    }) !OutputBasketRow {
        return .{ .user_id = row.user_id, .name = row.name, .created_at = row.created_at };
    }
};

/// Tag table row
pub const TagRow = struct {
    id: u32,
    user_id: u32,
    name: []const u8,

    pub fn bind(self: TagRow, _: std.mem.Allocator) !struct {
        id: u32,
        user_id: u32,
        name: []const u8,
    } {
        return .{ .id = self.id, .user_id = self.user_id, .name = self.name };
    }

    pub fn read(_: std.mem.Allocator, row: struct { id: u32, user_id: u32, name: []const u8 }) !TagRow {
        return .{ .id = row.id, .user_id = row.user_id, .name = row.name };
    }
};

/// Label table row
pub const LabelRow = struct {
    id: u32,
    user_id: u32,
    name: []const u8,

    pub fn bind(self: LabelRow, _: std.mem.Allocator) !struct {
        id: u32,
        user_id: u32,
        name: []const u8,
    } {
        return .{ .id = self.id, .user_id = self.user_id, .name = self.name };
    }

    pub fn read(_: std.mem.Allocator, row: struct { id: u32, user_id: u32, name: []const u8 }) !LabelRow {
        return .{ .id = row.id, .user_id = row.user_id, .name = row.name };
    }
};

/// OutputTag junction table row
pub const OutputTagRow = struct {
    output_id: u32,
    tag_id: u32,

    pub fn bind(self: OutputTagRow, _: std.mem.Allocator) !struct {
        output_id: u32,
        tag_id: u32,
    } {
        return .{ .output_id = self.output_id, .tag_id = self.tag_id };
    }

    pub fn read(_: std.mem.Allocator, row: struct { output_id: u32, tag_id: u32 }) !OutputTagRow {
        return .{ .output_id = row.output_id, .tag_id = row.tag_id };
    }
};

/// TransactionLabel junction table row
pub const TransactionLabelRow = struct {
    transaction_id: u32,
    label_id: u32,

    pub fn bind(self: TransactionLabelRow, _: std.mem.Allocator) !struct {
        transaction_id: u32,
        label_id: u32,
    } {
        return .{ .transaction_id = self.transaction_id, .label_id = self.label_id };
    }

    pub fn read(_: std.mem.Allocator, row: struct { transaction_id: u32, label_id: u32 }) !TransactionLabelRow {
        return .{ .transaction_id = row.transaction_id, .label_id = row.label_id };
    }
};

/// KnownTx status enum (matches go-wallet-toolbox)
pub const KnownTxStatus = enum {
    unsent,
    unsent_expired,
    rebroadcast,
    unmined,
    mined,
    invalid_tx,
    double_spend,
    replaced,
    unknown,
};

/// Transaction status enum (matches go-wallet-toolbox wdk.TxStatus)
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

/// Output spendable status
pub const OutputSpendable = enum {
    spendable,
    reserved,
    spent,
    locked,
};
