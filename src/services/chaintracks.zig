const std = @import("std");
const http = @import("../http/client.zig");
const types = @import("types.zig");

pub const ChaintracksClient = struct {
    host: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    const base_path = "/1sat/chaintracks";

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8) ChaintracksClient {
        return .{
            .host = host,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *ChaintracksClient) void {
        _ = self;
    }

    pub fn currentHeight(self: *ChaintracksClient) !u32 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/tip", .{ self.host, base_path });
        defer self.allocator.free(url);

        const result = try http.getJson(self.allocator, self.io, url, &.{});
        if (result.status != .ok) return error.HttpRequestFailed;

        return @intCast(result.body.object.get("height").?.integer);
    }

    pub fn isValidRootForHeight(self: *ChaintracksClient, root: [32]u8, height: u32) !bool {
        const header = try self.findHeaderForHeight(height) orelse return false;
        return std.mem.eql(u8, &header.merkle_root, &root);
    }

    pub fn getHeaderBytes(self: *ChaintracksClient, height: u32) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/headers?height={d}&count=1", .{ self.host, base_path, height });
        defer self.allocator.free(url);

        const result = try http.getBinary(self.allocator, self.io, url, &.{});
        if (result.status != .ok) {
            self.allocator.free(result.body);
            return error.HttpRequestFailed;
        }

        return result.body;
    }

    pub fn findHeaderForHeight(self: *ChaintracksClient, height: u32) !?types.BlockHeader {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/header/height/{d}", .{ self.host, base_path, height });
        defer self.allocator.free(url);

        const result = http.getJson(self.allocator, self.io, url, &.{}) catch return null;
        if (result.status != .ok) return null;

        return try parseBlockHeader(result.body);
    }

    pub fn findHeaderForBlockHash(self: *ChaintracksClient, hash: []const u8) !?types.BlockHeader {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/header/hash/{s}", .{ self.host, base_path, hash });
        defer self.allocator.free(url);

        const result = http.getJson(self.allocator, self.io, url, &.{}) catch return null;
        if (result.status != .ok) return null;

        return try parseBlockHeader(result.body);
    }

    fn parseBlockHeader(json: std.json.Value) !types.BlockHeader {
        const obj = json.object;

        return .{
            .version = @intCast(obj.get("version").?.integer),
            .previous_hash = try parseHexHash(obj.get("previousHash")),
            .merkle_root = try parseHexHash(obj.get("merkleRoot")),
            .time = @intCast(obj.get("time").?.integer),
            .bits = @intCast(obj.get("bits").?.integer),
            .nonce = @intCast(obj.get("nonce").?.integer),
            .height = @intCast(obj.get("height").?.integer),
            .hash = try parseHexHash(obj.get("hash")),
        };
    }

    fn parseHexHash(value: ?std.json.Value) ![32]u8 {
        const hex_str = (value orelse return error.MissingField).string;
        if (hex_str.len != 64) return error.InvalidHashLength;
        var result: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&result, hex_str) catch return error.InvalidHexEncoding;
        return result;
    }
};
