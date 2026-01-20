# stz - 待完成功能清单

## 重要说明

### SDL 版本问题

当前代码使用 **SDL3**，但环境只有 **SDL2**。需要以下修改：

1. 更新 `build.zig.zon` - 使用 SDL2 依赖
2. 修改所有 SDL3 API 为 SDL2 等价 API
3. 主要差异：
   - SDL3: `SDL_Init` → SDL2: `SDL_Init`
   - SDL3: `SDL_CreateWindow` → SDL2: `SDL_CreateWindow`
   - SDL3: 事件循环 `SDL_PollEvent` → SDL2: `SDL_PollEvent`
   - SDL3: 渲染器 API 有变化

---

## 待完善功能

### 🔴 高优先级（核心功能）

#### 1. SDL2 兼容性改造
**复杂度**: 高
**影响模块**: `window.zig`, `renderer.zig`, `main.zig`

- [ ] 更新 `build.zig.zon` 中的 SDL3 依赖为 SDL2
- [ ] 修改 `window.zig` 中的所有 SDL3 调用为 SDL2
- [ ] 更新事件类型定义（SDL3 使用枚举，SDL2 使用 u32）
- [ ] 测试跨平台编译

**SDL3 → SDL2 主要 API 映射**:
```zig
SDL3                              SDL2
-----------------------------------------
SDL_Init                          SDL_Init
SDL_Quit                           SDL_Quit
SDL_CreateWindow                   SDL_CreateWindow
SDL_DestroyWindow                 SDL_DestroyWindow
SDL_CreateRenderer                 SDL_CreateRenderer
SDL_DestroyRenderer               SDL_DestroyRenderer
SDL_SetRenderDrawColor            SDL_SetRenderDrawColor
SDL_RenderFillRect               SDL_RenderFillRect
SDL_RenderPresent                 SDL_RenderPresent
SDL_PollEvent                   SDL_PollEvent
SDL_Delay                       SDL_Delay
SDL_SCANCODE_*                    SDL_SCANCODE_* (保持兼容)
SDL_KEY_*                       SDL_KEY_* (保持兼容)
SDL_BUTTON_*                    SDL_BUTTON_* (保持兼容)
SDL_WINDOWPOS_UNDEFINED            SDL_WINDOWPOS_UNDEFINED
SDL_WINDOW_RESIZABLE              SDL_WINDOW_RESIZABLE
SDL_WINDOW_HIDDEN                 SDL_WINDOW_SHOWN
SDL_RENDERER_ACCELERATED          SDL_RENDERER_ACCELERATED
SDL_RENDERER_PRESENTVSYNC          SDL_RENDERER_PRESENTVSYNC
SDL_WINDOWEVENT_*                 SDL_WINDOWEVENT_*
SDL_KEYDOWN                       SDL_KEYDOWN
SDL_KEYUP                         SDL_KEYUP
SDL_MOUSEBUTTONDOWN               SDL_MOUSEBUTTONDOWN
SDL_MOUSEBUTTONUP               SDL_MOUSEBUTTONUP
SDL_MOUSEMOTION                 SDL_MOUSEMOTION
```

#### 2. 字体加载和渲染
**复杂度**: 高
**影响模块**: `renderer.zig`, 新建 `font.zig`

- [ ] 创建 `font.zig` 模块
- [ ] 使用 FontConfig 加载字体
- [ ] 使用 FreeType2 渲染字形
- [ ] 实现 glyph 缓存（优化性能）
- [ ] 支持粗体、斜体、下划线渲染
- [ ] 支持字体回退（fallback）
- [ ] 计算字符实际宽度（考虑合字）

**需要添加的依赖**:
- `fontconfig` (通过 pkg-config 获取)
- `freetype2` (通过 pkg-config 获取)

#### 3. 完整的转义序列支持
**复杂度**: 中
**影响模块**: `parser.zig`, `terminal.zig`

- [ ] 完善 CSI 参数解析（支持 `:` 分隔的参数）
- [ ] 实现所有 SGR 属性（颜色、粗体、斜体等）
- [ ] 实现字符属性（闪烁、反色、隐藏、删除线）
- [ ] 支持保存/恢复光标（DECSC/DECRC）
- [ ] 实现 DECSTBM（设置滚动区域）完整逻辑
- [ ] 支持 DCS（设备控制字符串）
- [ ] 支持 PM（私有消息）
- [ ] 支持 APC（应用程序命令）

**具体 SGR 序列**:
- [ ] 前景色 30-37, 38-48 (索引和真彩)
- [ ] 背景色 40-47, 48-49
- [ ] 粗体 1/22
- [ ] 斜体 3/23
- [ ] 下划线 4/24
- [ ] 闪烁 5/25
- [ ] 反色 7/27
- [ ] 隐藏 8/28
- [ ] 删除线 9/29

#### 4. 颜色渲染系统
**复杂度**: 中
**影响模块**: `renderer.zig`

- [ ] 实现 256 色调色板（6x6x6x6 + 24 灰度）
- [ ] 实现真彩色（24位 RGB: 2^24）
- [ ] 支持颜色初始化序列（OSC 4）
- [ ] 支持动态颜色查询（OSC 10, 11, 12）
- [ ] 实现调色板重新加载

**256 色公式**:
```zig
// 16-231: 6x6x6x6 立方体
r = (n - 16) / 36 * 51
g = ((n - 16) % 36) / 6 * 51
b = ((n - 16) % 6) * 51

// 232-255: 24 灰度
gray = (n - 232) * 10 + 8
```

#### 5. 鼠标协议支持
**复杂度**: 中高
**影响模块**: `input.zig`, `pty.zig`

- [ ] 实现 X10 鼠标协议（基本报告）
- [ ] 实现 UTF-8 鼠标协议（不推荐）
- [ ] 实现 SGR 鼠标协议（推荐）
- [ ] 实现 URXVT 鼠标协议（不推荐）
- [ ] 支持按钮拖拽报告
- [ ] 实现所有鼠标事件格式

**鼠标报告格式**:
- X10: `\x1B[M<Cb><Cx><Cy>` (旧格式)
- SGR: `\x1B[<0;<Cx>;<Cy><M/m>`
- 按钮编码:
  - 按下: 0-3
  - 释放: 0-3
  - 移动: 32, 35 (无按钮/有按钮)
  - 修饰符: Shift+4, Alt+8, Ctrl+16

#### 6. 剪贴板集成
**复杂度**: 中
**影响模块**: `selection.zig`

- [ ] 使用 SDL2 剪贴板 API
- [ ] 支持 PRIMARY 选择（X11 特有）
- [ ] 支持 CLIPBOARD 选择
- [ ] 处理 INCR 选择传输（大块数据）
- [ ] 实现拖放支持（可选）

**SDL2 剪贴板 API**:
- `SDL_SetClipboardText` - 设置剪贴板
- `SDL_GetClipboardText` - 获取剪贴板

### 🟡 中优先级（增强功能）

#### 7. 终端模式支持
**复杂度**: 中
**影响模块**: `terminal.zig`

- [ ] DECANM - ANSI/VT52 模式切换
- [ ] DECAWM - 自动换行模式
- [ ] DECCOLM - 列模式（80/132 列）
- [ ] DECNKM - 应用小键盘模式
- [ ] DECPAM - 数字小键盘模式
- [ ] IRM - 插入/替换模式
- [ ] SRM - 发送/接收模式
- [ ] LNM - 新行模式

#### 8. 文本选择增强
**复杂度**: 中
**影响模块**: `selection.zig`

- [ ] 完整实现单词吸附（使用配置的分隔符）
- [ ] 实现双击选择单词
- [ ] 实现三击选择行
- [ ] 支持矩形选择（跨行）
- [ ] 实现超时检测（双击 300ms, 三击 600ms）

#### 9. 窗口功能
**复杂度**: 中
**影响模块**: `window.zig`, `main.zig`

- [ ] 实现窗口标题设置（OSC 0/2）
- [ ] 支持窗口图标设置（OSC 1）
- [ ] 实现最小化/最大化/恢复
- [ ] 支持全屏切换
- [ ] 实现窗口透明度（可选）
- [ ] 处理焦点获得/失去事件

#### 10. 字符宽度计算
**复杂度**: 中
**影响模块**: `unicode.zig`, `renderer.zig`

- [ ] 正确处理合字（combining characters）
- [ ] 处理双宽字符（CJK 字符）
- [ ] 处理零宽字符
- [ ] 使用 Unicode East Asian Width 标准

**双宽字符范围**:
- CJK 统一表意文字符
- CJK 符号和标点
- 全角字符
- Hangul Jamo

### 🟢 低优先级（优化和美化）

#### 11. 性能优化
**复杂度**: 高
**影响模块**: `renderer.zig`, `terminal.zig`

- [ ] 实现双缓冲渲染（消除闪烁）
- [ ] 只重绘脏区域（优化性能）
- [ ] 实现 glyph 纹理缓存
- [ ] 使用 SDL 纹理加速渲染
- [ ] 减少不必要的状态切换

**脏区域优化**:
```zig
// 只重绘标记为脏的行
for (dirty_rows) |row| {
    renderRow(row);
}
```

#### 12. 框线字符完整实现
**复杂度**: 中
**影响模块**: `boxdraw.zig`, `renderer.zig`

- [ ] 实现所有水平线（U+2500-U+250F）
- [ ] 实现所有垂直线（U+2500-U+250F）
- [ ] 实现所有角字符（U+250C-U+251F）
- [ ] 实现所有交叉字符（U+253C）
- [ ] 实现块元素（U+2580-U+259F）
- [ ] 实现点阵元素（U+2800-U+28FF）

#### 13. 调试和日志
**复杂度**: 低
**影响模块**: 全局

- [ ] 添加详细的转义序列日志（可选）
- [ ] 实现性能统计（FPS, 渲染时间）
- [ ] 添加内存使用监控
- [ ] 实现调试模式（显示未识别的序列）

#### 14. 配置系统增强
**复杂度**: 低
**影响模块**: `config.zig`

- [ ] 支持配置文件（~/.stzrc）
- [ ] 支持命令行参数（-e 执行命令，-f 字体等）
- [ ] 支持环境变量（STZ_XXX）
- [ ] 添加颜色主题配置（catppuccin, gruvbox 等）

#### 15. 兼容性测试
**复杂度**: 高
**影响模块**: 全部

- [ ] 测试 vim, emacs, tmux
- [ ] 测试 ncurses 程序
- [ ] 测试 shell 交互（zsh, bash, fish）
- [ ] 测试颜色程序（ls --color, dircolors）
- [ ] 测试 Unicode 显示
- [ ] 测试复制粘贴
- [ ] 性能基准测试

---

## 实施建议

### 立即开始（阻塞其他工作）

1. **SDL2 兼容性改造**
   - 这是必须的第一步
   - 预计时间: 4-8 小时

2. **字体加载和渲染**
   - 核心功能，影响用户体验
   - 预计时间: 8-12 小时

### 后续开发（按优先级）

3. 完整的转义序列（4-8 小时）
4. 颜色渲染系统（4-6 小时）
5. 鼠标协议支持（6-8 小时）
6. 文本选择增强（3-5 小时）

### 优化和美化阶段

7. 性能优化（8-12 小时）
8. 框线字符完整实现（2-4 小时）
9. 窗口功能（2-4 小时）
10. 调试和日志（2-3 小时）
11. 配置系统增强（3-4 小时）

### 测试和发布

12. 兼容性测试（持续进行）
13. 文档完善（2-3 小时）
14. 打包和发布（2 小时）

---

## 参考资源

### Zig 相关
- [Zig 0.15.2 文档](http://127.0.0.1:42857/)
- [Zig 标准库参考](https://ziglang.org/documentation/master/std/)

### SDL 相关
- [SDL2 Wiki](https://wiki.libsdl.org/)
- [SDL2 API 文档](https://wiki.libsdl.org/CategoryAPI)
- [SDL3 到 SDL2 迁移指南](https://github.com/libsdl-org/SDL/blob/main/docs/README-migration.md)

### 终端相关
- [VT100 标准](https://vt100.net/)
- [VT220 手册](https://vt100.net/docs/vt220.html)
- [Xterm 控制序列](http://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
- [ANSI 转义序列](https://en.wikipedia.org/wiki/ANSI_escape_code)
- [ECMA-48 标准](https://www.ecma-international.org/publications/standards/Ecma-048.htm)

### 字体相关
- [FontConfig](https://www.freedesktop.org/wiki/Software/fontconfig)
- [FreeType2](https://freetype.org/)
- [Unicode 宽度标准](https://www.unicode.org/reports/tr11/)

### 其他终端模拟器参考
- [st 源码](https://st.suckless.org/) - 原始 C 版本
- [Alacritty 源码](https://github.com/alacritty/alacritty) - Rust 实现
- [kitty 源码](https://github.com/kovidgoyal/kitty) - Python 实现

---

## 实施检查清单

在开始每个任务前，请检查：

- [ ] 是否了解相关的终端标准
- [ ] 是否有类似的实现可以参考
- [ ] 是否考虑了边界情况
- [ ] 是否有测试计划
- [ ] 是否更新了相关文档

完成后，请检查：

- [ ] 代码是否编译通过
- [ ] 是否有内存泄漏
- [ ] 是否通过基本测试
- [ ] 是否有性能问题
- [ ] 是否更新了 TODO.md

---

**最后更新**: 2026-01-16
**版本**: v0.1.0
**当前进度**: 核心框架已完成，待 SDL2 迁移和功能增强
