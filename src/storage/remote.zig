const std = @import("std");
const auth_fetch_mod = @import("../auth/auth_fetch.zig");
const json_rpc = @import("../http/json_rpc.zig");
const WalletStorageProvider = @import("interface.zig").WalletStorageProvider;
const types = @import("types.zig");

const log = std.log.scoped(.remote_storage);

pub const RemoteStorageClient = struct {
    allocator: std.mem.Allocator,
    auth_fetch: *auth_fetch_mod.AuthFetch,
    url: []const u8,
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator, auth_fetch: *auth_fetch_mod.AuthFetch, url: []const u8) RemoteStorageClient {
        return .{
            .allocator = allocator,
            .auth_fetch = auth_fetch,
            .url = url,
            .next_id = 1,
        };
    }

    fn rpcCall(self: *RemoteStorageClient, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) !std.json.Value {
        const id = self.next_id;
        self.next_id += 1;

        const request_body = try json_rpc.buildRequest(self.allocator, method, params, id);
        defer self.allocator.free(request_body);

        var response = try self.auth_fetch.postJson(self.url, request_body);
        defer response.deinit();

        log.info("RPC {s} -> status={d} body_len={d}", .{ method, response.status, response.body.len });
        if (response.body.len > 0 and response.body.len < 500) {
            log.info("RPC response body: {s}", .{response.body});
        }

        var parsed = try json_rpc.parseResponse(allocator, response.body);

        if (parsed.@"error") |rpc_err| {
            log.err("RPC error {d}: {s}", .{ rpc_err.code, rpc_err.message });
            parsed.deinit();
            return error.RpcError;
        }

        if (parsed.result) |result| {
            return result;
        }

        parsed.deinit();
        return .null;
    }

    fn buildAuthJson(self: *RemoteStorageClient, auth: types.AuthId) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        try obj.put("identityKey", .{ .string = auth.identity_key });
        if (auth.storage_identity_key) |sik| {
            try obj.put("storageIdentityKey", .{ .string = sik });
        }
        return .{ .object = obj };
    }

    pub fn makeAvailable(self: *RemoteStorageClient, allocator: std.mem.Allocator) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        return self.rpcCall(allocator, "makeAvailable", params);
    }

    pub fn migrate(self: *RemoteStorageClient, allocator: std.mem.Allocator, storage_name: []const u8) anyerror![]const u8 {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(.{ .string = storage_name });

        const result = try self.rpcCall(allocator, "migrate", params);
        return switch (result) {
            .string => |s| s,
            else => error.UnexpectedResponse,
        };
    }

    pub fn findOrInsertUser(self: *RemoteStorageClient, allocator: std.mem.Allocator, identity_key: []const u8) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(.{ .string = identity_key });

        return self.rpcCall(allocator, "findOrInsertUser", params);
    }

    pub fn createAction(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "createAction", params);
    }

    pub fn processAction(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "processAction", params);
    }

    pub fn abortAction(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "abortAction", params);
    }

    pub fn listOutputs(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "listOutputs", params);
    }

    pub fn listActions(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "listActions", params);
    }

    pub fn internalizeAction(self: *RemoteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        var params = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer params.array.deinit();
        try params.array.append(try self.buildAuthJson(auth));
        try params.array.append(args);

        return self.rpcCall(allocator, "internalizeAction", params);
    }

    pub fn destroy(_: *RemoteStorageClient) void {}

    pub fn storageProvider(self: *RemoteStorageClient) WalletStorageProvider {
        return WalletStorageProvider.init(self);
    }

    pub fn deinit(_: *RemoteStorageClient) void {}
};
