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
//! 4. 返回 true（表示已处理）
//!
//! 普通字符的处理流程：
//! 1. 从 SDL2 键盘事件获取按键码和修饰键状态
//! 2. 将按键码转换为字符并写入 PTY
//! 3. 返回 true（表示已处理）
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
const stz = @import("stz");

const sdl2 = stz.c.sdl2;
const PTY = stz.PTY;
const Terminal = stz.Terminal;

pub const InputError = error{
    InvalidKey,
    BufferOverflow,
};

/// 输入处理器
pub const Input = @This();
pty: *PTY,
term: *Terminal,

/// 初始化输入处理器
pub fn init(pty: *PTY, term: *Terminal) Input {
    return Input{
        .pty = pty,
        .term = term,
    };
}

/// 清理输入处理器
pub fn deinit(self: *Input) void {
    _ = self;
}

/// 发送粘贴内容到 PTY，支持括号粘贴模式
pub fn sendPaste(self: *Input, text: []const u8) !void {
    if (self.term.mode.brckt_paste) {
        _ = try self.pty.write("\x1b[200~");
    }

    // 将 \n 转换为 \r 以适应终端输入
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            if (i > start) {
                _ = try self.pty.write(text[start..i]);
            }
            _ = try self.pty.write("\r");
            start = i + 1;
        }
    }
    if (i > start) {
        _ = try self.pty.write(text[start..i]);
    }

    if (self.term.mode.brckt_paste) {
        _ = try self.pty.write("\x1b[201~");
    }
}

/// 处理键盘事件
/// 参数:
///   keycode: SDL2 按键码 (SDL_Keycode)
///   mod: 修饰键状态 (KMOD_SHIFT, KMOD_CTRL, KMOD_ALT 等)
/// 返回: true 表示按键已被处理
pub fn handleKey(self: *Input, keycode: i32, mod: u16) !bool {
    const ctrl = (mod & sdl2.KMOD_CTRL) != 0;
    const alt = (mod & sdl2.KMOD_ALT) != 0;
    const shift = (mod & sdl2.KMOD_SHIFT) != 0;

    // 如果是特殊功能键，拦截并处理
    if (try self.handleSpecialKey(keycode, ctrl, alt, shift)) {
        return true;
    }

    // 处理 Ctrl+字母 或 Alt+字母 等组合键
    if ((ctrl or alt) and keycode >= 32 and keycode <= 126) {
        try self.writePrintable(@intCast(keycode), alt, ctrl, shift);
        return true;
    }

    return false;
}

fn handleSpecialKey(self: *Input, keycode: i32, ctrl: bool, alt: bool, shift: bool) !bool {
    switch (keycode) {
        sdl2.SDLK_RETURN, sdl2.SDLK_KP_ENTER => try self.writeReturn(alt),
        sdl2.SDLK_ESCAPE => try self.writeEsc(),
        sdl2.SDLK_BACKSPACE => try self.writeBackspace(alt, ctrl, shift),
        sdl2.SDLK_TAB => try self.writeTab(alt),
        sdl2.SDLK_DELETE => try self.writeDelete(alt, ctrl),
        sdl2.SDLK_UP => try self.writeArrow(alt, 'A', ctrl, shift),
        sdl2.SDLK_DOWN => try self.writeArrow(alt, 'B', ctrl, shift),
        sdl2.SDLK_LEFT => try self.writeArrow(alt, 'D', ctrl, shift),
        sdl2.SDLK_RIGHT => try self.writeArrow(alt, 'C', ctrl, shift),
        sdl2.SDLK_HOME => try self.writeHome(alt, ctrl, shift),
        sdl2.SDLK_END => try self.writeEnd(alt, ctrl, shift),
        sdl2.SDLK_PAGEUP => try self.writePageUp(alt, ctrl, shift),
        sdl2.SDLK_PAGEDOWN => try self.writePageDown(alt, ctrl, shift),
        sdl2.SDLK_INSERT => {},
        sdl2.SDLK_F1, sdl2.SDLK_F2, sdl2.SDLK_F3, sdl2.SDLK_F4, sdl2.SDLK_F5, sdl2.SDLK_F6, sdl2.SDLK_F7, sdl2.SDLK_F8, sdl2.SDLK_F9, sdl2.SDLK_F10, sdl2.SDLK_F11, sdl2.SDLK_F12 => {
            const fn_num = @as(u32, @intCast(keycode - sdl2.SDLK_F1 + 1));
            try self.writeFunction(fn_num, shift, ctrl, alt);
            return true;
        },
        sdl2.SDLK_KP_0, sdl2.SDLK_KP_1, sdl2.SDLK_KP_2, sdl2.SDLK_KP_3, sdl2.SDLK_KP_4, sdl2.SDLK_KP_5, sdl2.SDLK_KP_6, sdl2.SDLK_KP_7, sdl2.SDLK_KP_8, sdl2.SDLK_KP_9, sdl2.SDLK_KP_MULTIPLY, sdl2.SDLK_KP_PLUS, sdl2.SDLK_KP_MINUS, sdl2.SDLK_KP_PERIOD, sdl2.SDLK_KP_DIVIDE => {
            return try self.writeKeypad(keycode, shift, ctrl, alt);
        },
        else => {
            // 忽略普通 ASCII 字符
            if (keycode >= 32 and keycode <= 126) {
                return false;
            }
            return false;
        },
    }
    return true;
}

fn writeKeypad(self: *Input, keycode: i32, shift: bool, ctrl: bool, alt: bool) !bool {
    if (self.term.mode.app_keypad) {
        var c: u8 = 0;
        if (keycode >= sdl2.SDLK_KP_0 and keycode <= sdl2.SDLK_KP_9) {
            c = 'p' + @as(u8, @intCast(keycode - sdl2.SDLK_KP_0));
        } else if (keycode == sdl2.SDLK_KP_MULTIPLY) {
            c = 'j';
        } else if (keycode == sdl2.SDLK_KP_PLUS) {
            c = 'k';
        } else if (keycode == sdl2.SDLK_KP_MINUS) {
            c = 'm';
        } else if (keycode == sdl2.SDLK_KP_PERIOD) {
            c = 'n';
        } else if (keycode == sdl2.SDLK_KP_DIVIDE) {
            c = 'o';
        } else {
            std.log.debug("未处理的 keypad 键 (AppKeypad): {}", .{keycode});
            return false;
        }
        var seq: [3]u8 = undefined;
        const s = try std.fmt.bufPrint(&seq, "\x1BO{c}", .{c});
        _ = try self.pty.write(s);
        return true;
    } else {
        var char: u8 = 0;
        if (keycode >= sdl2.SDLK_KP_0 and keycode <= sdl2.SDLK_KP_9) {
            char = '0' + @as(u8, @intCast(keycode - sdl2.SDLK_KP_0));
        } else if (keycode == sdl2.SDLK_KP_MULTIPLY) {
            char = '*';
        } else if (keycode == sdl2.SDLK_KP_PLUS) {
            char = '+';
        } else if (keycode == sdl2.SDLK_KP_MINUS) {
            char = '-';
        } else if (keycode == sdl2.SDLK_KP_PERIOD) {
            char = '.';
        } else if (keycode == sdl2.SDLK_KP_DIVIDE) {
            char = '/';
        } else {
            std.log.debug("未处理的 keypad 键 (Normal): {}", .{keycode});
            return false;
        }
        try self.writePrintable(char, alt, ctrl, shift);
        return true;
    }
}

pub fn sendMouseReport(self: *Input, x: usize, y: usize, button: u32, mod: u16, event_type: u8) !void {
    if (!self.term.mode.isMouseEnabled()) return;

    var code: u32 = 0;
    const btn = button;

    if (event_type == 2) { // Motion
        if (!self.term.mode.mouse_many and !self.term.mode.mouse_btn) return;
        // Motion events start with 32
        code = 32;
        if (btn >= 1 and btn <= 3) {
            code += btn - 1;
        } else if (btn >= 4 and btn <= 7) {
            code += 64 + (btn - 4);
        } else if (btn >= 8 and btn <= 11) {
            code += 128 + (btn - 8);
        } else {
            code += 3; // No button pressed or button 12+
        }
    } else if (event_type == 1) { // Release
        if (self.term.mode.mouse_x10) return;
        if (btn == 4 or btn == 5) return; // Scroll wheels don't have release
        if (self.term.mode.mouse_sgr) {
            code = btn - 1;
        } else {
            code = 3;
        }
    } else { // Press
        if (btn >= 4 and btn <= 7) {
            code = 64 + (btn - 4);
        } else if (btn >= 8 and btn <= 11) {
            code = 128 + (btn - 8);
        } else {
            code = btn - 1;
        }
    }

    // Add modifiers if not in X10 mode
    if (!self.term.mode.mouse_x10) {
        if ((mod & sdl2.KMOD_SHIFT) != 0) code += 4;
        if ((mod & sdl2.KMOD_ALT) != 0) code += 8;
        if ((mod & sdl2.KMOD_CTRL) != 0) code += 16;
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
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [16]u8 = undefined;

    if (mod > 0) {
        const s = try std.fmt.bufPrint(&seq, "\x1B[1;{d}{c}", .{ mod + 1, direction });
        _ = try self.pty.write(s);
        return;
    }

    const s = if (self.term.mode.app_cursor)
        try std.fmt.bufPrint(&seq, "\x1BO{c}", .{direction})
    else
        try std.fmt.bufPrint(&seq, "\x1B[{c}", .{direction});
    _ = try self.pty.write(s);
}

fn writeHome(self: *Input, alt: bool, ctrl: bool, shift: bool) !void {
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [16]u8 = undefined;
    const s = if (mod > 0)
        try std.fmt.bufPrint(&seq, "\x1B[1;{d}H", .{mod + 1})
    else
        "\x1B[H";
    _ = try self.pty.write(s);
}

fn writeEnd(self: *Input, alt: bool, ctrl: bool, shift: bool) !void {
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [16]u8 = undefined;
    const s = if (mod > 0)
        try std.fmt.bufPrint(&seq, "\x1B[1;{d}F", .{mod + 1})
    else
        "\x1B[F";
    _ = try self.pty.write(s);
}

fn writePageUp(self: *Input, alt: bool, ctrl: bool, shift: bool) !void {
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [16]u8 = undefined;
    const s = if (mod > 0)
        try std.fmt.bufPrint(&seq, "\x1B[5;{d}~", .{mod + 1})
    else
        "\x1B[5~";
    _ = try self.pty.write(s);
}

fn writePageDown(self: *Input, alt: bool, ctrl: bool, shift: bool) !void {
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [16]u8 = undefined;
    const s = if (mod > 0)
        try std.fmt.bufPrint(&seq, "\x1B[6;{d}~", .{mod + 1})
    else
        "\x1B[6~";
    _ = try self.pty.write(s);
}

fn writeFunction(self: *Input, fn_num: u32, shift: bool, ctrl: bool, alt: bool) !void {
    if (fn_num < 1 or fn_num > 12) return;
    const base_seq = switch (fn_num) {
        1 => "P",
        2 => "Q",
        3 => "R",
        4 => "S",
        5 => "15~",
        6 => "17~",
        7 => "18~",
        8 => "19~",
        9 => "20~",
        10 => "21~",
        11 => "23~",
        12 => "24~",
        else => unreachable,
    };
    const mod = @as(u32, @intFromBool(shift)) + @as(u32, @intFromBool(alt)) * 2 + @as(u32, @intFromBool(ctrl)) * 4;
    var seq: [32]u8 = undefined;

    const formatted_seq = if (mod > 0)
        if (fn_num <= 4)
            try std.fmt.bufPrint(&seq, "\x1B[1;{d}{s}", .{ mod + 1, base_seq })
        else
            try std.fmt.bufPrint(&seq, "\x1B[{s:.2};{d}~", .{ base_seq, mod + 1 })
    else if (fn_num <= 4)
        try std.fmt.bufPrint(&seq, "\x1BO{s}", .{base_seq})
    else
        try std.fmt.bufPrint(&seq, "\x1B[{s}", .{base_seq});

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
