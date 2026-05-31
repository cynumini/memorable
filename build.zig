const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap = b.dependency("clap", .{});
    const exe = b.addExecutable(.{
        .name = "omoshiroi",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("readline", .{});
    b.installArtifact(exe);
    const run_step = b.step("run", "Run omoshiroi");
    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_step.dependOn(&run_cmd.step);
}
