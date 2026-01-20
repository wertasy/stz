//! 伪终端管理
//! 使用 POSIX 伪终端 PTY 与子 shell 通信

const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("signal.h");
});

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
        var winsize: c.struct_winsize = .{
            .ws_col = @intCast(cols),
            .ws_row = @intCast(rows),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.openpty(&pty.master, &pty.slave, null, null, &winsize) != 0) {
            return error.OpenFailed;
        }

        // Fork 子进程
        const pid = c.fork();
        if (pid < 0) {
            return error.ForkFailed;
        }

        if (pid == 0) {
            // 子进程
            try pty.runChild(shell);
        } else {
            // 父进程
            pty.pid = pid;
            // 关闭 slave 端
            if (pty.slave != -1) {
                _ = c.close(pty.slave);
            }
        }

        return pty;
    }

    /// 运行子进程
    fn runChild(self: *PTY, shell: ?[:0]const u8) !void {
        // 设置会话 ID
        _ = c.setsid();

        // 重定向 stdio 到 PTY
        if (self.slave == -1) return;
        _ = c.dup2(self.slave, c.STDIN_FILENO);
        _ = c.dup2(self.slave, c.STDOUT_FILENO);
        _ = c.dup2(self.slave, c.STDERR_FILENO);

        // 关闭不需要的文件描述符
        _ = c.close(self.slave);
        _ = c.close(self.master);

        // 设置终端类型
        if (std.posix.getenv("TERM")) |term| {
            _ = c.setenv("TERM", term, 1);
        }

        // 执行 shell
        const shell_path = shell orelse "/bin/sh";
        const argv = [_]?[*:0]const u8{ shell_path, null };

        _ = c.execvp(shell_path, @ptrCast(&argv));
        c.exit(1);
    }

    /// 读取数据
    pub fn read(self: *PTY, buffer: []u8) !usize {
        const n = c.read(self.master, buffer.ptr, buffer.len);
        if (n < 0) {
            return error.ReadFailed;
        }
        return @intCast(n);
    }

    /// 写入数据
    pub fn write(self: *PTY, data: []const u8) !usize {
        std.log.info("PTY write: {d} bytes: {any}", .{ data.len, data });
        var written: usize = 0;
        while (written < data.len) {
            const n = c.write(self.master, data[written..].ptr, data.len - written);
            if (n < 0) {
                return error.WriteFailed;
            }
            if (n == 0) {
                return error.WriteFailed;
            }
            written += @intCast(n);
        }
        return written;
    }

    /// 调整大小
    pub fn resize(self: *PTY, cols: usize, rows: usize) !void {
        var winsize: c.struct_winsize = .{
            .ws_col = @intCast(cols),
            .ws_row = @intCast(rows),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.ioctl(self.master, c.TIOCSWINSZ, &winsize) != 0) {
            return error.WriteFailed;
        }

        self.cols = cols;
        self.rows = rows;
    }

    /// 关闭
    pub fn close(self: *PTY) void {
        if (self.master != -1) {
            _ = c.close(self.master);
        }
        if (self.slave != -1) {
            _ = c.close(self.slave);
        }
        if (self.pid != 0) {
            // 发送 SIGHUP 给子进程
            _ = c.kill(self.pid, c.SIGHUP);
        }
    }

    /// 检查子进程状态
    pub fn wait(self: *PTY) !u8 {
        var status: i32 = undefined;
        const pid = c.waitpid(self.pid, &status, 0);
        if (pid < 0) {
            return 0;
        }

        if (c.WIFEXITED(status)) {
            return @intCast(c.WEXITSTATUS(status));
        } else if (c.WIFSIGNALED(status)) {
            const sig = c.WTERMSIG(status);
            return @intCast(sig);
        }

        return 1;
    }
};
