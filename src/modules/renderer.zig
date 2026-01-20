//! 字符渲染系统 (Xft 实现)
const std = @import("std");
const x11 = @import("x11.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const selection = @import("selection.zig");
const boxdraw = @import("boxdraw.zig");
const boxdraw_data = @import("boxdraw_data.zig");
const Window = @import("window.zig").Window;

const Glyph = types.Glyph;
const Term = types.Term;

pub const RendererError = error{
    XftDrawCreateFailed,
    FontLoadFailed,
    ColorAllocFailed,
};

pub const Renderer = struct {
    window: *Window,
    allocator: std.mem.Allocator,
    draw: *x11.XftDraw,
    font: *x11.XftFont,

    char_width: u32,
    char_height: u32,
    ascent: i32,
    descent: i32,

    // Cursor blink state
    cursor_blink_state: bool = true,
    last_blink_time: i64 = 0,

    // Color cache (256 indexed + 4 special + some margin)
    colors: [300]x11.XftColor,
    loaded_colors: [300]bool,
    truecolor_cache: std.AutoArrayHashMap(u32, x11.XftColor),

    pub fn init(window: *Window, allocator: std.mem.Allocator) !Renderer {
        // Initialize buffer in window if not already
        window.resizeBuffer(window.width, window.height);

        const draw = x11.XftDrawCreate(window.dpy, window.buf, window.vis, window.cmap);
        if (draw == null) return error.XftDrawCreateFailed;

        // Load font
        var font_name: [:0]const u8 = config.Config.font.name; // e.g., "Monospace:size=12"

        // Try loading configured font

        var font = x11.XftFontOpenName(window.dpy, window.screen, font_name);

        if (font == null) {
            std.log.warn("Failed to load configured font: {s}, trying default 'Monospace:pixelsize=14'\n", .{font_name});
            font_name = "Monospace:pixelsize=14";
            font = x11.XftFontOpenName(window.dpy, window.screen, font_name);
        }

        if (font == null) {
            std.log.warn("Failed to load default font, trying backup 'fixed'\n", .{});
            font = x11.XftFontOpenName(window.dpy, window.screen, "fixed");
            if (font == null) return error.FontLoadFailed;
        }

        const char_width = @as(u32, @intCast(font.*.max_advance_width));
        const char_height = @as(u32, @intCast(font.*.height));
        const ascent = font.*.ascent;
        const descent = font.*.descent;

        // Update window metrics
        window.cell_width = char_width;
        window.cell_height = char_height;

        return Renderer{
            .window = window,
            .allocator = allocator,
            .draw = draw.?,
            .font = font.?,
            .char_width = char_width,
            .char_height = char_height,
            .ascent = ascent,
            .descent = descent,
            .cursor_blink_state = true,
            .last_blink_time = std.time.milliTimestamp(),
            .colors = undefined,
            .loaded_colors = [_]bool{false} ** 300,
            .truecolor_cache = std.AutoArrayHashMap(u32, x11.XftColor).init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        x11.XftDrawDestroy(self.draw);
        x11.XftFontClose(self.window.dpy, self.font);
        // Free indexed colors
        for (0..300) |i| {
            if (self.loaded_colors[i]) {
                x11.C.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &self.colors[i]);
            }
        }
        // Free truecolors
        var it = self.truecolor_cache.iterator();
        while (it.next()) |entry| {
            x11.C.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, entry.value_ptr);
        }
        self.truecolor_cache.deinit();
    }

    fn getColor(self: *Renderer, term: *Term, index: u32) !x11.XftColor {
        // 24位真彩色使用缓存
        if (index >= 0x10000000) {
            if (self.truecolor_cache.get(index)) |color| {
                return color;
            }

            // 限制缓存大小，防止内存溢出
            if (self.truecolor_cache.count() > 128) {
                // 简单的 FIFO 清理
                const first_key = self.truecolor_cache.keys()[0];
                var entry = self.truecolor_cache.fetchOrderedRemove(first_key).?;
                x11.C.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &entry.value);
            }

            var temp_color: x11.XftColor = undefined;
            const rgb = self.getIndexColor(term, index);
            const render_color = x11.XRenderColor{
                .red = @as(u16, rgb[0]) * 257,
                .green = @as(u16, rgb[1]) * 257,
                .blue = @as(u16, rgb[2]) * 257,
                .alpha = 0xFFFF,
            };
            if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &temp_color) == 0) {
                return error.ColorAllocFailed;
            }
            try self.truecolor_cache.put(index, temp_color);
            return temp_color;
        }

        if (index >= 300) return error.ColorAllocFailed;

        if (self.loaded_colors[index]) {
            return self.colors[index];
        }

        // Allocate color
        // Map index to RGB
        const rgb = self.getIndexColor(term, index);
        const render_color = x11.XRenderColor{
            .red = @as(u16, rgb[0]) * 257,
            .green = @as(u16, rgb[1]) * 257,
            .blue = @as(u16, rgb[2]) * 257,
            .alpha = 0xFFFF,
        };

        if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &render_color, &self.colors[index]) == 0) {
            return error.ColorAllocFailed;
        }

        self.loaded_colors[index] = true;
        return self.colors[index];
    }

    fn getIndexColor(self: *Renderer, term: *Term, index: u32) [3]u8 {
        _ = self;

        // 24 位真彩色 (0xFFRRGGBB 格式)
        if (index >= 0x10000000) {
            const r = @as(u8, @truncate((index >> 16) & 0xFF));
            const g = @as(u8, @truncate((index >> 8) & 0xFF));
            const b = @as(u8, @truncate(index & 0xFF));
            return .{ r, g, b };
        }

        // 标准颜色 (0-7)
        if (index < 8) return u32ToRgb(config.Config.colors.normal[index]); // Note: Config colors are u32 0xRRGGBB
        // 明亮颜色 (8-15)
        if (index < 16) return u32ToRgb(config.Config.colors.bright[index - 8]);
        // 256 色扩展 (16-255)
        if (index < 256) {
            // 从调色板读取 RGB 值
            return u32ToRgb(term.palette[index]);
        }
        // 光标颜色
        if (index == config.Config.colors.default_cursor) return u32ToRgb(config.Config.colors.cursor);
        // 前景色
        if (index == config.Config.colors.default_foreground) return u32ToRgb(config.Config.colors.foreground);
        // 背景色
        if (index == config.Config.colors.default_background) return u32ToRgb(config.Config.colors.background);

        // 默认白色
        return .{ 0xFF, 0xFF, 0xFF };
    }

    pub fn render(self: *Renderer, term: *Term, selector: *selection.Selector) !void {
        const screen = term.line;
        if (screen == null) return;

        // Default background color
        var default_bg = try self.getColor(term, 259);

        // Iterate over rows
        for (0..@min(term.row, screen.?.len)) |y| {
            // Determine which line to draw
            var line_data: []Glyph = undefined;

            if (term.scr > 0 and !term.mode.alt_screen) {
                if (y < term.scr) {
                    if (term.hist_cnt > 0) {
                        const newest_idx = (term.hist_idx + term.hist_max - 1) % term.hist_max;
                        const offset = term.scr - 1 - y;
                        if (offset < term.hist_cnt) {
                            const hist_fetch_idx = (newest_idx + term.hist_max - offset) % term.hist_max;
                            line_data = term.hist.?[hist_fetch_idx];
                        } else {
                            line_data = term.line.?[0];
                        }
                    } else {
                        line_data = term.line.?[0];
                    }
                } else {
                    line_data = term.line.?[y - term.scr];
                }
            } else {
                line_data = screen.?[y];
            }

            // Check dirty flag
            if (term.scr == 0 and selector.selection.mode == .idle) {
                if (term.dirty) |dirty| {
                    if (!dirty[y]) continue;
                }
            }

            // Clear the dirty row with default background
            const border = @as(i32, @intCast(config.Config.window.border_pixels));
            const y_pos = @as(i32, @intCast(y * self.char_height)) + border;
            x11.XftDrawRect(self.draw, &default_bg, 0, y_pos, @intCast(self.window.width), @intCast(self.char_height));

            for (0..@min(term.col, line_data.len)) |x| {
                const glyph = line_data[x];
                const x_pos = @as(i32, @intCast(x * self.char_width)) + border;

                var fg_idx = glyph.fg;
                var bg_idx = glyph.bg;

                if (glyph.attr.bold) {
                    if (fg_idx < 8) {
                        fg_idx += 8;
                    } else if (fg_idx == config.Config.colors.default_foreground) {
                        fg_idx = 15;
                    }
                }

                var reverse = glyph.attr.reverse != term.mode.reverse;
                if (selector.isSelected(x, y)) {
                    reverse = !reverse;
                }

                if (reverse) {
                    const tmp = fg_idx;
                    fg_idx = bg_idx;
                    bg_idx = tmp;
                }

                if (glyph.attr.blink and config.Config.cursor.blink_interval_ms > 0) {
                    const blink_state = @mod(@divFloor(std.time.milliTimestamp(), config.Config.cursor.blink_interval_ms), 2) == 0;
                    if (!blink_state) continue;
                }

                if (bg_idx != config.Config.colors.default_background) {
                    var bg_col = try self.getColor(term, bg_idx);
                    x11.XftDrawRect(self.draw, &bg_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                }

                if (boxdraw.BoxDraw.isBoxDraw(glyph.u)) {
                    var fg = try self.getColor(term, fg_idx);
                    var bg = try self.getColor(term, bg_idx);
                    try self.drawBoxChar(glyph.u, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height), &fg, &bg, glyph.attr.bold);
                } else if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, fg_idx);
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }

                if (glyph.attr.underline) {
                    const underline_fg_idx = if (glyph.ucolor[0] >= 0) custom: {
                        const r = @as(u8, @intCast(@max(0, glyph.ucolor[0])));
                        const g = @as(u8, @intCast(@max(0, glyph.ucolor[1])));
                        const b = @as(u8, @intCast(@max(0, glyph.ucolor[2])));
                        break :custom 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                    } else fg_idx;

                    var underline_fg = try self.getColor(term, underline_fg_idx);
                    const thickness = config.Config.cursor.thickness;
                    const underline_y = y_pos + self.ascent + 1;

                    if (glyph.ustyle <= 0) {
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y, @intCast(self.char_width), thickness);
                    } else if (glyph.ustyle == 1) {
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y, @intCast(self.char_width), thickness);
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y + thickness * 2, @intCast(self.char_width), thickness);
                    } else if (glyph.ustyle == 2) {
                        const wave_width_u = @divTrunc(self.char_width, 4);
                        const wave_height = thickness * 2;
                        const wave_y = underline_y + wave_height;
                        for (0..4) |i| {
                            const arc_x = x_pos + @as(i32, @intCast(i * wave_width_u)) + @as(i32, @intCast(wave_width_u / 2));
                            const arc_start_y = if (i % 2 == 0) underline_y else wave_y;
                            x11.XftDrawRect(self.draw, &underline_fg, arc_x, arc_start_y, 1, wave_height);
                        }
                    } else if (glyph.ustyle == 3) {
                        const dash_width_u = @divTrunc(self.char_width, 4);
                        for (0..4) |i| {
                            const dash_x = x_pos + @as(i32, @intCast(i * dash_width_u * 2));
                            x11.XftDrawRect(self.draw, &underline_fg, dash_x, underline_y, dash_width_u, thickness);
                        }
                    }
                }

                if (glyph.attr.struck) {
                    var fg = try self.getColor(term, fg_idx);
                    x11.XftDrawRect(self.draw, &fg, x_pos, y_pos + @divTrunc(self.ascent * 2, 3), @intCast(self.char_width), 1);
                }
            }

            if (term.dirty) |dirty| {
                dirty[y] = false;
            }
        }
    }

    pub fn renderCursor(self: *Renderer, term: *Term) !void {
        if (term.mode.hide_cursor) return;

        const cx = term.c.x;
        const cy = term.c.y;

        if (cx >= term.col or cy >= term.row) return;

        if (term.scr > 0 and !term.mode.alt_screen) {
            if (cy < term.scr) return;
        }

        const border = @as(i32, @intCast(config.Config.window.border_pixels));
        const x_pos = @as(i32, @intCast(cx * self.char_width)) + border;
        const screen_y = if (term.scr > 0 and !term.mode.alt_screen) cy - term.scr else cy;
        if (screen_y >= term.row) return;
        const y_pos = @as(i32, @intCast(screen_y * self.char_height)) + border;

        const now = std.time.milliTimestamp();
        if (config.Config.cursor.blink_interval_ms > 0) {
            if (now - self.last_blink_time >= config.Config.cursor.blink_interval_ms) {
                self.cursor_blink_state = !self.cursor_blink_state;
                self.last_blink_time = now;
            }
        } else {
            self.cursor_blink_state = true;
        }

        const style = config.Config.cursor.style;
        const is_blinking_style = (style == 0 or style == 1 or style == 3 or style == 5 or style == 7);

        if (is_blinking_style and term.mode.blink and !self.cursor_blink_state) {
            return;
        }

        const screen = term.line;
        var glyph = Glyph{};
        if (screen) |scr| {
            if (cy < scr.len and cx < scr[cy].len) {
                glyph = scr[cy][cx];
            }
        }

        const cursor_fg_idx: u32 = 259;
        var cursor_bg_idx: u32 = 256;

        if (term.mode.reverse) {
            if (self.cursor_blink_state and is_blinking_style) {
                cursor_bg_idx = 258;
            } else {
                cursor_bg_idx = 259;
            }
        }

        var draw_col = try self.getColor(term, cursor_bg_idx);

        switch (style) {
            0, 1 => { // blinking block
                if (!term.mode.blink or self.cursor_blink_state) {
                    x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                    if (glyph.u != ' ' and glyph.u != 0) {
                        var fg = try self.getColor(term, cursor_fg_idx);
                        const char = @as(u32, glyph.u);
                        x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                    }
                }
            },
            2 => { // steady block
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, cursor_fg_idx);
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
            3 => { // blinking underline
                if (!term.mode.blink or self.cursor_blink_state) {
                    const thickness = config.Config.cursor.thickness;
                    const y_line = y_pos + self.char_height - thickness;
                    x11.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(self.char_width), thickness);
                }
            },
            4 => { // steady underline
                const thickness = config.Config.cursor.thickness;
                const y_line = y_pos + self.char_height - thickness;
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_line, @intCast(self.char_width), thickness);
            },
            5 => { // blinking bar
                if (!term.mode.blink or self.cursor_blink_state) {
                    const thickness = config.Config.cursor.thickness;
                    x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
                }
            },
            6 => { // steady bar
                const thickness = config.Config.cursor.thickness;
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
            },
            7, 8 => { // st cursor (hollow box)
                const thickness = config.Config.cursor.thickness;
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), thickness);
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos + self.char_height - thickness, @intCast(self.char_width), thickness);
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height));
                x11.XftDrawRect(self.draw, &draw_col, x_pos + self.char_width - thickness, y_pos, thickness, @intCast(self.char_height));
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, 258);
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
            else => {},
        }
    }

    fn drawBoxChar(self: *Renderer, u: u21, x: i32, y: i32, w: i32, h: i32, color: *x11.XftColor, bg_color: *x11.XftColor, bold: bool) !void {
        const data = boxdraw.BoxDraw.getDrawData(u);
        if (data == 0) return;
        const mwh = @min(w, h);
        const base_s = @max(1, @divTrunc(mwh + 4, 8));
        const is_bold = (bold and config.Config.draw.boxdraw_bold) and mwh >= 6;
        const s: i32 = if (is_bold) @max(base_s + 1, @divTrunc(3 * base_s + 1, 2)) else base_s;
        const w2_line = @divTrunc(w - s + 1, 2);
        const h2_line = @divTrunc(h - s + 1, 2);
        const midx = x + w2_line;
        const midy = y + h2_line;
        const cat = data & ~@as(u16, boxdraw_data.BDB | 0xff);
        if (data & boxdraw_data.BRL != 0) {
            const bw1 = @divTrunc(w + 1, 2);
            const bh1 = @divTrunc(h + 2, 4);
            const bh2 = @divTrunc(h + 1, 2);
            const bh3 = @divTrunc(3 * h + 2, 4);
            if (data & 1 != 0) x11.XftDrawRect(self.draw, color, x, y, @intCast(bw1), @intCast(bh1));
            if (data & 2 != 0) x11.XftDrawRect(self.draw, color, x, y + bh1, @intCast(bw1), @intCast(bh2 - bh1));
            if (data & 4 != 0) x11.XftDrawRect(self.draw, color, x, y + bh2, @intCast(bw1), @intCast(bh3 - bh2));
            if (data & 8 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y, @intCast(w - bw1), @intCast(bh1));
            if (data & 16 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh1, @intCast(w - bw1), @intCast(bh2 - bh1));
            if (data & 32 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh2, @intCast(w - bw1), @intCast(bh3 - bh2));
            if (data & 64 != 0) x11.XftDrawRect(self.draw, color, x, y + bh3, @intCast(bw1), @intCast(h - bh3));
            if (data & 128 != 0) x11.XftDrawRect(self.draw, color, x + bw1, y + bh3, @intCast(w - bw1), @intCast(h - bh3));
            return;
        }
        if (cat == boxdraw_data.BBD) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
            x11.XftDrawRect(self.draw, color, x, y + d, @intCast(w), @intCast(h - d));
            return;
        } else if (cat == boxdraw_data.BBU) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * h + 4, 8);
            x11.XftDrawRect(self.draw, color, x, y, @intCast(w), @intCast(d));
            return;
        } else if (cat == boxdraw_data.BBL) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
            x11.XftDrawRect(self.draw, color, x, y, @intCast(d), @intCast(h));
            return;
        } else if (cat == boxdraw_data.BBR) {
            const d = @divTrunc(@as(i32, @intCast(data & 0xFF)) * w + 4, 8);
            x11.XftDrawRect(self.draw, color, x + d, y, @intCast(w - d), @intCast(h));
            return;
        }
        if (cat == boxdraw_data.BBQ) {
            const qw = @divTrunc(w + 1, 2);
            const qh = @divTrunc(h + 1, 2);
            if (data & boxdraw_data.TL != 0) x11.XftDrawRect(self.draw, color, x, y, @intCast(qw), @intCast(qh));
            if (data & boxdraw_data.TR != 0) x11.XftDrawRect(self.draw, color, x + qw, y, @intCast(w - qw), @intCast(qh));
            if (data & boxdraw_data.BL != 0) x11.XftDrawRect(self.draw, color, x, y + qh, @intCast(qw), @intCast(h - qh));
            if (data & boxdraw_data.BR != 0) x11.XftDrawRect(self.draw, color, x + qw, y + qh, @intCast(w - qw), @intCast(h - qh));
            return;
        }
        if (data & boxdraw_data.BBS != 0) {
            const d = @as(u16, @intCast(data & 0xFF));
            var xrc = x11.XRenderColor{
                .red = @intCast(@divTrunc(@as(u32, color.*.color.red) * d + @as(u32, bg_color.*.color.red) * (4 - d) + 2, 4)),
                .green = @intCast(@divTrunc(@as(u32, color.*.color.green) * d + @as(u32, bg_color.*.color.green) * (4 - d) + 2, 4)),
                .blue = @intCast(@divTrunc(@as(u32, color.*.color.blue) * d + @as(u32, bg_color.*.color.blue) * (4 - d) + 2, 4)),
                .alpha = 0xFFFF,
            };
            var xfc: x11.XftColor = undefined;
            if (x11.XftColorAllocValue(self.window.dpy, self.window.vis, self.window.cmap, &xrc, &xfc) != 0) {
                x11.XftDrawRect(self.draw, &xfc, x, y, @intCast(w), @intCast(h));
                x11.C.XftColorFree(self.window.dpy, self.window.vis, self.window.cmap, &xfc);
            }
            return;
        }
        if (data & (boxdraw_data.BDL | boxdraw_data.BDA) != 0) {
            const light = data & (boxdraw_data.LL | boxdraw_data.LU | boxdraw_data.LR | boxdraw_data.LD);
            const double_ = data & (boxdraw_data.DL | boxdraw_data.DU | boxdraw_data.DR | boxdraw_data.DD);
            if (light != 0) {
                const arc = data & boxdraw_data.BDA != 0;
                const multi_light = light & (light -% 1) != 0;
                const multi_double = double_ & (double_ -% 1) != 0;
                const d_len: i32 = if (arc or (multi_double and !multi_light)) -s else 0;
                if (data & boxdraw_data.LL != 0) x11.XftDrawRect(self.draw, color, x, midy, @intCast(w2_line + s + d_len), @intCast(s));
                if (data & boxdraw_data.LU != 0) x11.XftDrawRect(self.draw, color, midx, y, @intCast(s), @intCast(h2_line + s + d_len));
                if (data & boxdraw_data.LR != 0) x11.XftDrawRect(self.draw, color, midx - d_len, midy, @intCast(w - w2_line + d_len), @intCast(s));
                if (data & boxdraw_data.LD != 0) x11.XftDrawRect(self.draw, color, midx, midy - d_len, @intCast(s), @intCast(h - h2_line + d_len));
            }
            if (double_ != 0) {
                const dl = data & boxdraw_data.DL != 0;
                const du = data & boxdraw_data.DU != 0;
                const dr = data & boxdraw_data.DR != 0;
                const dd = data & boxdraw_data.DD != 0;
                if (dl) {
                    const p: i32 = if (dd) -s else 0;
                    const n: i32 = if (du) -s else if (dd) s else 0;
                    x11.XftDrawRect(self.draw, color, x, midy + s, @intCast(w2_line + s + p), @intCast(s));
                    x11.XftDrawRect(self.draw, color, x, midy - s, @intCast(w2_line + s + n), @intCast(s));
                }
                if (du) {
                    const p: i32 = if (dl) -s else 0;
                    const n: i32 = if (dr) -s else if (dl) s else 0;
                    x11.XftDrawRect(self.draw, color, midx - s, y, @intCast(s), @intCast(h2_line + s + p));
                    x11.XftDrawRect(self.draw, color, midx + s, y, @intCast(s), @intCast(h2_line + s + n));
                }
                if (dr) {
                    const p: i32 = if (du) -s else 0;
                    const n: i32 = if (dd) -s else if (du) s else 0;
                    x11.XftDrawRect(self.draw, color, midx - p, midy - s, @intCast(w - w2_line + p), @intCast(s));
                    x11.XftDrawRect(self.draw, color, midx - n, midy + s, @intCast(w - w2_line + n), @intCast(s));
                }
                if (dd) {
                    const p: i32 = if (dr) -s else 0;
                    const n: i32 = if (dl) -s else if (dr) s else 0;
                    x11.XftDrawRect(self.draw, color, midx + s, midy - p, @intCast(s), @intCast(h - h2_line + p));
                    x11.XftDrawRect(self.draw, color, midx - s, midy - n, @intCast(s), @intCast(h - h2_line + n));
                }
            }
        }
    }

    pub fn resize(self: *Renderer) void {
        x11.XftDrawChange(self.draw, self.window.buf);
    }

    pub fn resetCursorBlink(self: *Renderer) void {
        self.cursor_blink_state = true;
        self.last_blink_time = std.time.milliTimestamp();
    }
};

fn u32ToRgb(color: u32) [3]u8 {
    return .{
        @truncate((color >> 16) & 0xFF),
        @truncate((color >> 8) & 0xFF),
        @truncate(color & 0xFF),
    };
}
