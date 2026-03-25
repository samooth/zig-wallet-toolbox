const std = @import("std");
const http = @import("../http/client.zig");

pub const TxoClient = struct {
    host: []const u8,
    allocator: std.mem.Allocator,

    const base_path = "/1sat/txo";

    pub const GetOptions = struct {
        sats: bool = false,
        spend: bool = false,
        block: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, host: []const u8) TxoClient {
        return .{
            .host = host,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TxoClient) void {
        _ = self;
    }

    pub fn get(self: *TxoClient, outpoint: []const u8, opts: GetOptions) !IndexedOutput {
        const qs = buildQueryString(opts);
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}{s}", .{ self.host, base_path, outpoint, qs });
        defer self.allocator.free(url);

        const result = try http.getJson(self.allocator, url, &.{});
        if (result.status != .ok) return error.HttpRequestFailed;

        return parseIndexedOutput(result.body);
    }

    pub fn getSpend(self: *TxoClient, outpoint: []const u8) !?[]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/spend", .{ self.host, base_path, outpoint });
        defer self.allocator.free(url);

        const result = try http.getJson(self.allocator, url, &.{});
        if (result.status != .ok) return error.HttpRequestFailed;

        const obj = result.body.object;
        const val = obj.get("spendTxid") orelse return null;
        return switch (val) {
            .string => |s| s,
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

        var headers = std.BoundedArray(std.http.Header, 2){};
        headers.appendAssumeCapacity(.{ .name = "Content-Type", .value = "application/json" });

        const result = try http.postJson(self.allocator, url, body, headers.constSlice());
        if (result.status != .ok) return error.HttpRequestFailed;

        const arr = switch (result.body) {
            .array => |a| a,
            else => return error.UnexpectedJsonType,
        };

        var outputs = try std.ArrayList(IndexedOutput).initCapacity(self.allocator, arr.items.len);
        for (arr.items) |item| {
            switch (item) {
                .object => outputs.appendAssumeCapacity(try parseIndexedOutput(item)),
                .null => {},
                else => return error.UnexpectedJsonType,
            }
        }
        return outputs.items;
    }

    fn buildQueryString(opts: GetOptions) []const u8 {
        if (opts.sats and opts.spend and opts.block) return "?sats&spend&block";
        if (opts.sats and opts.spend) return "?sats&spend";
        if (opts.sats and opts.block) return "?sats&block";
        if (opts.spend and opts.block) return "?spend&block";
        if (opts.sats) return "?sats";
        if (opts.spend) return "?spend";
        if (opts.block) return "?block";
        return "";
    }

    fn serializeStringArray(allocator: std.mem.Allocator, strings: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        var writer = buf.writer();
        try writer.writeByte('[');
        for (strings, 0..) |s, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeByte('"');
            try writer.writeAll(s);
            try writer.writeByte('"');
        }
        try writer.writeByte(']');
        return buf.toOwnedSlice();
    }

    fn parseIndexedOutput(json: std.json.Value) !IndexedOutput {
        const obj = json.object;

        return .{
            .outpoint = switch (obj.get("outpoint") orelse return error.MissingField) {
                .string => |s| s,
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
                .string => |s| s,
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
