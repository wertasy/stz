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
    const test_step = b.step("test", "Run all unit tests");

    // 自动发现 tests 目录下的所有测试文件
    const tests_dir_path = "tests";
    var tests_dir = std.fs.cwd().openDir(tests_dir_path, .{ .iterate = true }) catch |err| {
        // 如果目录不存在，打印警告但不要崩溃
        std.debug.print("Warning: tests directory not found: {}\n", .{err});
        return;
    };
    defer tests_dir.close();

    var walker = tests_dir.walk(b.allocator) catch |err| {
        std.debug.print("Error walking tests directory: {}\n", .{err});
        return;
    };
    defer walker.deinit();

    while (walker.next() catch |err| {
        std.debug.print("Error iterating tests directory: {}\n", .{err});
        return;
    }) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            const path = b.fmt("{s}/{s}", .{ tests_dir_path, entry.path });

            const t = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "stz", .module = mod },
                    },
                }),
            });

            // 链接依赖
            t.linkLibC();
            t.linkSystemLibrary("X11");
            t.linkSystemLibrary("Xft");
            t.linkSystemLibrary("fontconfig");
            t.linkSystemLibrary("freetype");
            t.linkSystemLibrary("harfbuzz");

            const run_t = b.addRunArtifact(t);
            test_step.dependOn(&run_t.step);
        }
    }
}
