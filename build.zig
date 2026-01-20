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

    b.installArtifact(exe);

    // 运行步骤
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run stz");
    run_step.dependOn(&run_cmd.step);
}
