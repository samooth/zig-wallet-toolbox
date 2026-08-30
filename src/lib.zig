pub const auth = @import("auth/lib.zig");
pub const http = @import("http/lib.zig");
pub const monitor = @import("monitor/monitor.zig");
pub const services = @import("services/lib.zig");
pub const signer = @import("signer/lib.zig");
pub const storage = @import("storage/lib.zig");
pub const util = @import("util.zig");
pub const wallet = @import("wallet.zig");
pub const keymanagement = @import("keymanagement/privileged.zig");

// Re-export dependencies for C ABI target
pub const bsvz = @import("bsvz");
pub const sqlite = @import("sqlite");

test {
    // refAllDeclsRecursive disabled: hits Zig 0.17 `address_space` in transitive deps
    // @import("util.zig").refAllDeclsRecursive(@This());
}
