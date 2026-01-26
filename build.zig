const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建 root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 创建可执行文件
    const exe = b.addExecutable(.{
        .name = "stz",
        .root_module = root_module,
    });

    // 链接 X11 和相关库
    exe.linkLibC();
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("Xft");
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("harfbuzz");

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
            .root_source_file = b.path("src/parser_test.zig"),
            .target = target,
            .optimize = optimize,
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
            .root_source_file = b.path("src/selection_test.zig"),
            .target = target,
            .optimize = optimize,
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
