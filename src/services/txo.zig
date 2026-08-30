const std = @import("std");
const http = @import("../http/client.zig");

pub const TxoClient = struct {
    host: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    const base_path = "/1sat/txo";

    pub const GetOptions = struct {
        /// Include the spend txid when present (only documented query flag).
        spend: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8) TxoClient {
        return .{
            .host = host,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *TxoClient) void {
        _ = self;
    }

    pub fn get(self: *TxoClient, outpoint: []const u8, opts: GetOptions) !IndexedOutput {
        const qs = buildQueryString(opts);
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}{s}", .{ self.host, base_path, outpoint, qs });
        defer self.allocator.free(url);

        var result = try http.getJson(self.allocator, self.io, url, &.{});
        defer result.deinit();
        if (result.status != .ok) return error.HttpRequestFailed;

        return try parseIndexedOutput(self.allocator, result.body);
    }

    pub fn getSpend(self: *TxoClient, outpoint: []const u8) !?[]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/spend", .{ self.host, base_path, outpoint });
        defer self.allocator.free(url);

        var result = try http.getJson(self.allocator, self.io, url, &.{});
        defer result.deinit();
        if (result.status != .ok) return error.HttpRequestFailed;

        const obj = result.body.object;
        const val = obj.get("spendTxid") orelse return null;
        return switch (val) {
            .string => |s| try self.allocator.dupe(u8, s),
            .null => null,
            else => null,
        };
    }

    pub fn getBatch(self: *TxoClient, outpoints: []const []const u8, opts: GetOptions) ![]IndexedOutput {
        const qs = buildQueryString(opts);
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/outpoints{s}", .{ self.host, base_path, qs });
        defer self.allocator.free(url);

        const body = try serializeStringArray(self.allocator, outpoints);
        defer self.allocator.free(body);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const result = try http.postJson(self.allocator, self.io, url, body, &headers);
        var resp = result;
        defer resp.deinit();
        if (resp.status != .ok) return error.HttpRequestFailed;

        const arr = switch (resp.body) {
            .array => |a| a,
            else => return error.UnexpectedJsonType,
        };

        var outputs: std.ArrayList(IndexedOutput) = .empty;
        try outputs.ensureTotalCapacity(self.allocator, arr.items.len);
        for (arr.items) |item| {
            switch (item) {
                .object => outputs.appendAssumeCapacity(try parseIndexedOutput(self.allocator, item)),
                .null => {},
                else => return error.UnexpectedJsonType,
            }
        }
        return outputs.toOwnedSlice(self.allocator);
    }

    fn buildQueryString(opts: GetOptions) []const u8 {
        if (opts.spend) return "?spend=true";
        return "";
    }

    fn serializeStringArray(allocator: std.mem.Allocator, strings: []const []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.append(allocator, '[');
        for (strings, 0..) |s, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        }
        try buf.append(allocator, ']');
        return buf.toOwnedSlice(allocator);
    }

    fn parseIndexedOutput(allocator: std.mem.Allocator, json: std.json.Value) !IndexedOutput {
        const obj = json.object;

        return .{
            .outpoint = switch (obj.get("outpoint") orelse return error.MissingField) {
                .string => |s| try allocator.dupe(u8, s),
                else => return error.UnexpectedJsonType,
            },
            .score = switch (obj.get("score") orelse return error.MissingField) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => return error.UnexpectedJsonType,
            },
            .satoshis = if (obj.get("satoshis")) |v| switch (v) {
                .integer => |i| @intCast(i),
                .null => null,
                else => null,
            } else null,
            .block_height = if (obj.get("blockHeight")) |v| switch (v) {
                .integer => |i| @intCast(i),
                .null => null,
                else => null,
            } else null,
            .block_idx = if (obj.get("blockIdx")) |v| switch (v) {
                .integer => |i| @intCast(i),
                .null => null,
                else => null,
            } else null,
            .spend = if (obj.get("spend")) |v| switch (v) {
                .string => |s| try allocator.dupe(u8, s),
                .null => null,
                else => null,
            } else null,
        };
    }
};

pub const IndexedOutput = struct {
    outpoint: []const u8,
    score: f64,
    satoshis: ?u64,
    block_height: ?u32,
    block_idx: ?u32,
    spend: ?[]const u8,
};
