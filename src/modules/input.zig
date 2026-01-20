//! 键盘和鼠标输入处理

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
    term: *const @import("types.zig").Term,
    bracketed_paste_buffer: std.ArrayList(u8) = .empty,
    in_bracketed_paste: bool = false,

    /// 初始化输入处理器
    pub fn init(pty: *PTY, term: *const @import("types.zig").Term) Input {
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
    /// 返回: true 表示数据已处理，false 表示数据保留在缓冲区中
    pub fn handleBracketedPaste(self: *Input, data: []const u8) bool {
        if (!self.term.mode.brckt_paste) {
            // 不在 bracketed paste 模式下，直接写入 PTY
            _ = self.pty.write(data) catch {};
            return true;
        }

        const start_seq = "\x1b[200~";
        const end_seq = "\x1b[201~";

        var i: usize = 0;
        while (i < data.len) {
            // 检查是否是开始序列
            if (!self.in_bracketed_paste and i + 6 <= data.len and
                std.mem.eql(u8, data[i .. i + 6], start_seq))
            {
                self.in_bracketed_paste = true;
                i += 6;
                continue;
            }

            // 检查是否是结束序列
            if (self.in_bracketed_paste and i + 6 <= data.len and
                std.mem.eql(u8, data[i .. i + 6], end_seq))
            {
                self.in_bracketed_paste = false;

                // 写入缓冲的内容到 PTY
                if (self.bracketed_paste_buffer.items.len > 0) {
                    _ = self.pty.write(self.bracketed_paste_buffer.items) catch {};
                    self.bracketed_paste_buffer.clearRetainingCapacity();
                }

                i += 6;
                continue;
            }

            // 如果在 bracketed paste 模式下，缓冲数据
            if (self.in_bracketed_paste) {
                self.bracketed_paste_buffer.append(self.pty.allocator, data[i]) catch {};
            } else {
                // 不在 bracketed paste 模式下，直接写入 PTY
                _ = self.pty.write(data[i .. i + 1]) catch {};
            }

            i += 1;
        }

        return true;
    }

    /// 处理键盘事件
    pub fn handleKey(self: *Input, event: *const x11.C.XKeyEvent) !void {
        var keysym: x11.KeySym = 0;

        // 获取 KeySym (不处理控制键，只处理 Shift)
        keysym = x11.C.XkbKeycodeToKeysym(event.display, @intCast(event.keycode), 0, if ((event.state & x11.C.ShiftMask) != 0) 1 else 0);

        const state = event.state;
        const ctrl = (state & x11.C.ControlMask) != 0;
        const alt = (state & x11.C.Mod1Mask) != 0;
        const shift = (state & x11.C.ShiftMask) != 0;

        // Log input for debugging
        // std.log.info("handleKey: keycode={d}, keysym=0x{x}, state={d}, ctrl={}, alt={}, shift={}", .{ event.keycode, keysym, state, ctrl, alt, shift });

        // Handle special keys first (Arrows, F-keys, Home/End, etc.)
        if (try self.handleSpecialKey(keysym, ctrl, alt, shift)) {
            return;
        }

        // Handle normal characters
        // Control keys (Ctrl+A..Z, etc) are handled here if not special
        if (keysym >= 32 and keysym <= 126) {
            try self.writePrintable(@intCast(keysym), alt, ctrl, shift);
        } else if (keysym >= 0xA0 and keysym <= 0xFF) {
            // Latin-1 supplement
            try self.writePrintable(@intCast(keysym), alt, ctrl, shift);
        }
        // TODO: Handle UTF-8 input for other keysyms
    }

    fn handleSpecialKey(self: *Input, keysym: x11.KeySym, ctrl: bool, alt: bool, shift: bool) !bool {
        // X11 KeySym definitions
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
        const XK_Prior = 0xFF55; // PageUp
        const XK_Next = 0xFF56; // PageDown
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
            XK_KP_Enter => try self.writeReturn(alt), // Handle KP Enter like Return
            XK_Escape => try self.writeEsc(),
            XK_BackSpace => try self.writeBackspace(alt, ctrl),
            XK_Tab => try self.writeTab(alt),
            XK_ISO_Left_Tab => try self.writeTab(alt), // Shift+Tab usually produces this
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
            XK_Insert => { // TODO: Insert key
            },
            XK_KP_Insert => { // TODO: Insert key
            },
            else => {
                if (keysym >= XK_F1 and keysym <= XK_F12) {
                    try self.writeFunction(@intCast(keysym - XK_F1 + 1), shift, ctrl, alt);
                    return true;
                }

                // Keypad Number handling
                if (keysym >= XK_KP_0 and keysym <= XK_KP_9) {
                    return try self.writeKeypad(keysym, shift, ctrl, alt);
                }
                // Keypad Operators
                if (keysym == XK_KP_Add or keysym == XK_KP_Subtract or keysym == XK_KP_Multiply or
                    keysym == XK_KP_Divide or keysym == XK_KP_Decimal or keysym == XK_KP_Separator)
                {
                    return try self.writeKeypad(keysym, shift, ctrl, alt);
                }

                return false;
            },
        }
        return true;
    }

    /// Write Keypad sequence
    fn writeKeypad(self: *Input, keysym: x11.KeySym, shift: bool, ctrl: bool, alt: bool) !bool {
        // If Application Keypad Mode is ON
        if (self.term.mode.app_keypad) {
            const XK_KP_0 = 0xFFB0;
            const XK_KP_9 = 0xFFB9;
            const XK_KP_Multiply = 0xFFAA;
            const XK_KP_Add = 0xFFAB;
            const XK_KP_Separator = 0xFFAC;
            const XK_KP_Subtract = 0xFFAD;
            const XK_KP_Decimal = 0xFFAE;
            const XK_KP_Divide = 0xFFAF;

            var c: u8 = 0;
            if (keysym >= XK_KP_0 and keysym <= XK_KP_9) {
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
                return false;
            }

            var seq: [3]u8 = undefined;
            const s = try std.fmt.bufPrint(&seq, "\x1BO{c}", .{c});
            _ = try self.pty.write(s);
            return true;
        } else {
            // Numeric Mode: Let it fall through to printable characters?
            // Usually, these keysyms (XK_KP_0 etc) are NOT in the ASCII range (0xFFB0).
            // We need to map them to their ASCII equivalents manually if we want them to print numbers.
            const XK_KP_0 = 0xFFB0;
            const XK_KP_9 = 0xFFB9;
            const XK_KP_Multiply = 0xFFAA;
            const XK_KP_Add = 0xFFAB;
            const XK_KP_Separator = 0xFFAC;
            const XK_KP_Subtract = 0xFFAD;
            const XK_KP_Decimal = 0xFFAE;
            const XK_KP_Divide = 0xFFAF;

            var char: u8 = 0;
            if (keysym >= XK_KP_0 and keysym <= XK_KP_9) {
                char = '0' + @as(u8, @intCast(keysym - XK_KP_0));
            } else if (keysym == XK_KP_Multiply) {
                char = '*';
            } else if (keysym == XK_KP_Add) {
                char = '+';
            } else if (keysym == XK_KP_Separator) {
                char = ',';
            } else if (keysym == XK_KP_Subtract) {
                char = '-';
            } else if (keysym == XK_KP_Decimal) {
                char = '.';
            } else if (keysym == XK_KP_Divide) {
                char = '/';
            } else {
                return false;
            }
            try self.writePrintable(char, alt, ctrl, shift);
            return true;
        }
    }

    /// 处理鼠标事件
    pub fn handleMouse(self: *Input, event: *const x11.C.XButtonEvent) !void {
        _ = self;
        _ = event;
    }

    /// 发送鼠标报告
    /// x, y: 终端坐标 (0-indexed)
    /// button: 按钮编号 (1-11)
    /// state: 修饰符状态
    /// release: 是否是释放事件
    pub fn sendMouseReport(self: *Input, x: usize, y: usize, button: u32, state: u32, release: bool) !void {
        // 检查是否启用了鼠标报告
        if (!self.term.mode.mouse) return;

        var code: u32 = 0;

        // 按钮编码
        if (release) {
            // MODE_MOUSEX10: 不发送按钮释放 (st does this via mouse_x10 check)
            // Note: self.term.mode doesn't have mouse_x10, it usually maps to certain bits
            // In stz TermMode, we have mouse, mouse_btn, mouse_motion, etc.

            // 不发送滚轮的释放事件
            if (button == 4 or button == 5) return;

            code += 3; // 按钮释放时加 3
        } else {
            // ...
        }

        // 添加修饰符
        if (self.term.mode.mouse_sgr or !self.term.mode.mouse) { // Simplified check
            if ((state & x11.C.ShiftMask) != 0) code += 4;
            if ((state & x11.C.Mod1Mask) != 0) code += 8; // Alt
            if ((state & x11.C.ControlMask) != 0) code += 16;
        }

        // 生成报告
        if (self.term.mode.mouse_sgr) {
            // SGR 格式: ESC[<code;x+1;y+1M/m
            const ch: u8 = if (release) 'm' else 'M';
            const s = std.fmt.allocPrint(
                std.heap.page_allocator,
                "\x1b[<{d};{d};{d}{c}",
                .{ code, x + 1, y + 1, ch },
            ) catch return;
            defer std.heap.page_allocator.free(s);
            _ = try self.pty.write(s);
        } else if (x < 223 and y < 223) {
            // URXVT 格式: ESC[M<code+32><x+1+32><y+1+32>
            const s = std.fmt.allocPrint(
                std.heap.page_allocator,
                "\x1b[M{c}{c}{c}",
                .{
                    @as(u8, @intCast(32 + code)),
                    @as(u8, @intCast(32 + x + 1)),
                    @as(u8, @intCast(32 + y + 1)),
                },
            ) catch return;
            defer std.heap.page_allocator.free(s);
            _ = try self.pty.write(s);
        } else {
            return; // 坐标超出范围
        }
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
            if (self.term.mode.app_cursor) {
                seq = switch (direction) {
                    'A' => "\x1BOA", // Up
                    'B' => "\x1BOB", // Down
                    'C' => "\x1BOC", // Right
                    'D' => "\x1BOD", // Left
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
        const formatted_seq = if (shift or alt or ctrl)
            try std.fmt.bufPrint(&seq, "\x1B[{d}{s}", .{ @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4, base_seq })
        else
            try std.fmt.bufPrint(&seq, "\x1BO{s}", .{base_seq});

        _ = try self.pty.write(formatted_seq);
    }

    /// 写入可打印字符
    fn writePrintable(self: *Input, c: u8, alt: bool, ctrl: bool, shift: bool) !void {
        _ = shift;
        // std.log.info("writePrintable: char='{c}' ({d}), alt={any}, ctrl={any}", .{ c, c, alt, ctrl });
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
