const std = @import("std");
const http = @import("../http/client.zig");
const types = @import("types.zig");

/// Broadcast client backed by the 1Sat Stack API gateway
/// (`POST {host}/1sat/tx/`, which proxies to ARC upstream).
pub const ArcadeClient = struct {
    host: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    /// The gateway exposes a single broadcast endpoint; per-txid status
    /// queries are not part of the documented API (use BeefClient instead).
    const broadcast_path = "/1sat/tx/";

    pub const SubmitOptions = struct {
        callback_url: ?[]const u8 = null,
        callback_token: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8) ArcadeClient {
        return .{
            .host = host,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *ArcadeClient) void {
        _ = self;
    }

    pub fn submitTransaction(self: *ArcadeClient, beef: []const u8, opts: SubmitOptions) !ArcadeStatusResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.host, broadcast_path });
        defer self.allocator.free(url);

        var headers_buf: [4]std.http.Header = undefined;
        var header_count: usize = 0;
        headers_buf[header_count] = .{ .name = "Content-Type", .value = "application/octet-stream" };
        header_count += 1;
        if (opts.callback_url) |cb_url| {
            headers_buf[header_count] = .{ .name = "X-CallbackUrl", .value = cb_url };
            header_count += 1;
        }
        if (opts.callback_token) |cb_token| {
            headers_buf[header_count] = .{ .name = "X-CallbackToken", .value = cb_token };
            header_count += 1;
        }

        const result = try http.postJson(self.allocator, self.io, url, beef, headers_buf[0..header_count]);
        // 200 = accepted/terminal, 202 = wait timed out (status is best-effort)
        if (result.status != .ok and result.status != .accepted) return error.HttpRequestFailed;

        return parseStatusResponse(result.body);
    }

    fn parseStatusResponse(json: std.json.Value) !ArcadeStatusResponse {
        const obj = json.object;

        return .{
            .txid = if (obj.get("txid")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            .tx_status = parseArcadeStatus(obj.get("txStatus")),
            .block_height = if (obj.get("blockHeight")) |v| switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            } else null,
            .block_hash = if (obj.get("blockHash")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            .extra_info = if (obj.get("extraInfo")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
            .competing_txs = if (obj.get("competingTxs")) |v| switch (v) {
                .array => |arr| blk: {
                    var txs: std.ArrayList([]const u8) = .empty;
                    for (arr.items) |item| {
                        switch (item) {
                            .string => |s| try txs.append(std.heap.page_allocator, s),
                            else => {},
                        }
                    }
                    break :blk txs.items;
                },
                else => null,
            } else null,
        };
    }

    fn parseArcadeStatus(value: ?std.json.Value) types.ArcadeStatus {
        const str = switch (value orelse return .UNKNOWN) {
            .string => |s| s,
            else => return .UNKNOWN,
        };

        const map = std.StaticStringMap(types.ArcadeStatus).initComptime(.{
            .{ "UNKNOWN", .UNKNOWN },
            .{ "RECEIVED", .RECEIVED },
            .{ "SENT_TO_NETWORK", .SENT_TO_NETWORK },
            .{ "ACCEPTED_BY_NETWORK", .ACCEPTED_BY_NETWORK },
            .{ "SEEN_ON_NETWORK", .SEEN_ON_NETWORK },
            .{ "DOUBLE_SPEND_ATTEMPTED", .DOUBLE_SPEND_ATTEMPTED },
            .{ "REJECTED", .REJECTED },
            .{ "MINED", .MINED },
            .{ "IMMUTABLE", .IMMUTABLE },
        });

        return map.get(str) orelse .UNKNOWN;
    }
};

pub const ArcadeStatusResponse = struct {
    txid: ?[]const u8,
    tx_status: types.ArcadeStatus,
    block_height: ?u32,
    block_hash: ?[]const u8,
    extra_info: ?[]const u8,
    competing_txs: ?[][]const u8,
};
