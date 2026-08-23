const std = @import("std");

pub const PeerSession = struct {
    is_authenticated: bool,
    session_nonce: ?[]const u8, // our nonce (base64)
    peer_nonce: ?[]const u8, // their nonce (base64)
    peer_identity_key: ?[]const u8, // their public key hex
    last_update: i64, // milliseconds since epoch
};

pub const SessionManager = struct {
    sessions: std.ArrayList(PeerSession),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.sessions.deinit(self.allocator);
    }

    pub fn addSession(self: *SessionManager, session: PeerSession) !void {
        try self.sessions.append(self.allocator, session);
    }

    pub fn updateSession(self: *SessionManager, session: PeerSession) !void {
        if (session.session_nonce) |nonce| {
            for (self.sessions.items) |*s| {
                if (s.session_nonce) |sn| {
                    if (std.mem.eql(u8, sn, nonce)) {
                        s.* = session;
                        return;
                    }
                }
            }
        }
        try self.sessions.append(self.allocator, session);
    }

    /// Look up a session by session_nonce first, then by peer_identity_key
    /// (returning the most recent authenticated session for that key).
    pub fn getSession(self: *SessionManager, identifier: []const u8) ?*PeerSession {
        for (self.sessions.items) |*s| {
            if (s.session_nonce) |sn| {
                if (std.mem.eql(u8, sn, identifier)) return s;
            }
        }

        var best: ?*PeerSession = null;
        for (self.sessions.items) |*s| {
            const key = s.peer_identity_key orelse continue;
            if (!std.mem.eql(u8, key, identifier)) continue;

            if (best == null) {
                best = s;
                continue;
            }
            const b = best.?;
            if (s.last_update > b.last_update) {
                if (s.is_authenticated or !b.is_authenticated) {
                    best = s;
                }
            } else if (s.is_authenticated and !b.is_authenticated) {
                best = s;
            }
        }
        return best;
    }

    pub fn removeSession(self: *SessionManager, session_nonce: []const u8) void {
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            if (self.sessions.items[i].session_nonce) |sn| {
                if (std.mem.eql(u8, sn, session_nonce)) {
                    _ = self.sessions.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    pub fn hasSession(self: *SessionManager, identifier: []const u8) bool {
        return self.getSession(identifier) != null;
    }
};

test "SessionManager add and get by nonce" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addSession(.{
        .is_authenticated = true,
        .session_nonce = "nonce-1",
        .peer_nonce = "peer-nonce-1",
        .peer_identity_key = "02aabb",
        .last_update = 1000,
    });

    const s = mgr.getSession("nonce-1");
    try std.testing.expect(s != null);
    try std.testing.expect(s.?.is_authenticated);
    try std.testing.expectEqualStrings("peer-nonce-1", s.?.peer_nonce.?);
}

test "SessionManager get by identity key returns best session" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addSession(.{
        .is_authenticated = false,
        .session_nonce = "old",
        .peer_nonce = null,
        .peer_identity_key = "02aabb",
        .last_update = 100,
    });
    try mgr.addSession(.{
        .is_authenticated = true,
        .session_nonce = "new",
        .peer_nonce = "pn",
        .peer_identity_key = "02aabb",
        .last_update = 200,
    });

    const s = mgr.getSession("02aabb");
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("new", s.?.session_nonce.?);
}

test "SessionManager remove" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addSession(.{
        .is_authenticated = true,
        .session_nonce = "to-remove",
        .peer_nonce = null,
        .peer_identity_key = "02cc",
        .last_update = 500,
    });

    try std.testing.expect(mgr.hasSession("to-remove"));
    mgr.removeSession("to-remove");
    try std.testing.expect(!mgr.hasSession("to-remove"));
}

test "SessionManager update replaces existing" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addSession(.{
        .is_authenticated = false,
        .session_nonce = "s1",
        .peer_nonce = null,
        .peer_identity_key = "02dd",
        .last_update = 100,
    });

    try mgr.updateSession(.{
        .is_authenticated = true,
        .session_nonce = "s1",
        .peer_nonce = "pn1",
        .peer_identity_key = "02dd",
        .last_update = 200,
    });

    try std.testing.expectEqual(@as(usize, 1), mgr.sessions.items.len);
    const s = mgr.getSession("s1").?;
    try std.testing.expect(s.is_authenticated);
    try std.testing.expectEqual(@as(i64, 200), s.last_update);
}

test "SessionManager get returns null for unknown" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.getSession("nonexistent") == null);
}

test "SessionManager prefers authenticated over newer unauthenticated" {
    var mgr = SessionManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.addSession(.{
        .is_authenticated = true,
        .session_nonce = "auth-old",
        .peer_nonce = null,
        .peer_identity_key = "02ee",
        .last_update = 100,
    });
    try mgr.addSession(.{
        .is_authenticated = false,
        .session_nonce = "unauth-new",
        .peer_nonce = null,
        .peer_identity_key = "02ee",
        .last_update = 200,
    });

    const s = mgr.getSession("02ee");
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("auth-old", s.?.session_nonce.?);
}
