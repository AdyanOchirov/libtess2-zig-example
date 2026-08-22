const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libtess2_dep = b.dependency("libtess2", .{ .target = target, .optimize = optimize });
    const libtess2 = libtess2_dep.module("libtess2_zig");

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });

    const example = b.addModule(
        "libtess2_example",
        .{
            .root_source_file = b.path("src/libtess2_example.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    example.addImport("libtess2", libtess2);
    example.addImport("dvui", dvui_dep.module("dvui_sdl3"));

    const main = b.addModule(
        "main",
        .{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    main.addImport("example", example);
    main.addImport("sdl-backend", dvui_dep.module("sdl3"));

    const main_exe = b.addExecutable(.{
        .name = "main",
        .root_module = main,
    });

    b.installArtifact(main_exe);

    const main_exe_run = b.addRunArtifact(main_exe);
    const run_step = b.step("run", "Run");
    run_step.dependOn(&main_exe_run.step);

    const main_exe_check = b.addExecutable(.{
        .name = "main",
        .root_module = main,
    });
    const check_step = b.step("check", "Check");
    check_step.dependOn(&main_exe_check.step);
}
