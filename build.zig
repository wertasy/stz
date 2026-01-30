const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建 stz module
    const mod = b.createModule(.{
        .root_source_file = b.path("src/stz/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 链接 X11 和相关库
    mod.addImport("stz", mod);
    mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("Xft", .{});
    mod.linkSystemLibrary("fontconfig", .{});
    mod.linkSystemLibrary("harfbuzz", .{});

    // 创建 root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "stz", .module = mod },
        },
    });

    // 创建可执行文件
    const exe = b.addExecutable(.{
        .name = "stz",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // 运行步骤
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run stz");
    run_step.dependOn(&run_cmd.step);

    // 测试步骤
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stz/parser_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stz", .module = mod },
            },
        }),
    });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("X11");
    unit_tests.linkSystemLibrary("Xft");
    unit_tests.linkSystemLibrary("fontconfig");
    unit_tests.linkSystemLibrary("freetype");
    unit_tests.linkSystemLibrary("harfbuzz");

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const selection_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stz/selection_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "stz", .module = mod },
            },
        }),
    });
    selection_tests.linkLibC();
    selection_tests.linkSystemLibrary("X11");
    selection_tests.linkSystemLibrary("Xft");
    selection_tests.linkSystemLibrary("fontconfig");
    selection_tests.linkSystemLibrary("freetype");
    selection_tests.linkSystemLibrary("harfbuzz");
    const run_selection_tests = b.addRunArtifact(selection_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_selection_tests.step);
}
