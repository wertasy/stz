//! 字符渲染系统 (Xft 实现)
const std = @import("std");
const x11 = @import("x11.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const Window = @import("window.zig").Window;
const renderer_utils = @import("renderer_utils.zig");

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

    pub fn render(self: *Renderer, term: *Term) !void {
        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return;

        // Default background color
        var default_bg = try self.getColor(term, 259);

        // Iterate over rows
        for (0..@min(term.row, screen.?.len)) |y| {
            // Determine which line to draw
            var line_data: []Glyph = undefined;

            if (term.scr > 0 and !term.mode.alt_screen) {
                // Drawing from history
                if (y < term.row) {
                    // Calculate index in history ring buffer
                    // hist_idx points to the *next* write position (oldest line if full, or empty)
                    // The newest line is at (hist_idx - 1 + hist_max) % hist_max

                    // We want to show lines from history.
                    // scr=1 means show the last line of history at the bottom of the screen?
                    // No, usually scr=N means we shifted the view up by N lines.
                    // So screen[row-1] becomes history[newest], screen[row-2] becomes history[newest-1]...

                    // If term.scr > 0, we are looking at history.
                    // The screen shows:
                    //   Lines from history (top to bottom)
                    //   ...
                    //   Maybe lines from current screen buffer if scr < term.row?

                    // Simplified logic:
                    // If scr > 0, the entire screen is shifted down.
                    // The line at screen y corresponds to logical line (y - scr).
                    // If (y - scr) < 0, it's in history.

                    // Let's look at how st does it.
                    // Tline(y) macro:
                    // ((y) < term.scr ? term.hist[((y) + term.histi - term.scr + term.histlen + 1) % term.histlen] : term.line[(y) - term.scr])

                    // Wait, st's `term.scr` is the scroll offset (how many lines we scrolled up).
                    // `term.histi` is the index of the latest history line.

                    // In my implementation:
                    // `term.hist_idx` is the next write position.
                    // So `term.hist_idx - 1` is the newest line.

                    // Let's assume typical behavior:
                    // We want to display line `y` (0..row-1) on the window.
                    // The logical line index is `L = y - term.scr` relative to the current screen top.
                    // But `term.scr` shifts the view UP, so we see older lines.
                    // So the line we see at `y` is actually `y - term.scr` relative to the *current* screen top?
                    // No. If scr=1, the line at y=row-1 (bottom) is the line that was at row-2.
                    // The line at y=0 is history[newest].

                    // Correct mapping:
                    // We want to fetch line `L` where `L = y - term.scr`.
                    // Since `y` is 0..row-1 and `scr` is 0..hist_cnt, `L` can be negative.
                    // If `L >= 0`, it is `term.line[L]`. (Only if we scrolling "within" the buffer? No)

                    // Actually, `scr` acts as an offset into the "virtual" buffer composed of History + Screen.
                    // Virtual buffer:
                    // [ Hist 0 ] <- Oldest
                    // ...
                    // [ Hist N ] <- Newest
                    // [ Line 0 ] <- Top of current screen
                    // ...
                    // [ Line R ] <- Bottom of current screen

                    // When scr=0, we see [Line 0] to [Line R].
                    // When scr=1, we see [Hist N] to [Line R-1].
                    // When scr=S, row `y` corresponds to:
                    //   If `y < S`: It comes from History.
                    //   If `y >= S`: It comes from Screen (index `y - S`).

                    if (y < term.scr) {
                        // Fetch from history
                        // Which history line?
                        // y=0, scr=1 => index 0 from bottom of history?
                        // We want the lines to be contiguous.
                        // Screen line `scr` maps to `term.line[0]`.
                        // Screen line `scr-1` maps to `hist[newest]`.
                        // Screen line `scr-k` maps to `hist[newest - k + 1]`.
                        // So `y` maps to `hist[newest - (scr - 1 - y)]` = `hist[newest - scr + 1 + y]`.

                        if (term.hist_cnt > 0) {
                            const newest_idx = (term.hist_idx + term.hist_max - 1) % term.hist_max;
                            // Calculate offset backwards from newest
                            const offset = term.scr - 1 - y;
                            if (offset < term.hist_cnt) {
                                const hist_fetch_idx = (newest_idx + term.hist_max - offset) % term.hist_max;
                                line_data = term.hist.?[hist_fetch_idx];
                            } else {
                                // Out of history bounds (should not happen if scr is clamped)
                                line_data = term.line.?[0]; // Fallback or clear?
                            }
                        } else {
                            line_data = term.line.?[0];
                        }
                    } else {
                        // Fetch from screen
                        line_data = term.line.?[y - term.scr];
                    }
                }
            } else {
                line_data = screen.?[y];
            }

            // Check dirty flag
            // If scrolling, we should redraw everything or handle dirty logic carefully.
            // Simplified: If scr > 0, always redraw or assume dirty.
            // Or better: setFullDirty when scrolling.
            if (term.scr == 0) {
                if (term.dirty) |dirty| {
                    if (!dirty[y]) continue;
                }
            }

            // Clear the dirty row with default background
            const y_pos = @as(i32, @intCast(y * self.char_height));
            x11.XftDrawRect(self.draw, &default_bg, 0, y_pos, @intCast(self.window.width), @intCast(self.char_height));

            for (0..@min(term.col, line_data.len)) |x| {
                const glyph = line_data[x];
                const x_pos = @as(i32, @intCast(x * self.char_width));

                // Determine colors based on attributes
                var fg_idx = glyph.fg;
                var bg_idx = glyph.bg;

                // Handle Bold (bright colors)
                if (glyph.attr.bold) {
                    if (fg_idx < 8) {
                        fg_idx += 8;
                    } else if (fg_idx == config.Config.colors.default_foreground) {
                        fg_idx = 15; // Map bold default to bright white
                    }
                }

                // Handle Global and character Reverse
                const reverse = glyph.attr.reverse != term.mode.reverse;
                if (reverse) {
                    const tmp = fg_idx;
                    fg_idx = bg_idx;
                    bg_idx = tmp;
                }

                // Handle text blinking (ATTR_BLINK)
                // If blink is enabled and glyph has blink attribute, toggle visibility
                if (glyph.attr.blink and config.Config.cursor.blink_interval_ms > 0) {
                    // Check blink state based on time
                    const blink_state = @mod(@divFloor(std.time.milliTimestamp(), config.Config.cursor.blink_interval_ms), 2) == 0;
                    if (!blink_state) {
                        // Skip drawing this character (it's in the "off" phase)
                        continue;
                    }
                }

                // Draw background if not default (optimization)
                // Note: The row was already cleared with default_bg.
                if (bg_idx != config.Config.colors.default_background) {
                    var bg_col = try self.getColor(term, bg_idx);
                    x11.XftDrawRect(self.draw, &bg_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                }

                // Draw Box Drawing Characters manually
                if (config.Config.draw.boxdraw and glyph.u >= 0x2500 and glyph.u <= 0x259F) {
                    var fg = try self.getColor(term, fg_idx);
                    try self.drawBoxChar(glyph.u, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height), &fg);
                }
                // Draw character
                else if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, fg_idx);
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }

                // Draw Underline
                if (glyph.attr.underline) {
                    // Determine underline color (use ustyle color if specified, else fg)
                    const underline_fg_idx = if (glyph.ucolor[0] >= 0) custom: {
                        // Custom RGB color for underline
                        const r = @as(u8, @intCast(@max(0, glyph.ucolor[0])));
                        const g = @as(u8, @intCast(@max(0, glyph.ucolor[1])));
                        const b = @as(u8, @intCast(@max(0, glyph.ucolor[2])));
                        // Create a temporary color index (0xFFRRGGBB format)
                        break :custom 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
                    } else fg_idx;

                    var underline_fg = try self.getColor(term, underline_fg_idx);
                    const thickness = config.Config.cursor.thickness;
                    const underline_y = y_pos + self.ascent + 1;

                    // Draw based on underline style
                    if (glyph.ustyle == 0 or glyph.ustyle < 0) {
                        // Solid underline (default)
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y, @intCast(self.char_width), thickness);
                    } else if (glyph.ustyle == 1) {
                        // Double underline
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y, @intCast(self.char_width), thickness);
                        x11.XftDrawRect(self.draw, &underline_fg, x_pos, underline_y + thickness * 2, @intCast(self.char_width), thickness);
                    } else if (glyph.ustyle == 2) {
                        // Curly underline (simplified wave)
                        // Draw small arcs to simulate wave pattern
                        const wave_width_u = @divTrunc(self.char_width, 4);
                        const wave_height = thickness * 2;
                        const wave_y = underline_y + wave_height;

                        for (0..4) |i| {
                            const arc_x = x_pos + @as(i32, @intCast(i * wave_width_u)) + @as(i32, @intCast(wave_width_u / 2));
                            const arc_start_y = if (i % 2 == 0) underline_y else wave_y;
                            // Draw simple vertical line segments to simulate wave
                            x11.XftDrawRect(self.draw, &underline_fg, arc_x, arc_start_y, 1, wave_height);
                        }
                    } else if (glyph.ustyle == 3) {
                        // Dotted/Dashed underline
                        const dash_width_u = @divTrunc(self.char_width, 4);
                        for (0..4) |i| {
                            const dash_x = x_pos + @as(i32, @intCast(i * dash_width_u * 2));
                            x11.XftDrawRect(self.draw, &underline_fg, dash_x, underline_y, dash_width_u, thickness);
                        }
                    }
                }

                // Draw Strikethrough (optional, if attribute exists)
                if (glyph.attr.struck) {
                    var fg = try self.getColor(term, fg_idx);
                    x11.XftDrawRect(self.draw, &fg, x_pos, y_pos + @divTrunc(self.ascent * 2, 3), @intCast(self.char_width), 1);
                }
            }

            // Clear dirty flag for this row
            if (term.dirty) |dirty| {
                dirty[y] = false;
            }
        }
    }

    pub fn renderCursor(self: *Renderer, term: *Term) !void {
        if (term.mode.hide_cursor) return;

        const cx = term.c.x;
        const cy = term.c.y;

        // Ensure cursor is within bounds
        if (cx >= term.col or cy >= term.row) return;

        // Handle cursor blinking
        const now = std.time.milliTimestamp();
        if (config.Config.cursor.blink_interval_ms > 0) {
            if (now - self.last_blink_time >= config.Config.cursor.blink_interval_ms) {
                self.cursor_blink_state = !self.cursor_blink_state;
                self.last_blink_time = now;
            }
        } else {
            self.cursor_blink_state = true;
        }

        // Cursor styles (matching st):
        // 0: blinking block
        // 1: blinking block (default)
        // 2: steady block
        // 3: blinking underline
        // 4: steady underline
        // 5: blinking bar
        // 6: steady bar
        // 7: blinking st cursor
        // 8: steady st cursor
        const style = config.Config.cursor.style;
        const is_blinking_style = (style == 0 or style == 1 or style == 3 or style == 5 or style == 7);

        // Check if blinking is enabled (MODE_BLINK)
        if (is_blinking_style and term.mode.blink and !self.cursor_blink_state) {
            return;
        }

        const x_pos = @as(i32, @intCast(cx * self.char_width));
        const y_pos = @as(i32, @intCast(cy * self.char_height));

        // Get glyph under cursor
        const screen = if (term.mode.alt_screen) term.alt else term.line;
        var glyph = Glyph{};
        if (screen) |scr| {
            if (cy < scr.len and cx < scr[cy].len) {
                glyph = scr[cy][cx];
            }
        }

        // Determine cursor colors based on st's logic
        var cursor_fg_idx: u32 = undefined;
        var cursor_bg_idx: u32 = undefined;

        if (term.mode.reverse) {
            // In reverse mode
            if (self.cursor_blink_state and is_blinking_style) {
                cursor_bg_idx = 258; // default_fg
            } else {
                cursor_bg_idx = 259; // default_bg
            }
        } else {
            // Normal mode
            cursor_bg_idx = 256; // cursor color
            cursor_fg_idx = 259; // default background
        }

        // Render based on cursor style
        var draw_col = try self.getColor(term, cursor_bg_idx);

        switch (style) {
            0, 1 => { // blinking block
                if (!term.mode.blink or self.cursor_blink_state) {
                    // Draw full block
                    x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                    // Draw character
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
                // Draw outline
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, @intCast(self.char_width), thickness); // top
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos + self.char_height - thickness, @intCast(self.char_width), thickness); // bottom
                x11.XftDrawRect(self.draw, &draw_col, x_pos, y_pos, thickness, @intCast(self.char_height)); // left
                x11.XftDrawRect(self.draw, &draw_col, x_pos + self.char_width - thickness, y_pos, thickness, @intCast(self.char_height)); // right
                // Draw character
                if (glyph.u != ' ' and glyph.u != 0) {
                    var fg = try self.getColor(term, 258); // default fg
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, &fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }
            },
            else => {}, // unknown style, don't draw
        }
    }

    /// 绘制 Box Drawing 字符
    fn drawBoxChar(self: *Renderer, u: u21, x: i32, y: i32, w: i32, h: i32, color: *x11.XftColor) !void {
        const bd: i32 = 1; // 边框粗细 (light)
        // const bdb: i32 = 2; // 边框粗细 (bold) - 暂时不用

        // 计算中心点
        const cx = x + @divTrunc(w, 2);
        const cy = y + @divTrunc(h, 2);

        // 绘制线条
        // 0x2500 ─ LIGHT HORIZONTAL
        // 0x2502 │ LIGHT VERTICAL
        // ...

        // 简单的实现：只处理最常见的单线字符
        // 实际上应该完整实现 Unicode Box Drawing 范围

        // Horizontal (Left-Right)
        if (u == 0x2500 or u == 0x2501 or u == 0x2502 or u == 0x2503) {
            // Let font handle simple lines if possible? No, we want pixel perfection.
        }

        // 绘制水平线
        if (renderer_utils.boxCharHasLeft(u)) {
            x11.XftDrawRect(self.draw, color, x, cy - @divTrunc(bd, 2), @intCast(cx - x + @divTrunc(bd + 1, 2)), @intCast(bd));
        }
        if (renderer_utils.boxCharHasRight(u)) {
            x11.XftDrawRect(self.draw, color, cx, cy - @divTrunc(bd, 2), @intCast(x + w - cx), @intCast(bd));
        }

        // 绘制垂直线
        if (renderer_utils.boxCharHasUp(u)) {
            x11.XftDrawRect(self.draw, color, cx - @divTrunc(bd, 2), y, @intCast(bd), @intCast(cy - y + @divTrunc(bd + 1, 2)));
        }
        if (renderer_utils.boxCharHasDown(u)) {
            x11.XftDrawRect(self.draw, color, cx - @divTrunc(bd, 2), cy, @intCast(bd), @intCast(y + h - cy));
        }
    }

    /// 更新绘制目标（在窗口大小调整后调用）
    pub fn resize(self: *Renderer) void {
        x11.XftDrawChange(self.draw, self.window.buf);
    }

    /// 重置光标闪烁计时器
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
