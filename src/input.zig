//! 键盘和鼠标输入处理
//!
//! 输入处理器负责将用户的键盘和鼠标输入转换为终端能够理解的格式，
//! 然后发送给 PTY（伪终端）。
//!
//! 核心功能：
//! - 键盘输入处理：将 KeyPress 事件转换为字符或转义序列
//! - 特殊键处理：方向键、功能键、编辑键（Backspace、Delete 等）
//! - 应用程序模式：根据 mode.app_cursor 和 mode.app_keypad 发送不同的转义序列
//! - 括号粘贴模式：处理特殊的粘贴序列（bracketed paste）
//! - 鼠标事件：发送鼠标报告到 PTY（如果启用了鼠标模式）
//!
//! 特殊键的处理流程：
//! 1. 检测特殊键（Backspace、Delete、方向键、PageUp/PageDown 等）
//! 2. 根据当前模式（普通模式/应用程序模式）选择对应的转义序列
//! 3. 将转义序列写入 PTY
//! 4. 返回 true（表示已处理，不需要输入法处理）
//!
//! 普通字符的处理流程：
//! 1. Xutf8LookupString 或 XLookupString 将 KeyPress 事件转换为 UTF-8 字符
//! 2. 将 UTF-8 字符写入 PTY
//! 3. 返回 false（表示已处理，不需要输入法处理）
//!
//! 应用程序模式 (Application Keypad/Cursor Mode)：
//! - 普通：方向键发送 ESC [ A/B/C/D
//! - 应用：方向键发送 ESC O A/B/C/D
//! - 用途：vim、htop 等 TUI 程序需要应用程序模式
//!
//! 括号粘贴模式 (Bracketed Paste Mode)：
//! - 启用时：粘贴内容被特殊字符包裹（\x1B[200~ 和 \x1B[201~）
//! - 用途：防止粘贴的内容被解释为命令
//! - 示例：粘贴 "Ctrl+C" 不会被解释为中断信号
//!
//! 与 PTY 的交互：
//! - pty.write(): 将字符或转义序列写入 PTY
//! - PTY 将数据转发给 shell 程序
//! - Shell 程序接收到输入，执行相应的命令

const std = @import("std");
const x11 = @import("x11.zig");
const PTY = @import("pty.zig").PTY;
const Terminal = @import("terminal.zig").Terminal;

pub const InputError = error{
    InvalidKey,
    BufferOverflow,
};

/// 输入处理器
pub const Input = struct {
    pty: *PTY,
    term: *Terminal,
    bracketed_paste_buffer: std.ArrayList(u8) = .empty,
    in_bracketed_paste: bool = false,

    /// 初始化输入处理器
    pub fn init(pty: *PTY, term: *Terminal) Input {
        return Input{
            .pty = pty,
            .term = term,
        };
    }

    /// 清理输入处理器
    pub fn deinit(self: *Input) void {
        self.bracketed_paste_buffer.deinit(self.pty.allocator);
    }

    /// 处理 bracketed paste 模式数据
    pub fn handleBracketedPaste(self: *Input, data: []const u8) bool {
        if (!self.term.mode.brckt_paste) {
            _ = self.pty.write(data) catch {};
            return true;
        }

        const start_seq = "\x1b[200~";
        const end_seq = "\x1b[201~";

        var i: usize = 0;
        while (i < data.len) {
            if (!self.in_bracketed_paste and i + 6 <= data.len and
                std.mem.eql(u8, data[i .. i + 6], start_seq))
            {
                self.in_bracketed_paste = true;
                i += 6;
                continue;
            }

            if (self.in_bracketed_paste and i + 6 <= data.len and
                std.mem.eql(u8, data[i .. i + 6], end_seq))
            {
                self.in_bracketed_paste = false;
                if (self.bracketed_paste_buffer.items.len > 0) {
                    _ = self.pty.write(self.bracketed_paste_buffer.items) catch {};
                    self.bracketed_paste_buffer.clearRetainingCapacity();
                }
                i += 6;
                continue;
            }

            if (self.in_bracketed_paste) {
                self.bracketed_paste_buffer.append(self.pty.allocator, data[i]) catch {};
            } else {
                _ = self.pty.write(data[i .. i + 1]) catch {};
            }
            i += 1;
        }
        return true;
    }

    /// 处理键盘事件
    /// 返回: true 表示按键已被特殊处理，false 表示应由输入法继续处理
    pub fn handleKey(self: *Input, event: *const x11.c.XKeyEvent) !bool {
        var keysym: x11.c.KeySym = 0;
        keysym = x11.c.XkbKeycodeToKeysym(event.display, @intCast(event.keycode), 0, if ((event.state & x11.c.ShiftMask) != 0) 1 else 0);

        const state = event.state;
        const ctrl = (state & x11.c.ControlMask) != 0;
        const alt = (state & x11.c.Mod1Mask) != 0;
        const shift = (state & x11.c.ShiftMask) != 0;

        // 如果是特殊功能键，拦截并处理
        if (try self.handleSpecialKey(keysym, ctrl, alt, shift)) {
            return true;
        }

        // 处理 Ctrl+字母 等组合键
        if (ctrl and keysym >= 32 and keysym <= 126) {
            try self.writePrintable(@intCast(keysym), alt, ctrl, shift);
            return true;
        }

        // 其他普通字符交给 XIM 处理
        return false;
    }

    fn handleSpecialKey(self: *Input, keysym: x11.c.KeySym, ctrl: bool, alt: bool, shift: bool) !bool {
        const XK_BackSpace = 0xFF08;
        const XK_Tab = 0xFF09;
        const XK_Return = 0xFF0D;
        const XK_Escape = 0xFF1B;
        const XK_Delete = 0xFFFF;
        const XK_Home = 0xFF50;
        const XK_Left = 0xFF51;
        const XK_Up = 0xFF52;
        const XK_Right = 0xFF53;
        const XK_Down = 0xFF54;
        const XK_Prior = 0xFF55;
        const XK_Next = 0xFF56;
        const XK_End = 0xFF57;
        const XK_Insert = 0xFF63;
        const XK_ISO_Left_Tab = 0xFE20;
        const XK_F1 = 0xFFBE;
        const XK_F12 = 0xFFC9;
        const XK_KP_Enter = 0xFF8D;
        const XK_KP_Home = 0xFF95;
        const XK_KP_Left = 0xFF96;
        const XK_KP_Up = 0xFF97;
        const XK_KP_Right = 0xFF98;
        const XK_KP_Down = 0xFF99;
        const XK_KP_Prior = 0xFF9A;
        const XK_KP_Next = 0xFF9B;
        const XK_KP_End = 0xFF9C;
        const XK_KP_Insert = 0xFF9E;
        const XK_KP_Delete = 0xFF9F;
        const XK_KP_Multiply = 0xFFAA;
        const XK_KP_Add = 0xFFAB;
        const XK_KP_Separator = 0xFFAC;
        const XK_KP_Subtract = 0xFFAD;
        const XK_KP_Decimal = 0xFFAE;
        const XK_KP_Divide = 0xFFAF;
        const XK_KP_0 = 0xFFB0;
        const XK_KP_9 = 0xFFB9;

        switch (keysym) {
            XK_Return => try self.writeReturn(alt),
            XK_KP_Enter => try self.writeReturn(alt),
            XK_Escape => try self.writeEsc(),
            XK_BackSpace => try self.writeBackspace(alt, ctrl, shift),
            XK_Tab => try self.writeTab(alt),
            XK_ISO_Left_Tab => try self.writeTab(alt),
            XK_Delete => try self.writeDelete(alt, ctrl),
            XK_KP_Delete => try self.writeDelete(alt, ctrl),
            XK_Up => try self.writeArrow(alt, 'A', ctrl, shift),
            XK_Down => try self.writeArrow(alt, 'B', ctrl, shift),
            XK_Left => try self.writeArrow(alt, 'D', ctrl, shift),
            XK_Right => try self.writeArrow(alt, 'C', ctrl, shift),
            XK_KP_Up => try self.writeArrow(alt, 'A', ctrl, shift),
            XK_KP_Down => try self.writeArrow(alt, 'B', ctrl, shift),
            XK_KP_Left => try self.writeArrow(alt, 'D', ctrl, shift),
            XK_KP_Right => try self.writeArrow(alt, 'C', ctrl, shift),
            XK_Home => try self.writeHome(alt, ctrl),
            XK_KP_Home => try self.writeHome(alt, ctrl),
            XK_End => try self.writeEnd(alt, ctrl),
            XK_KP_End => try self.writeEnd(alt, ctrl),
            XK_Prior => try self.writePageUp(alt, ctrl),
            XK_KP_Prior => try self.writePageUp(alt, ctrl),
            XK_Next => try self.writePageDown(alt, ctrl),
            XK_KP_Next => try self.writePageDown(alt, ctrl),
            XK_Insert => {},
            XK_KP_Insert => {},
            else => {
                if (keysym >= XK_F1 and keysym <= XK_F12) {
                    try self.writeFunction(@intCast(keysym - XK_F1 + 1), shift, ctrl, alt);
                    return true;
                }
                if (keysym >= XK_KP_0 and keysym <= XK_KP_9) {
                    return try self.writeKeypad(keysym, shift, ctrl, alt);
                }
                if (keysym == XK_KP_Add or keysym == XK_KP_Subtract or keysym == XK_KP_Multiply or
                    keysym == XK_KP_Divide or keysym == XK_KP_Decimal or keysym == XK_KP_Separator)
                {
                    return try self.writeKeypad(keysym, shift, ctrl, alt);
                }

                // 忽略普通 ASCII 字符和修饰键的日志，避免刷屏
                if (keysym < 0x80 or (keysym >= 0xFFE1 and keysym <= 0xFFEE)) {
                    return false;
                }

                std.log.debug("未处理的特殊按键: 0x{x}", .{keysym});
                return false;
            },
        }
        return true;
    }

    fn writeKeypad(self: *Input, keysym: x11.c.KeySym, shift: bool, ctrl: bool, alt: bool) !bool {
        if (self.term.mode.app_keypad) {
            const XK_KP_0 = 0xFFB0;
            const XK_KP_Multiply = 0xFFAA;
            const XK_KP_Add = 0xFFAB;
            const XK_KP_Separator = 0xFFAC;
            const XK_KP_Subtract = 0xFFAD;
            const XK_KP_Decimal = 0xFFAE;
            const XK_KP_Divide = 0xFFAF;

            var c: u8 = 0;
            if (keysym >= XK_KP_0 and keysym <= 0xFFB9) {
                c = 'p' + @as(u8, @intCast(keysym - XK_KP_0));
            } else if (keysym == XK_KP_Multiply) {
                c = 'j';
            } else if (keysym == XK_KP_Add) {
                c = 'k';
            } else if (keysym == XK_KP_Separator) {
                c = 'l';
            } else if (keysym == XK_KP_Subtract) {
                c = 'm';
            } else if (keysym == XK_KP_Decimal) {
                c = 'n';
            } else if (keysym == XK_KP_Divide) {
                c = 'o';
            } else {
                std.log.debug("未处理的 keypad 键 (AppKeypad): 0x{x}", .{keysym});
                return false;
            }
            var seq: [3]u8 = undefined;
            const s = try std.fmt.bufPrint(&seq, "\x1BO{c}", .{c});
            _ = try self.pty.write(s);
            return true;
        } else {
            const XK_KP_0 = 0xFFB0;
            var char: u8 = 0;
            if (keysym >= XK_KP_0 and keysym <= 0xFFB9) {
                char = '0' + @as(u8, @intCast(keysym - XK_KP_0));
            } else if (keysym == 0xFFAA) {
                char = '*';
            } else if (keysym == 0xFFAB) {
                char = '+';
            } else if (keysym == 0xFFAC) {
                char = ',';
            } else if (keysym == 0xFFAD) {
                char = '-';
            } else if (keysym == 0xFFAE) {
                char = '.';
            } else if (keysym == 0xFFAF) {
                char = '/';
            } else {
                std.log.debug("未处理的 keypad 键 (Normal): 0x{x}", .{keysym});
                return false;
            }
            try self.writePrintable(char, alt, ctrl, shift);
            return true;
        }
    }

    pub fn sendMouseReport(self: *Input, x: usize, y: usize, button: u32, state: u32, event_type: u8) !void {
        if (!self.term.mode.isMouseEnabled()) return;
        var code: u32 = 0;
        if (event_type == 2) {
            if (!self.term.mode.mouse_many and !self.term.mode.mouse_btn) return;
            code = 32;
            if (button >= 1 and button <= 3) {
                code += button - 1;
            } else {
                code += 3;
            }
        } else if (event_type == 1) {
            if (button == 4 or button == 5) return;
            code = 3;
        } else {
            if (button >= 4) {
                code = 64 + (button - 4);
            } else {
                code = button - 1;
            }
        }
        if (self.term.mode.mouse_sgr or (x < 223 and y < 223)) {
            if ((state & x11.c.ShiftMask) != 0) code += 4;
            if ((state & x11.c.Mod1Mask) != 0) code += 8;
            if ((state & x11.c.ControlMask) != 0) code += 16;
        }
        if (self.term.mode.mouse_sgr) {
            const ch: u8 = if (event_type == 1) 'm' else 'M';
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ code, x + 1, y + 1, ch });
            _ = try self.pty.write(s);
        } else if (x < 223 and y < 223) {
            var buf: [6]u8 = undefined;
            buf[0] = 0x1b;
            buf[1] = '[';
            buf[2] = 'M';
            buf[3] = @as(u8, @intCast(32 + code));
            buf[4] = @as(u8, @intCast(32 + x + 1));
            buf[5] = @as(u8, @intCast(32 + y + 1));
            _ = try self.pty.write(&buf);
        }
    }

    fn writeEsc(self: *Input) !void {
        _ = try self.pty.write("\x1B");
    }

    fn writeReturn(self: *Input, alt: bool) !void {
        const seq = if (alt) "\x1BO\r" else "\r";
        _ = try self.pty.write(seq);
    }

    fn writeTab(self: *Input, alt: bool) !void {
        const seq = if (alt) "\x1BO[Z" else "\t";
        _ = try self.pty.write(seq);
    }

    fn writeBackspace(self: *Input, alt: bool, ctrl: bool, shift: bool) !void {
        if (shift) {
            _ = try self.pty.write("\x08"); // Shift+BS 常用作回退一个字符并删除
        } else if (alt) {
            _ = try self.pty.write("\x1B\x7F"); // Alt+BS 删除单词
        } else if (ctrl) {
            _ = try self.pty.write("\x1B[3;5~"); // Ctrl+BS 发送特定的删除序列，避免与 Ctrl-H (\x08) 冲突
        } else {
            _ = try self.pty.write("\x7F"); // 默认 Backspace 发送 DEL
        }
    }

    fn writeDelete(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[3~" else if (ctrl) "\x1B[3;5~" else "\x1B[3~";
        _ = try self.pty.write(seq);
    }

    pub fn writeArrow(self: *Input, alt: bool, direction: u8, ctrl: bool, shift: bool) !void {
        var seq: []const u8 = "";
        if (ctrl) {
            seq = switch (direction) {
                'A' => "\x1B[1;5A",
                'B' => "\x1B[1;5B",
                'C' => "\x1B[1;5C",
                'D' => "\x1B[1;5D",
                else => {
                    std.log.debug("未知的方向键 (Ctrl): {c}", .{direction});
                    return;
                },
            };
        } else if (shift) {
            seq = switch (direction) {
                'A' => "\x1B[1;2A",
                'B' => "\x1B[1;2B",
                'C' => "\x1B[1;2C",
                'D' => "\x1B[1;2D",
                else => {
                    std.log.debug("未知的方向键 (Shift): {c}", .{direction});
                    return;
                },
            };
        } else if (alt) {
            seq = switch (direction) {
                'A' => "\x1B[1;3A",
                'B' => "\x1B[1;3B",
                'C' => "\x1B[1;3C",
                'D' => "\x1B[1;3D",
                else => {
                    std.log.debug("未知的方向键 (Alt): {c}", .{direction});
                    return;
                },
            };
        } else {
            if (self.term.mode.app_cursor) {
                seq = switch (direction) {
                    'A' => "\x1BOA",
                    'B' => "\x1BOB",
                    'C' => "\x1BOC",
                    'D' => "\x1BOD",
                    else => {
                        std.log.debug("未知的方向键 (AppCursor): {c}", .{direction});
                        return;
                    },
                };
            } else {
                seq = switch (direction) {
                    'A' => "\x1B[A",
                    'B' => "\x1B[B",
                    'C' => "\x1B[C",
                    'D' => "\x1B[D",
                    else => {
                        std.log.debug("未知的方向键 (Default): {c}", .{direction});
                        return;
                    },
                };
            }
        }
        _ = try self.pty.write(seq);
    }

    fn writeHome(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[1;3H" else if (ctrl) "\x1B[1;5H" else "\x1B[H";
        _ = try self.pty.write(seq);
    }

    fn writeEnd(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[1;3F" else if (ctrl) "\x1B[1;5F" else "\x1B[F";
        _ = try self.pty.write(seq);
    }

    fn writePageUp(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[5;3~" else if (ctrl) "\x1B[5;5~" else "\x1B[5~";
        _ = try self.pty.write(seq);
    }

    fn writePageDown(self: *Input, alt: bool, ctrl: bool) !void {
        const seq = if (alt) "\x1B[6;3~" else if (ctrl) "\x1B[6;5~" else "\x1B[6~";
        _ = try self.pty.write(seq);
    }

    fn writeFunction(self: *Input, fn_num: u32, shift: bool, ctrl: bool, alt: bool) !void {
        if (fn_num < 1 or fn_num > 12) return;
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
            else => {
                std.log.debug("未知的 Fn 键: {d}", .{fn_num});
                return;
            },
        };
        var seq: [32]u8 = undefined;
        const formatted_seq = if (shift or alt or ctrl)
            try std.fmt.bufPrint(&seq, "\x1B[{d}{s}", .{ @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4, base_seq })
        else
            try std.fmt.bufPrint(&seq, "\x1BO{s}", .{base_seq});
        _ = try self.pty.write(formatted_seq);
    }

    fn writePrintable(self: *Input, c: u8, alt: bool, ctrl: bool, shift: bool) !void {
        _ = shift;
        var char = c;
        if (ctrl) {
            char &= 0x1F;
        }
        if (alt) {
            const seq = [_]u8{ 0x1B, char };
            _ = try self.pty.write(&seq);
        } else {
            const seq = [_]u8{char};
            _ = try self.pty.write(&seq);
        }
    }
};
