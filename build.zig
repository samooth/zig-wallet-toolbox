const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bsvz_dep = b.dependency("bsvz", .{
        .target = target,
        .optimize = optimize,
    });
    const bsvz_module = bsvz_dep.module("bsvz");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("bsvz", bsvz_module);

    const lib = b.addLibrary(.{
        .name = "zig-wallet-toolbox",
        .root_module = root_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // C-compatible static library with exported symbols
    const c_module = b.createModule(.{
        .root_source_file = b.path("src/exports.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_module.addImport("bsvz", bsvz_module);
    c_module.addImport("zig-wallet-toolbox", root_module);

    const c_lib = b.addLibrary(.{
        .name = "bsvwallet_c",
        .root_module = c_module,
        .linkage = .static,
    });
    b.installArtifact(c_lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.setCwd(b.path("."));

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zig-wallet-toolbox", root_module);
    test_module.addImport("bsvz", bsvz_module);

    const integration_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
