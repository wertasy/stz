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

    // Color cache
    colors: [260]x11.XftColor,
    loaded_colors: [260]bool,

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
            .loaded_colors = [_]bool{false} ** 260,
        };
    }

    pub fn deinit(self: *Renderer) void {
        x11.XftDrawDestroy(self.draw);
        x11.XftFontClose(self.window.dpy, self.font);
        // Free colors...
    }

    fn getColor(self: *Renderer, index: u32) !*x11.XftColor {
        if (index >= 260) return error.ColorAllocFailed;

        if (self.loaded_colors[index]) {
            return &self.colors[index];
        }

        // Allocate color
        // Map index to RGB
        const rgb = self.getIndexColor(index);
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
        return &self.colors[index];
    }

    fn getIndexColor(self: *Renderer, index: u32) [3]u8 {
        _ = self;
        // TODO: Use the logic from previous renderer to map index to RGB
        if (index < 8) return u32ToRgb(config.Config.colors.normal[index]); // Note: Config colors are u32 0xRRGGBB
        if (index < 16) return u32ToRgb(config.Config.colors.bright[index - 8]);
        if (index == 256) return u32ToRgb(config.Config.colors.cursor);
        if (index == 258) return u32ToRgb(config.Config.colors.foreground);
        if (index == 259) return u32ToRgb(config.Config.colors.background);

        // Default white
        return .{ 0xFF, 0xFF, 0xFF };
    }

    pub fn render(self: *Renderer, term: *Term) !void {
        const screen = if (term.mode.alt_screen) term.alt else term.line;
        if (screen == null) return;

        // Default background color
        const default_bg = try self.getColor(259);

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
            x11.XftDrawRect(self.draw, default_bg, 0, y_pos, @intCast(self.window.width), @intCast(self.char_height));

            for (0..@min(term.col, line_data.len)) |x| {
                const glyph = line_data[x];
                const x_pos = @as(i32, @intCast(x * self.char_width));

                // Determine colors based on attributes
                var fg_idx = glyph.fg;
                var bg_idx = glyph.bg;

                // Handle Reverse
                if (glyph.attr.reverse) {
                    const tmp = fg_idx;
                    fg_idx = bg_idx;
                    bg_idx = tmp;
                }

                // Handle Bold (bright colors)
                if (glyph.attr.bold and fg_idx < 8) {
                    fg_idx += 8;
                }

                // Draw background if not default (optimization)
                // Note: The row was already cleared with default_bg (259).
                // If the calculated bg_idx is DIFFERENT from 259, we must draw it.
                if (bg_idx != 259) {
                    const bg_col = try self.getColor(bg_idx);
                    x11.XftDrawRect(self.draw, bg_col, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));
                }

                // Draw Box Drawing Characters manually
                if (config.Config.draw.boxdraw and glyph.u >= 0x2500 and glyph.u <= 0x259F) {
                    const fg = try self.getColor(fg_idx);
                    try self.drawBoxChar(glyph.u, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height), fg);
                }
                // Draw character
                else if (glyph.u != ' ' and glyph.u != 0) {
                    const fg = try self.getColor(fg_idx);
                    const char = @as(u32, glyph.u);
                    x11.XftDrawString32(self.draw, fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
                }

                // Draw Underline
                if (glyph.attr.underline) {
                    const fg = try self.getColor(fg_idx);
                    // Draw a 1px line at baseline + 1
                    x11.XftDrawRect(self.draw, fg, x_pos, y_pos + self.ascent + 1, @intCast(self.char_width), 1);
                }

                // Draw Strikethrough (optional, if attribute exists)
                if (glyph.attr.struck) {
                    const fg = try self.getColor(fg_idx);
                    x11.XftDrawRect(self.draw, fg, x_pos, y_pos + @divTrunc(self.ascent * 2, 3), @intCast(self.char_width), 1);
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

        // 0: blinking block
        // 1: blinking block (default)
        // 2: steady block
        // 3: blinking underline
        // 4: steady underline
        // 5: blinking bar
        // 6: steady bar
        const style = config.Config.cursor.style;
        const is_blinking_style = (style == 0 or style == 1 or style == 3 or style == 5);

        if (is_blinking_style and !self.cursor_blink_state) {
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

        // Determine cursor colors
        // Default: Cursor color (256) is background, Text color is what was under it (reversed)
        // Or specific logic.
        // Usually: cursor bg = 256, cursor fg = glyph.fg or bg?
        // st uses: if selected, use reverse.
        // Simple implementation: Draw cursor rect with cursor color (256), then draw char with background color (259) or reversed fg.

        const cursor_bg_idx: u32 = 256; // Cursor color
        const cursor_fg_idx: u32 = 259; // Default background as text color on cursor

        // Draw cursor background rect
        const cursor_bg = try self.getColor(cursor_bg_idx);
        x11.XftDrawRect(self.draw, cursor_bg, x_pos, y_pos, @intCast(self.char_width), @intCast(self.char_height));

        // Draw character under cursor
        if (glyph.u != ' ' and glyph.u != 0) {
            // Use default background color for the text (since cursor is "foreground")
            // Or use the inverse of the glyph's color?
            // Let's use 259 (default bg) for now which creates a "reverse video" block effect if cursor is white/grey.
            const cursor_fg = try self.getColor(cursor_fg_idx);
            const char = @as(u32, glyph.u);
            x11.XftDrawString32(self.draw, cursor_fg, self.font, x_pos, y_pos + self.ascent, &char, 1);
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
