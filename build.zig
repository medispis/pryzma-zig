const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pryzma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.linkSystemLibrary("python3.14", .{});
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include/python3.14" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the Pryzma interpreter");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_cmd = b.addSystemCommand(&.{ "bash", "tests/run_tests.sh" });
    test_cmd.addArtifactArg(exe);
    test_cmd.setCwd(b.path("."));
    test_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&test_cmd.step);
}
