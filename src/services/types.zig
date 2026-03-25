const std = @import("std");

// --- Block Header ---

pub const BlockHeader = struct {
    version: u32,
    previous_hash: [32]u8,
    merkle_root: [32]u8,
    time: u32,
    bits: u32,
    nonce: u32,
    height: u32,
    hash: [32]u8,
};

// --- Merkle Path ---

pub const MerklePathResult = struct {
    name: []const u8,
    merkle_path: ?[]const u8,
    block_header: ?MerklePathBlockHeader,
};

pub const MerklePathBlockHeader = struct {
    height: u32,
    merkle_root: []const u8,
    hash: []const u8,
};

// --- Raw Tx ---

pub const RawTxResult = struct {
    txid: []const u8,
    name: []const u8,
    raw_tx: ?[]u8,
};

// --- Post BEEF ---

pub const PostBeefResult = struct {
    name: []const u8,
    status: Status,
    txid_results: []PostedTxid,
    @"error": ?[]const u8,

    pub const Status = enum { success, @"error" };
};

pub const PostedTxid = struct {
    txid: []const u8,
    result: ResultStatus,
    already_known: bool,
    double_spend: bool,
    block_hash: ?[]const u8,
    block_height: ?u32,
    merkle_path: ?[]const u8,
    competing_txs: ?[]const []const u8,
    data: ?[]const u8,
    @"error": ?[]const u8,

    pub const ResultStatus = enum {
        success,
        @"error",
        already_known,
        double_spend,
        missing_inputs,
    };
};

// --- Tx Status ---

pub const GetStatusForTxidsResult = struct {
    name: []const u8,
    status: Status,
    results: []TxStatusDetail,

    pub const Status = enum { success };
};

pub const TxStatusDetail = struct {
    txid: []const u8,
    depth: ?u32,
    status: TxStatus,
};

pub const TxStatus = enum {
    mined,
    known,
    unknown,
};

// --- Arcade Status ---

pub const ArcadeStatus = enum {
    UNKNOWN,
    RECEIVED,
    SENT_TO_NETWORK,
    ACCEPTED_BY_NETWORK,
    SEEN_ON_NETWORK,
    DOUBLE_SPEND_ATTEMPTED,
    REJECTED,
    MINED,
    IMMUTABLE,
};

// --- UTXO Status ---

pub const UtxoStatusResult = struct {
    name: []const u8,
    status: Status,
    is_utxo: bool,
    details: []UtxoDetail,

    pub const Status = enum { success, @"error" };
};

pub const UtxoDetail = struct {
    txid: []const u8,
    index: u32,
    satoshis: ?u64,
    height: ?u32,
};
