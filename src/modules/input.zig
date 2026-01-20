//! 键盘和鼠标输入处理
//! 将 SDL2 输入事件转换为终端转义序列

const std = @import("std");
const x11 = @import("x11.zig");
const PTY = @import("pty.zig").PTY;

pub const InputError = error{
    InvalidKey,
    BufferOverflow,
};

/// 输入处理器
pub const Input = struct {
    pty: *PTY,
    mode: struct {
        app_cursor: bool = false,
        app_keypad: bool = false,
        crlf: bool = false,
    } = .{},

    /// 初始化输入处理器
    pub fn init(pty: *PTY) Input {
        return Input{
            .pty = pty,
        };
    }

    /// 处理键盘事件
    pub fn handleKey(self: *Input, event: *const x11.C.XKeyEvent) !void {
        var keysym: x11.KeySym = 0;

        keysym = x11.C.XkbKeycodeToKeysym(event.display, @intCast(event.keycode), 0, if ((event.state & x11.C.ShiftMask) != 0) 1 else 0);

        const state = event.state;
        const ctrl = (state & x11.C.ControlMask) != 0;
        const alt = (state & x11.C.Mod1Mask) != 0; // Usually Alt
        const shift = (state & x11.C.ShiftMask) != 0;

        // Log input for debugging
        std.log.info("handleKey: keycode={d}, keysym={d}, state={d}", .{ event.keycode, keysym, state });

        // Handle special keys
        if (self.handleSpecialKey(keysym, ctrl, alt, shift)) |seq| {
            _ = try self.pty.write(seq);
            return;
        }

        // Handle normal characters
        if (keysym >= 32 and keysym <= 126) {
            try self.writePrintable(@intCast(keysym), alt, ctrl, shift);
        }
    }

    fn handleSpecialKey(self: *Input, keysym: x11.KeySym, ctrl: bool, alt: bool, shift: bool) ?[]const u8 {
        _ = self;
        _ = ctrl;
        _ = alt;
        _ = shift;
        // Map X11 KeySyms to sequences
        // TODO: Complete this mapping using X11 keysymdefs
        // For now, minimal set
        const XK_Return = 0xFF0D;
        const XK_Escape = 0xFF1B;
        const XK_BackSpace = 0xFF08;
        const XK_Tab = 0xFF09;
        const XK_Up = 0xFF52;
        const XK_Down = 0xFF54;
        const XK_Left = 0xFF51;
        const XK_Right = 0xFF53;

        if (keysym == XK_Return) return "\r";
        if (keysym == XK_Escape) return "\x1B";
        if (keysym == XK_BackSpace) return "\x7F";
        if (keysym == XK_Tab) return "\t";
        if (keysym == XK_Up) return "\x1B[A";
        if (keysym == XK_Down) return "\x1B[B";
        if (keysym == XK_Left) return "\x1B[D";
        if (keysym == XK_Right) return "\x1B[C";

        return null;
    }

    /// 处理鼠标事件
    pub fn handleMouse(self: *Input, event: *const anyopaque) !void {
        // TODO: 实现鼠标报告
        _ = self;
        _ = event;
    }

    /// 写入 ESC 字符
    fn writeEsc(self: *Input) !void {
        const seq = "\x1B";
        _ = try self.pty.write(seq);
    }

    /// 写入回车
    fn writeReturn(self: *Input, alt: bool) !void {
        const seq = if (alt) "\x1BO\r" else "\r";
        _ = try self.pty.write(seq);
    }

    /// 写入制表符
    fn writeTab(self: *Input, alt: bool) !void {
        const seq = if (alt) "\x1BO[Z" else "\t";
        _ = try self.pty.write(seq);
    }

    /// 写入退格
    fn writeBackspace(self: *Input, alt: bool, ctrl: bool) !void {
        if (ctrl and !alt) {
            _ = try self.pty.write("\x08"); // Ctrl+H
        } else {
            _ = try self.pty.write("\x7F"); // DEL
        }
    }

    /// 写入删除
    fn writeDelete(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[3~" else if (ctrl) "\x1B[3;5~" else "\x1B[3~";
        _ = try self.pty.write(seq);
    }

    /// 写入箭头键
    fn writeArrow(self: *Input, alt: bool, direction: u8, ctrl: bool, shift: bool) !void {
        var seq: []const u8 = "";

        if (ctrl) {
            seq = switch (direction) {
                'A' => "\x1B[1;5A", // Ctrl+Up
                'B' => "\x1B[1;5B", // Ctrl+Down
                'C' => "\x1B[1;5C", // Ctrl+Right
                'D' => "\x1B[1;5D", // Ctrl+Left
                else => return,
            };
        } else if (shift) {
            seq = switch (direction) {
                'A' => "\x1B[1;2A", // Shift+Up
                'B' => "\x1B[1;2B", // Shift+Down
                'C' => "\x1B[1;2C", // Shift+Right
                'D' => "\x1B[1;2D", // Shift+Left
                else => return,
            };
        } else if (alt) {
            seq = switch (direction) {
                'A' => "\x1B[1;3A", // Alt+Up
                'B' => "\x1B[1;3B", // Alt+Down
                'C' => "\x1B[1;3C", // Alt+Right
                'D' => "\x1B[1;3D", // Alt+Left
                else => return,
            };
        } else {
            seq = switch (direction) {
                'A' => "\x1B[A", // Up
                'B' => "\x1B[B", // Down
                'C' => "\x1B[C", // Right
                'D' => "\x1B[D", // Left
                else => return,
            };
        }

        _ = try self.pty.write(seq);
    }

    /// 写入 Home 键
    fn writeHome(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[1;3H" else if (ctrl) "\x1B[1;5H" else "\x1B[H";
        _ = try self.pty.write(seq);
    }

    /// 写入 End 键
    fn writeEnd(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[1;3F" else if (ctrl) "\x1B[1;5F" else "\x1B[F";
        _ = try self.pty.write(seq);
    }

    /// 写入 PageUp 键
    fn writePageUp(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[5;3~" else if (ctrl) "\x1B[5;5~" else "\x1B[5~";
        _ = try self.pty.write(seq);
    }

    /// 写入 PageDown 键
    fn writePageDown(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[6;3~" else if (ctrl) "\x1B[6;5~" else "\x1B[6~";
        _ = try self.pty.write(seq);
    }

    /// 写入功能键
    fn writeFunction(self: *Input, fn_num: u32, shift: bool, ctrl: bool, alt: bool) !void {
        if (fn_num < 1 or fn_num > 12) return;

        var modifiers: u32 = 0;
        if (shift) modifiers += 1;
        if (alt) modifiers += 2;
        if (ctrl) modifiers += 4;

        const base_seq = switch (fn_num) {
            1 => "OP",
            2 => "OQ",
            3 => "OR",
            4 => "OS",
            5 => "[15~",
            6 => "[17~",
            7 => "[18~",
            8 => "[19~",
            9 => "[20~",
            10 => "[21~",
            11 => "[23~",
            12 => "[24~",
            else => return,
        };

        // 应用修饰符
        var seq: [32]u8 = undefined;
        const formatted_seq = if (modifiers > 0)
            try std.fmt.bufPrint(&seq, "\x1B[{d}{s}", .{ modifiers, base_seq })
        else
            try std.fmt.bufPrint(&seq, "\x1BO{s}", .{base_seq});

        _ = try self.pty.write(formatted_seq);
    }

    /// 写入可打印字符
    fn writePrintable(self: *Input, c: u8, alt: bool, ctrl: bool, shift: bool) !void {
        _ = shift;
        std.log.info("writePrintable: char='{c}' ({d}), alt={any}, ctrl={any}", .{ c, c, alt, ctrl });
        if (ctrl) {
            // Ctrl + 字符
            const ctrl_char = c & 0x1F; // 只使用低5位
            const seq = [_]u8{ctrl_char};
            _ = try self.pty.write(&seq);
        } else if (alt) {
            // Alt + 字符
            const seq = [_]u8{ 0x1B, c };
            _ = try self.pty.write(&seq);
        } else {
            // 普通字符
            const seq = [_]u8{c};
            _ = try self.pty.write(&seq);
        }
    }
};
