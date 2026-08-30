const std = @import("std");
const bsvz = @import("bsvz");
const crypto = bsvz.crypto;
const OneSatServices = @import("../services/onesat.zig").OneSatServices;

/// Chain tracker adapter for bsvz's BEEF/merkle-path verification
/// (`spv.verifyBeef`, `MerklePath.verify`): resolves each merkle root
/// against the real chain via Chaintracks through `OneSatServices`.
///
/// The duck-typed interface bsvz expects is
/// `isValidRootForHeight(root: crypto.Hash256, height: u32) !bool`.
///
/// `offline` mode maps every query to false so callers can distinguish
/// "could not verify" from "verified" without network access (used by
/// internalizeAction when services are unavailable and verification is
/// required — callers then fail closed).
pub const ChaintracksChainTracker = struct {
    services: ?*OneSatServices,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, services: ?*OneSatServices) ChaintracksChainTracker {
        return .{
            .services = services,
            .allocator = allocator,
        };
    }

    pub fn isValidRootForHeight(self: ChaintracksChainTracker, root: crypto.Hash256, height: u32) !bool {
        const svc = self.services orelse return false;
        // Verify against the chain header for this height. Network or parse
        // failures are verification failures (fail closed).
        return svc.isValidRootForHeight(root.bytes, height) catch false;
    }
};

/// A tracker that accepts every root (bsvz's GullibleChainTracker shape).
/// Used for offline/no-network internalize when the caller explicitly opts
/// out of verification via `trustUnverified`.
pub const GullibleTracker = bsvz.spv.GullibleChainTracker;
