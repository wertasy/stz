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
    @cInclude("fcntl.h");
    @cInclude("pwd.h");
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
        const sid = c.setsid();
        if (sid < 0) return error.ForkFailed;

        // 重定向 stdio 到 PTY
        if (self.slave == -1) return;

        // 获取控制终端
        if (c.ioctl(self.slave, c.TIOCSCTTY, @as(c_int, 0)) < 0) {
            // 这通常不致命，但值得注意
            // std.log.warn("ioctl TIOCSCTTY failed\n", .{});
        }

        _ = c.dup2(self.slave, c.STDIN_FILENO);
        _ = c.dup2(self.slave, c.STDOUT_FILENO);
        _ = c.dup2(self.slave, c.STDERR_FILENO);

        // 关闭不需要的文件描述符
        _ = c.close(self.slave);
        _ = c.close(self.master);

        // 重置信号处理
        _ = c.signal(c.SIGCHLD, c.SIG_DFL);
        _ = c.signal(c.SIGHUP, c.SIG_DFL);
        _ = c.signal(c.SIGINT, c.SIG_DFL);
        _ = c.signal(c.SIGQUIT, c.SIG_DFL);
        _ = c.signal(c.SIGTERM, c.SIG_DFL);
        _ = c.signal(c.SIGALRM, c.SIG_DFL);

        // 设置环境变量
        const pw = c.getpwuid(c.getuid());
        if (pw != null) {
            _ = c.setenv("LOGNAME", pw.*.pw_name, 1);
            _ = c.setenv("USER", pw.*.pw_name, 1);
            _ = c.setenv("HOME", pw.*.pw_dir, 1);
            if (shell == null) {
                // 如果未指定 shell，使用 passwd 中的 shell
                _ = c.setenv("SHELL", pw.*.pw_shell, 1);
            }
        }

        // 设置 TERM (如果还没设置)
        _ = c.setenv("TERM", "xterm-256color", 0);

        // 执行 shell
        var shell_path: [:0]const u8 = "/bin/sh";
        if (shell) |s| {
            shell_path = s;
        } else if (pw != null and pw.*.pw_shell != null) {
            shell_path = std.mem.span(pw.*.pw_shell);
        }

        // 准备参数
        const argv = [_]?[*:0]const u8{ shell_path, null };

        _ = c.execvp(shell_path, @ptrCast(&argv));

        // 如果 execvp 失败
        std.log.err("execvp failed for {s}: {d}\n", .{ shell_path, std.posix.errno(0) });
        c.exit(1);
    }

    /// 读取数据
    pub fn read(self: *PTY, buffer: []u8) !usize {
        return std.posix.read(self.master, buffer);
    }

    /// 写入数据
    pub fn write(self: *PTY, data: []const u8) !usize {
        // std.log.info("PTY write: {d} bytes: {any}", .{ data.len, data });
        return std.posix.write(self.master, data);
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

    /// 设置为非阻塞模式
    pub fn setNonBlocking(self: *PTY) !void {
        const flags = c.fcntl(self.master, c.F_GETFL, @as(c_int, 0));
        if (flags < 0) return error.OpenFailed;
        if (c.fcntl(self.master, c.F_SETFL, flags | c.O_NONBLOCK) < 0) {
            return error.OpenFailed;
        }
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

    /// 检查子进程是否还活着（非阻塞）
    /// 返回: true 表示子进程还在运行，false 表示子进程已退出
    pub fn isChildAlive(self: *const PTY) bool {
        var status: i32 = undefined;
        // WNOHANG: 非阻塞，如果没有子进程退出，立即返回 0
        const pid = c.waitpid(self.pid, &status, c.WNOHANG);
        if (pid < 0) {
            // waitpid 失败，可能进程已经不存在了
            return false;
        }
        if (pid == 0) {
            // 子进程还在运行
            return true;
        }
        // pid > 0 表示子进程已退出
        return false;
    }
};
