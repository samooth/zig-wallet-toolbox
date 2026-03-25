const std = @import("std");
const http = @import("../http/client.zig");

pub const BeefClient = struct {
    host: []const u8,
    allocator: std.mem.Allocator,

    const base_path = "/1sat/beef";

    pub fn init(allocator: std.mem.Allocator, host: []const u8) BeefClient {
        return .{
            .host = host,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BeefClient) void {
        _ = self;
    }

    pub fn getBeef(self: *BeefClient, txid: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}", .{ self.host, base_path, txid });
        defer self.allocator.free(url);

        const result = try http.getBinary(self.allocator, url, &.{});
        if (result.status != .ok) {
            self.allocator.free(result.body);
            return error.HttpRequestFailed;
        }

        return result.body;
    }

    pub fn getRawTx(self: *BeefClient, txid: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/tx", .{ self.host, base_path, txid });
        defer self.allocator.free(url);

        const result = try http.getBinary(self.allocator, url, &.{});
        if (result.status != .ok) {
            self.allocator.free(result.body);
            return error.HttpRequestFailed;
        }

        return result.body;
    }

    pub fn getProof(self: *BeefClient, txid: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}/proof", .{ self.host, base_path, txid });
        defer self.allocator.free(url);

        const result = try http.getBinary(self.allocator, url, &.{});
        if (result.status != .ok) {
            self.allocator.free(result.body);
            return error.HttpRequestFailed;
        }

        return result.body;
    }
};
