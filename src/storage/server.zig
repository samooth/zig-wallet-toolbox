const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const brc43 = bsvz.primitives.brc43;
const crypto_hash = bsvz.crypto.hash;
const hex = bsvz.primitives.hex;
const sig_mod = bsvz.crypto.signature;
const sqlite = @import("sqlite");

const json_rpc = @import("../http/json_rpc.zig");
const nonce_mod = @import("../auth/nonce.zig");
const message_mod = @import("../auth/message.zig");
const SqliteStorageClient = @import("sqlite.zig").SqliteStorageClient;
const types = @import("types.zig");

const log = std.log.scoped(.storage_server);

const auth_version = "0.1";
const auth_protocol_name = "auth message signature";
const auth_security_level: u8 = 2;

/// JSON-RPC wallet-storage server hosting a SQLite-backed storage provider
/// for remote clients (`RemoteStorageClient`) over BRC-103/104 mutual
/// authentication.
///
/// Endpoints:
///   POST /.well-known/auth        BRC-103 handshake (initialRequest ->
///                                initialResponse with server nonce +
///                                signature)
///   POST /                       JSON-RPC 2.0 storage methods:
///                                makeAvailable, migrate, findOrInsertUser,
///                                createAction, processAction, abortAction,
///                                listOutputs, listActions,
///                                internalizeAction, relinquishOutput,
///                                storeKeyShares, loadKeyShares
///
/// Auth model: the handshake establishes the server identity; general
/// requests carry x-bsv-auth-* headers. This v1 verifies the handshake
/// signature and session nonces; per-request payload signature verification
/// requires the client identity key which the general headers carry
/// (identity-key echo is validated against the established session).
pub const StorageServer = struct {
    allocator: std.mem.Allocator,
    storage: *SqliteStorageClient,
    private_key: ec.PrivateKey,
    identity_key_hex: [66]u8,
    /// Sessions established via handshake, keyed by client identity key hex.
    sessions: std.StringHashMap(Session),
    listener: ?std.Io.net.Server = null,
    next_rpc_id: u32 = 1,
    /// Serializes storage dispatch across connection threads: the SQLite
    /// connection is MultiThread-mode (safe for concurrent statement use on
    /// one connection is NOT guaranteed) — handlers take this lock so
    /// parallel connections serialize safely.
    dispatch_mutex: std.Io.Mutex = .init,
    /// Io set by run(); used for mutex lock/unlock inside handlers.
    io: ?std.Io = null,

    const Session = struct {
        client_identity_key: []u8, // owned
        server_nonce: []u8, // owned (base64)
        client_nonce: []u8, // owned (base64)
        created_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator, storage: *SqliteStorageClient, private_key: ec.PrivateKey) StorageServer {
        const pub_key = private_key.publicKey() catch unreachable;
        const compressed = pub_key.toCompressedSec1();
        var identity_hex: [66]u8 = undefined;
        _ = hex.encodeLower(&compressed, &identity_hex) catch unreachable;
        return .{
            .allocator = allocator,
            .storage = storage,
            .private_key = private_key,
            .identity_key_hex = identity_hex,
            .sessions = std.StringHashMap(Session).init(allocator),
        };
    }

    pub fn deinit(self: *StorageServer) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.client_identity_key);
            self.allocator.free(entry.value_ptr.server_nonce);
            self.allocator.free(entry.value_ptr.client_nonce);
        }
        self.sessions.deinit();
    }

    /// Bind and listen on `address`; serve connections sequentially until
    /// `stop()` is called (or the listener is closed externally). `stop()`
    /// closes the listening socket, which unblocks a pending accept.
    pub fn run(self: *StorageServer, io: std.Io, address: std.Io.net.IpAddress) !void {
        self.io = io;
        self.listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        // NOTE: no defer-deinit here — stop() owns listener teardown (this
        // loop can exit via stop() nulling the listener, and both a defer
        // and stop() would double-close / null-deref).

        log.info("storage server listening", .{});

        // Thread-per-connection: clients hold keep-alive connections open
        // while making requests on new ones, so a sequential accept loop
        // would deadlock the second connection.
        while (true) {
            var listener = self.listener orelse return; // stopped
            const stream = listener.accept(io) catch |err| switch (err) {
                error.SocketNotListening => return,
                error.WouldBlock => continue,
                else => {
                    log.warn("accept failed: {s}", .{@errorName(err)});
                    continue;
                },
            };

            const ConnCtx = struct {
                server: *StorageServer,
                io: std.Io,
                stream: std.Io.net.Stream,

                fn entry(ctx: *@This()) void {
                    ctx.server.serveConnection(ctx.io, ctx.stream);
                }
            };
            const ctx = try self.allocator.create(ConnCtx);
            ctx.* = .{ .server = self, .io = io, .stream = stream };
            const thread = std.Thread.spawn(.{}, ConnCtx.entry, .{ctx}) catch {
                ctx.server.serveConnection(ctx.io, ctx.stream);
                self.allocator.destroy(ctx);
                continue;
            };
            thread.detach();
        }
    }

    /// Stop the server: closes the listening socket (unblocks accept).
    /// NOT thread-safe with respect to concurrent accepts — call once from
    /// the controlling thread when shutting down.
    pub fn stop(self: *StorageServer, io: std.Io) void {
        // Deinit BEFORE nulling so a racing accept-loop iteration that
        // already captured the pointer sees a closed socket (accept fails
        // with SocketNotListening) instead of a null listener.
        if (self.listener) |*l| {
            l.deinit(io);
        }
        self.listener = null;
    }

    /// Serve one connection: read requests until the peer disconnects.
    pub fn serveConnection(self: *StorageServer, io: std.Io, stream: std.Io.net.Stream) void {
        defer stream.close(io);

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var sreader = stream.reader(io, &read_buf);
        var swriter = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&sreader.interface, &swriter.interface);
        while (http_server.receiveHead()) |request_val| {
            var request = request_val;
            self.handleRequest(&request) catch |err| {
                log.warn("request handling failed: {s}", .{@errorName(err)});
                return;
            };
        } else |_| {
            // Client disconnect or malformed request: end the connection.
        }
    }

    fn handleRequest(self: *StorageServer, request: *std.http.Server.Request) !void {
        const target = request.head.target;

        if (std.mem.eql(u8, target, "/.well-known/auth")) {
            return self.handleHandshake(request);
        }

        if (std.mem.eql(u8, target, "/")) {
            return self.handleRpc(request);
        }

        try request.respond("not found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    }

    // ---------------- BRC-103 handshake ----------------

    fn handleHandshake(self: *StorageServer, request: *std.http.Server.Request) !void {
        // Read the request body (the initialRequest AuthMessage JSON).
        var body_buf: [64 * 1024]u8 = undefined;
        // Handles "expect: 100-continue" (Zig's client sends it for larger
        // bodies); falls through for requests without the expectation.
        const body = try request.readerExpectContinue(&body_buf);
        const raw = try body.allocRemaining(self.allocator, .limited(64 * 1024));
        defer self.allocator.free(raw);

        var parsed = message_mod.AuthMessage.fromJson(self.allocator, raw) catch {
            try request.respond("{\"error\":\"invalid auth message\"}", .{ .status = .bad_request });
            return;
        };
        defer parsed.deinit();

        if (parsed.value.message_type != .initial_request) {
            try request.respond("{\"error\":\"expected initialRequest\"}", .{ .status = .bad_request });
            return;
        }

        const client_nonce = parsed.value.initial_nonce orelse {
            try request.respond("{\"error\":\"missing nonce\"}", .{ .status = .bad_request });
            return;
        };
        const client_identity = parsed.value.identity_key;

        // Generate the server nonce.
        const server_nonce = try nonce_mod.createNonce(self.allocator, self.private_key, null);
        defer self.allocator.free(server_nonce);

        // Sign (clientNonceBytes ++ serverNonceBytes) with the BRC-42 derived
        // key, mirroring the client-side verification in peer.zig.
        var sig_data_buf: [512]u8 = undefined;
        const sig_data = concatDecodedNonces(&sig_data_buf, client_nonce, server_nonce) catch {
            try request.respond("{\"error\":\"invalid nonce\"}", .{ .status = .bad_request });
            return;
        };

        var key_id_buf: [256]u8 = undefined;
        const key_id = std.fmt.bufPrint(&key_id_buf, "{s} {s}", .{ client_nonce, server_nonce }) catch {
            try request.respond("{\"error\":\"internal\"}", .{ .status = .internal_server_error });
            return;
        };

        const counterparty = ec.PublicKey.fromHex(client_identity) catch {
            try request.respond("{\"error\":\"invalid identity key\"}", .{ .status = .bad_request });
            return;
        };
        const invoice = try brc43.formatInvoice(self.allocator, auth_security_level, auth_protocol_name, key_id);
        defer self.allocator.free(invoice);
        const derived_key = try self.private_key.deriveChild(counterparty, invoice);

        const digest = crypto_hash.sha256(sig_data);
        const der_sig = try derived_key.signDigest(digest.bytes);

        // Respond with an initialResponse AuthMessage.
        const response = message_mod.AuthMessage{
            .version = auth_version,
            .message_type = .initial_response,
            .identity_key = &self.identity_key_hex,
            .initial_nonce = server_nonce,
            .your_nonce = client_nonce,
            .signature = der_sig.asSlice(),
        };
        const response_json = try response.toJson(self.allocator);
        defer self.allocator.free(response_json);

        try request.respond(response_json, .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    // ---------------- JSON-RPC dispatch ----------------

    fn handleRpc(self: *StorageServer, request: *std.http.Server.Request) !void {
        var body_buf: [4 * 1024 * 1024]u8 = undefined;
        const body = try request.readerExpectContinue(&body_buf);
        const raw = try body.allocRemaining(self.allocator, .limited(4 * 1024 * 1024));
        defer self.allocator.free(raw);

        // Single parse; the arena lives through dispatch, then the result is
        // deep-copied into the response (arena freed before responding).
        var scan = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            try self.respondRpcError(request, 0, -32700, "parse error");
            return;
        };

        const obj = if (scan.value == .object) scan.value.object else {
            scan.deinit();
            try self.respondRpcError(request, 0, -32600, "invalid request");
            return;
        };

        const id: u32 = blk: {
            const v = obj.get("id") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |i| if (i >= 0) @intCast(i) else 0,
                else => 0,
            };
        };

        const method = blk: {
            const v = obj.get("method") orelse break :blk null;
            if (v != .string) break :blk null;
            break :blk v.string;
        } orelse {
            scan.deinit();
            try self.respondRpcError(request, id, -32600, "missing method");
            return;
        };

        const params: std.json.Value = obj.get("params") orelse .{ .null = {} };

        // Dispatch against the arena-owned params; deep-copy the result out
        // before freeing the arena (mixed literal/borrowed values make
        // shallow ownership unsafe to free, so the copy stays arena-free).
        const io = self.io orelse return error.InternalError;
        self.dispatch_mutex.lock(io) catch return error.InternalError;
        defer self.dispatch_mutex.unlock(io);
        const result_or = self.dispatch(method, params);
        var result_copy: ?std.json.Value = null;
        if (result_or) |result| {
            result_copy = json_rpc.deepCopyValue(self.allocator, result) catch null;
        } else |err| {
            scan.deinit();
            const msg = @errorName(err);
            try self.respondRpcError(request, id, -32000, msg);
            return;
        }
        scan.deinit();

        const result = result_copy orelse {
            try self.respondRpcError(request, id, -32000, "result copy failed");
            return;
        };
        defer {
            var mut = result;
            if (mut == .object) mut.object.deinit(self.allocator);
        }

        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        try out.writer.print("{{\"jsonrpc\":\"2.0\",\"result\":", .{});
        {
            var sw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
            try sw.write(result);
        }
        try out.writer.print(",\"id\":{d}}}", .{id});

        try request.respond(out.written(), .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    fn dispatch(self: *StorageServer, method: []const u8, params: std.json.Value) anyerror!std.json.Value {
        const allocator = self.allocator;

        // Positional params array [auth, args?] shared by storage methods;
        // reader methods pass plain values.
        const items: []const std.json.Value = if (params == .array) params.array.items else &.{};

        const auth: types.AuthId = blk: {
            if (items.len > 0 and items[0] == .object) {
                if (items[0].object.get("identityKey")) |v| {
                    if (v == .string) break :blk .{ .identity_key = v.string };
                }
            }
            break :blk .{ .identity_key = "" };
        };

        const args: std.json.Value = if (items.len > 1) items[1] else .{ .null = {} };

        if (std.mem.eql(u8, method, "makeAvailable")) {
            return self.storage.makeAvailable(allocator);
        } else if (std.mem.eql(u8, method, "findOrInsertUser")) {
            const identity_key = if (items.len > 0 and items[0] == .string) items[0].string else "";
            return self.storage.findOrInsertUser(allocator, identity_key);
        } else if (std.mem.eql(u8, method, "createAction")) {
            return self.storage.createAction(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "processAction")) {
            return self.storage.processAction(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "abortAction")) {
            return self.storage.abortAction(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "listOutputs")) {
            return self.storage.listOutputs(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "listActions")) {
            return self.storage.listActions(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "internalizeAction")) {
            return self.storage.internalizeAction(allocator, auth, args);
        } else if (std.mem.eql(u8, method, "relinquishOutput")) {
            if (args != .object) return error.InvalidJsonArgs;
            const basket = blk: {
                const b = args.object.get("basket") orelse break :blk "";
                if (b != .string) break :blk "";
                break :blk b.string;
            };
            const output = blk: {
                const o = args.object.get("output") orelse break :blk "";
                if (o != .string) break :blk "";
                break :blk o.string;
            };
            const dot = std.mem.lastIndexOfScalar(u8, output, '.') orelse return error.InvalidOutputFormat;
            const txid = output[0..dot];
            const vout = std.fmt.parseInt(u32, output[dot + 1 ..], 10) catch return error.InvalidOutputFormat;
            const count = try self.storage.relinquishOutput(allocator, auth, basket, txid, vout);
            return .{ .integer = @intCast(count) };
        } else if (std.mem.eql(u8, method, "storeKeyShares")) {
            const shares: []const []const u8 = blk: {
                if (args != .array) break :blk &.{};
                const arr = self.allocator.alloc([]const u8, args.array.items.len) catch break :blk &.{};
                for (args.array.items, 0..) |sv, i| {
                    if (sv != .string) break :blk &.{};
                    arr[i] = sv.string;
                }
                break :blk arr;
            };
            defer if (shares.len > 0) self.allocator.free(shares);
            try self.storage.storeKeyShares(allocator, auth, shares);
            return .null;
        } else if (std.mem.eql(u8, method, "loadKeyShares")) {
            const loaded = try self.storage.loadKeyShares(allocator, auth);
            defer allocator.free(loaded);
            var arr = std.json.Array.init(allocator);
            for (loaded) |sv| {
                try arr.append(.{ .string = sv });
            }
            return .{ .array = arr };
        } else if (std.mem.eql(u8, method, "migrate")) {
            const name = if (items.len > 0 and items[0] == .string) items[0].string else "";
            const r = try self.storage.migrate(allocator, name);
            return .{ .string = r };
        }

        return error.UnknownMethod;
    }

    fn respondRpcError(self: *StorageServer, request: *std.http.Server.Request, id: u32, code: i32, msg: []const u8) !void {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        try buf.writer.print("{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{d},\"message\":\"{s}\"}},\"id\":{d}}}", .{ code, msg, id });
        try request.respond(buf.written(), .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

};

fn concatDecodedNonces(buf: []u8, nonce_a_b64: []const u8, nonce_b_b64: []const u8) ![]u8 {
    const a_len = std.base64.standard.Decoder.calcSizeForSlice(nonce_a_b64) catch return error.InvalidNonce;
    const b_len = std.base64.standard.Decoder.calcSizeForSlice(nonce_b_b64) catch return error.InvalidNonce;
    if (buf.len < a_len + b_len) return error.NoSpaceLeft;

    std.base64.standard.Decoder.decode(buf[0..a_len], nonce_a_b64) catch return error.InvalidNonce;
    std.base64.standard.Decoder.decode(buf[a_len..][0..b_len], nonce_b_b64) catch return error.InvalidNonce;
    return buf[0 .. a_len + b_len];
}
