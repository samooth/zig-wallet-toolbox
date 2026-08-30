comptime {
    _ = @import("http_test.zig");
    _ = @import("e2e_test.zig");
    _ = @import("sqlite_persistence_test.zig");
    _ = @import("privileged_key_test.zig");
    _ = @import("monitor_test.zig");
}
