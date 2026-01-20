//! 键盘和鼠标输入处理
//! 将 SDL2 输入事件转换为终端转义序列

const std = @import("std");
const sdl = @import("sdl.zig");
const pty = @import("pty.zig");

pub const InputError = error{
    InvalidKey,
    BufferOverflow,
};

/// 输入处理器
pub const Input = struct {
    pty_master: std.os.fd_t,
    mode: struct {
        app_cursor: bool = false,
        app_keypad: bool = false,
        crlf: bool = false,
    } = .{},

    /// 初始化输入处理器
    pub fn init(pty_master: std.os.fd_t) Input {
        return Input{
            .pty_master = pty_master,
        };
    }

    /// 处理键盘事件
    pub fn handleKey(self: *Input, event: *const sdl.SDL_KeyboardEvent) !void {
        const scancode = event.scancode;
        const keycode = event.keycode;
        const mod = event.mod;
        const state = event.state;

        // 只处理按下事件
        if (state != sdl.SDL_PRESSED) {
            return;
        }

        // 检查修饰键
        const ctrl = (mod & sdl.KMOD_LCTRL) != 0 or (mod & sdl.KMOD_RCTRL) != 0;
        const alt = (mod & sdl.KMOD_LALT) != 0 or (mod & sdl.KMOD_RALT) != 0;
        const shift = (mod & sdl.KMOD_LSHIFT) != 0 or (mod & sdl.KMOD_RSHIFT) != 0;

        // 处理特殊键
        switch (scancode) {
            sdl.SDL_SCANCODE_ESCAPE => try self.writeEsc(),
            sdl.SDL_SCANCODE_RETURN => try self.writeReturn(alt),
            sdl.SDL_SCANCODE_TAB => try self.writeTab(alt),
            sdl.SDL_SCANCODE_BACKSPACE => try self.writeBackspace(alt, ctrl),
            sdl.SDL_SCANCODE_DELETE => try self.writeDelete(alt, ctrl),
            sdl.SDL_SCANCODE_UP => try self.writeArrow(alt, 'A', ctrl, shift),
            sdl.SDL_SCANCODE_DOWN => try self.writeArrow(alt, 'B', ctrl, shift),
            sdl.SDL_SCANCODE_LEFT => try self.writeArrow(alt, 'D', ctrl, shift),
            sdl.SDL_SCANCODE_RIGHT => try self.writeArrow(alt, 'C', ctrl, shift),
            sdl.SDL_SCANCODE_HOME => try self.writeHome(alt, ctrl),
            sdl.SDL_SCANCODE_END => try self.writeEnd(alt, ctrl),
            sdl.SDL_SCANCODE_PAGEUP => try self.writePageUp(alt, ctrl),
            sdl.SDL_SCANCODE_PAGEDOWN => try self.writePageDown(alt, ctrl),
            sdl.SDL_SCANCODE_F1 => try self.writeFunction(1, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F2 => try self.writeFunction(2, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F3 => try self.writeFunction(3, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F4 => try self.writeFunction(4, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F5 => try self.writeFunction(5, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F6 => try self.writeFunction(6, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F7 => try self.writeFunction(7, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F8 => try self.writeFunction(8, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F9 => try self.writeFunction(9, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F10 => try self.writeFunction(10, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F11 => try self.writeFunction(11, shift, ctrl, alt),
            sdl.SDL_SCANCODE_F12 => try self.writeFunction(12, shift, ctrl, alt),
            else => {
                // 可打印字符
                if (keycode >= 32 and keycode <= 126) {
                    try self.writePrintable(@as(u8, keycode), alt, ctrl, shift);
                }
            },
        }
    }

    /// 处理鼠标事件
    pub fn handleMouse(self: *Input, event: *const sdl.SDL_MouseButtonEvent) !void {
        // TODO: 实现鼠标报告
        _ = self;
        _ = event;
    }

    /// 写入 ESC 字符
    fn writeEsc(self: *Input) !void {
        _ = try self.pty.write(&.{0x1B});
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
            _ = try self.pty.write(&.{0x08}); // Ctrl+H
        } else {
            _ = try self.pty.write(&.{0x7F}); // DEL
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
        };

        // 应用修饰符
        var seq: [32]u8 = undefined;
        const len = if (modifiers > 0)
            std.fmt.bufPrint(&seq, "\x1B[{s}{s}", .{ modifiers, base_seq })
        else
            std.fmt.bufPrint(&seq, "\x1BO{s}", .{base_seq});

        _ = try self.pty.write(seq[0..len]);
    }

    /// 写入可打印字符
    fn writePrintable(self: *Input, c: u8, alt: bool, ctrl: bool, shift: bool) !void {
        _ = shift;
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
