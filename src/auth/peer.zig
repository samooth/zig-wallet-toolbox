const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const brc43 = bsvz.primitives.brc43;
const crypto_hash = bsvz.crypto.hash;
const hex = bsvz.primitives.hex;
const sig_mod = bsvz.crypto.signature;

const nonce_mod = @import("nonce.zig");
const session_mod = @import("session.zig");
const message_mod = @import("message.zig");
const payload_mod = @import("payload.zig");
const transport_mod = @import("transport.zig");

const PrivateKey = ec.PrivateKey;
const PublicKey = ec.PublicKey;
const AuthMessage = message_mod.AuthMessage;
const MessageType = message_mod.MessageType;
const PeerSession = session_mod.PeerSession;
const SessionManager = session_mod.SessionManager;
const SimplifiedHttpTransport = transport_mod.SimplifiedHttpTransport;

const auth_version = "0.1";
const auth_protocol_name = "auth message signature";
const auth_security_level: u8 = 2;

pub const Peer = struct {
    private_key: PrivateKey,
    identity_key_hex: [66]u8,
    transport: SimplifiedHttpTransport,
    session_manager: SessionManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, private_key: PrivateKey, base_url: []const u8) !Peer {
        const pub_key = try private_key.publicKey();
        var identity_hex: [66]u8 = undefined;
        _ = pub_key.toDerHex(&identity_hex);

        return .{
            .private_key = private_key,
            .identity_key_hex = identity_hex,
            .transport = SimplifiedHttpTransport.init(allocator, base_url),
            .session_manager = SessionManager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Peer) void {
        self.session_manager.deinit();
    }

    /// Get or create an authenticated session with the peer.
    /// Initiates a handshake if no authenticated session exists.
    pub fn getAuthenticatedSession(self: *Peer, peer_identity_key: ?[]const u8) !*PeerSession {
        if (peer_identity_key) |key| {
            if (self.session_manager.getSession(key)) |s| {
                if (s.is_authenticated) return s;
            }
        }
        return self.initiateHandshake();
    }

    /// Send an authenticated message and return the response body.
    pub fn sendMessage(
        self: *Peer,
        method: []const u8,
        url: []const u8,
        request_payload: []const u8,
    ) !SendResult {
        const session = try self.getAuthenticatedSession(null);

        const our_nonce = session.session_nonce orelse return error.SessionMissingNonce;
        const peer_nonce = session.peer_nonce orelse return error.SessionMissingPeerNonce;
        const peer_identity = session.peer_identity_key orelse return error.SessionMissingPeerKey;

        // Sign the payload
        const signature = try self.createSignature(request_payload, our_nonce, peer_nonce, peer_identity);
        defer self.allocator.free(signature);

        // Base64-encode the payload for the AuthMessage
        const payload_b64_len = std.base64.standard.Encoder.calcSize(request_payload.len);
        const payload_b64 = try self.allocator.alloc(u8, payload_b64_len);
        defer self.allocator.free(payload_b64);
        _ = std.base64.standard.Encoder.encode(payload_b64, request_payload);

        const msg = AuthMessage{
            .version = auth_version,
            .message_type = .general,
            .identity_key = &self.identity_key_hex,
            .nonce = our_nonce,
            .your_nonce = peer_nonce,
            .payload = payload_b64,
            .signature = signature,
        };

        const response = try self.transport.sendGeneral(msg, method, url);
        // Transfer ownership of the response body to the caller
        return .{
            .body = response.body,
            .status = response.status,
            .allocator = self.allocator,
        };
    }

    fn initiateHandshake(self: *Peer) !*PeerSession {
        // Create our nonce
        const client_nonce = try nonce_mod.createNonce(self.allocator, self.private_key, null);
        defer self.allocator.free(client_nonce);

        // Add preliminary session
        try self.session_manager.addSession(.{
            .is_authenticated = false,
            .session_nonce = client_nonce,
            .peer_nonce = null,
            .peer_identity_key = null,
            .last_update = std.time.milliTimestamp(),
        });

        // Build initialRequest
        const initial_request = AuthMessage{
            .version = auth_version,
            .message_type = .initial_request,
            .identity_key = &self.identity_key_hex,
            .initial_nonce = client_nonce,
        };

        // Send handshake and get response
        var response = try self.transport.sendHandshake(initial_request);
        defer response.deinit();

        const resp_msg = response.value;

        // Validate response type
        if (resp_msg.message_type != .initial_response) {
            return error.UnexpectedMessageType;
        }

        const server_nonce = resp_msg.initial_nonce orelse return error.MissingServerNonce;
        const your_nonce = resp_msg.your_nonce orelse return error.MissingYourNonce;

        // Verify the server echoed back our nonce
        if (!std.mem.eql(u8, your_nonce, client_nonce)) {
            return error.NonceMismatch;
        }

        // Verify server's signature
        // Data signed: concat(clientNonceBytes, serverNonceBytes)
        const sig_data = try concatDecodedNonces(self.allocator, client_nonce, server_nonce);
        defer self.allocator.free(sig_data);

        // keyID: "{clientNonce} {serverNonce}"
        const key_id = try buildKeyId(self.allocator, client_nonce, server_nonce);
        defer self.allocator.free(key_id);

        const server_identity = resp_msg.identity_key;
        try verifySignature(
            self.allocator,
            self.private_key,
            server_identity,
            sig_data,
            key_id,
            resp_msg.signature orelse return error.MissingSignature,
        );

        // Update session to authenticated
        try self.session_manager.updateSession(.{
            .is_authenticated = true,
            .session_nonce = client_nonce,
            .peer_nonce = server_nonce,
            .peer_identity_key = server_identity,
            .last_update = std.time.milliTimestamp(),
        });

        return self.session_manager.getSession(client_nonce) orelse return error.SessionNotFound;
    }

    fn createSignature(
        self: *Peer,
        data: []const u8,
        our_nonce: []const u8,
        peer_nonce: []const u8,
        peer_identity_hex: []const u8,
    ) ![]const u8 {
        const key_id = try buildKeyId(self.allocator, our_nonce, peer_nonce);
        defer self.allocator.free(key_id);

        // Derive signing key using BRC-42
        const counterparty = try PublicKey.fromHex(peer_identity_hex);
        const invoice = try brc43.formatInvoice(self.allocator, auth_security_level, auth_protocol_name, key_id);
        defer self.allocator.free(invoice);

        const derived_key = try self.private_key.deriveChild(counterparty, invoice);

        // SHA-256 digest of the data
        const digest = crypto_hash.sha256(data);

        // Sign
        const der_sig = try derived_key.signDigest(digest.bytes);

        // Base64-encode the DER signature
        const b64_len = std.base64.standard.Encoder.calcSize(der_sig.len);
        const b64_buf = try self.allocator.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64_buf, der_sig.asSlice());

        return b64_buf;
    }

    pub const SendResult = struct {
        body: []u8,
        status: std.http.Status,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *SendResult) void {
            self.allocator.free(self.body);
        }
    };
};

fn verifySignature(
    allocator: std.mem.Allocator,
    our_private_key: PrivateKey,
    peer_identity_hex: []const u8,
    data: []const u8,
    key_id: []const u8,
    signature_b64: []const u8,
) !void {
    const counterparty = try PublicKey.fromHex(peer_identity_hex);

    const invoice = try brc43.formatInvoice(allocator, auth_security_level, auth_protocol_name, key_id);
    defer allocator.free(invoice);

    // Derive the expected signing public key (counterparty side)
    const derived_pub = try counterparty.deriveChild(our_private_key, invoice);

    // Decode the signature from base64
    const sig_decoded_len = std.base64.standard.Decoder.calcSizeForSlice(signature_b64) catch return error.InvalidSignature;
    const sig_bytes = try allocator.alloc(u8, sig_decoded_len);
    defer allocator.free(sig_bytes);
    std.base64.standard.Decoder.decode(sig_bytes, signature_b64) catch return error.InvalidSignature;

    const der_sig = sig_mod.DerSignature.fromDer(sig_bytes) catch return error.InvalidSignature;

    // SHA-256 digest of the data
    const digest = crypto_hash.sha256(data);

    const valid = derived_pub.verifyDigest(digest.bytes, der_sig) catch return error.InvalidSignature;
    if (!valid) return error.InvalidSignature;
}

fn concatDecodedNonces(allocator: std.mem.Allocator, nonce_a_b64: []const u8, nonce_b_b64: []const u8) ![]u8 {
    const a_len = std.base64.standard.Decoder.calcSizeForSlice(nonce_a_b64) catch return error.InvalidNonce;
    const b_len = std.base64.standard.Decoder.calcSizeForSlice(nonce_b_b64) catch return error.InvalidNonce;

    const buf = try allocator.alloc(u8, a_len + b_len);
    errdefer allocator.free(buf);

    std.base64.standard.Decoder.decode(buf[0..a_len], nonce_a_b64) catch return error.InvalidNonce;
    std.base64.standard.Decoder.decode(buf[a_len..], nonce_b_b64) catch return error.InvalidNonce;

    return buf;
}

fn buildKeyId(allocator: std.mem.Allocator, nonce_a: []const u8, nonce_b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ nonce_a, nonce_b });
}

test "buildKeyId" {
    const allocator = std.testing.allocator;
    const result = try buildKeyId(allocator, "abc", "xyz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc xyz", result);
}

test "concatDecodedNonces" {
    const allocator = std.testing.allocator;
    // base64("hello") = "aGVsbG8=", base64("world") = "d29ybGQ="
    const result = try concatDecodedNonces(allocator, "aGVsbG8=", "d29ybGQ=");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("helloworld", result);
}

test "Peer init and deinit" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();
    var peer = try Peer.init(allocator, priv, "http://localhost:8080");
    defer peer.deinit();

    try std.testing.expectEqual(@as(usize, 66), peer.identity_key_hex.len);
}
