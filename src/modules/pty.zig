//! 伪终端管理
//! 使用 POSIX 伪终端 PTY 与子 shell 通信

const std = @import("std");
const builtin = @import("builtin");

pub const PtyError = error{
    OpenFailed,
    ForkFailed,
    ExecFailed,
    ReadFailed,
    WriteFailed,
};

/// 伪终端结构
pub const PTY = struct {
    master: std.posix.fd_t = -1,
    slave: std.posix.fd_t = -1,
    pid: std.os.linux.pid_t = 0,
    cols: usize = 80,
    rows: usize = 24,

    /// 初始化伪终端
    pub fn init(shell: ?[:0]const u8, cols: usize, rows: usize) !PTY {
        var pty = PTY{
            .cols = cols,
            .rows = rows,
        };

        // 打开伪终端
        if (comptime builtin.os.tag == .linux) {
            // Linux: 使用 openpty
            var winsize: std.posix.winsize = .{
                .ws_col = @intCast(cols),
                .ws_row = @intCast(rows),
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            const ret = std.os.linux.openpty(null, &pty.slave, &winsize, null);
            if (ret == -1) {
                return error.OpenFailed;
            }
            pty.master = @intCast(ret);
        } else if (comptime builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
            // BSD: 使用 openpty
            var name: [1024]u8 = undefined;
            var winsize: std.posix.winsize = .{
                .ws_col = @intCast(cols),
                .ws_row = @intCast(rows),
            };

            const ret = std.os.system.openpty(&name, &pty.slave, &winsize);
            if (ret == -1) {
                return error.OpenFailed;
            }
            pty.master = @intCast(ret);
        } else {
            return error.OpenFailed;
        }

        // Fork 子进程
        const pid = std.os.fork() catch |err| {
            _ = err;
            return error.ForkFailed;
        };

        if (pid == 0) {
            // 子进程
            try pty.runChild(shell);
        } else {
            // 父进程
            pty.pid = pid;
            // 关闭 slave 端
            if (pty.slave != -1) {
                std.os.close(pty.slave);
            }
        }

        return pty;
    }

    /// 运行子进程
    fn runChild(self: *PTY, shell: ?[:0]const u8) !void {
        // 设置会话 ID
        _ = std.os.setsid(std.os.getpid()) catch |err| {
            _ = err;
            std.os.exit(1);
        };

        // 重定向 stdio 到 PTY
        if (self.slave == -1) return;
        _ = std.os.dup2(self.slave, std.os.STDIN_FILENO);
        _ = std.os.dup2(self.slave, std.os.STDOUT_FILENO);
        _ = std.os.dup2(self.slave, std.os.STDERR_FILENO);

        // 关闭不需要的文件描述符
        std.os.close(self.slave);
        std.os.close(self.master);

        // 设置终端类型
        if (std.os.getenv("TERM")) |term| {
            std.os.setenv("TERM", term) catch {};
        }

        // 执行 shell
        const shell_path = shell orelse "/bin/sh";
        const argv = [_]?[*:0]const u8{ shell_path, null };

        std.os.execv(shell_path, &argv) catch |err| {
            _ = err;
            std.os.exit(1);
        };
    }

    /// 读取数据
    pub fn read(self: *PTY, buffer: []u8) !usize {
        const n = std.os.read(self.master, buffer) catch |err| {
            _ = err;
            return error.ReadFailed;
        };
        return n;
    }

    /// 写入数据
    pub fn write(self: *PTY, data: []const u8) !usize {
        var written: usize = 0;
        while (written < data.len) {
            const n = std.os.write(self.master, data[written..]) catch |err| {
                _ = err;
                return error.WriteFailed;
            };
            if (n == 0) {
                return error.WriteFailed;
            }
            written += n;
        }
        return written;
    }

    /// 调整大小
    pub fn resize(self: *PTY, cols: usize, rows: usize) !void {
        if (comptime builtin.os.tag == .linux) {
            var winsize: std.posix.winsize = .{
                .ws_col = @intCast(cols),
                .ws_row = @intCast(rows),
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };
            _ = std.os.linux.ioctl(self.master, std.os.linux.T.IOCGWINSZ, &winsize) catch |err| {
                _ = err;
                return error.WriteFailed;
            };
        }

        self.cols = cols;
        self.rows = rows;
    }

    /// 关闭
    pub fn close(self: *PTY) void {
        if (self.master != -1) {
            std.os.close(self.master);
        }
        if (self.slave != -1) {
            std.os.close(self.slave);
        }
        if (self.pid != 0) {
            // 发送 SIGHUP 给子进程
            _ = std.os.kill(self.pid, std.os.SIG.HUP) catch {};
        }
    }

    /// 检查子进程状态
    pub fn wait(self: *PTY) !u8 {
        var status: i32 = undefined;
        _ = std.os.waitpid(self.pid, &status, 0) catch |err| {
            _ = err;
            return 0;
        };

        if (std.os.W.IFEXITED(status)) {
            return @intCast(std.os.W.EXITSTATUS(status));
        } else if (std.os.W.IFSIGNALED(status)) {
            const sig = std.os.W.TERMSIG(status);
            return @intCast(sig);
        }

        return 1;
    }
};
