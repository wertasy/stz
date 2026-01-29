# stz 开发计划 (TODO)

## 已完成功能

### 核心架构
- [x] Zig build system (build.zig) 配置
- [x] 模块化架构 (Terminal, Parser, Renderer, Window, PTY, Selection, Input)
- [x] 核心数据类型定义 (Glyph, GlyphAttr, Mode, EscapeState)

### X11 后端
- [x] X11 窗口创建和事件循环
- [x] 双缓冲渲染 (Pixmap)
- [x] XIM/XIC 输入法集成 (支持中文输入)
- [x] 窗口标题设置 (OSC 0/1/2)
- [x] 窗口大小调整和 PTY resize 通知

### 终端模拟
- [x] VT100/VT220 转义序列解析
- [x] CSI 序列处理 (光标移动、清屏、颜色设置)
- [x] CSI 冒号子参数解析 (用于 SGR 扩展颜色)
- [x] OSC 序列处理 (窗口标题、调色板)
- [x] 私有模式处理 (DECSET/DECRST)
- [x] 字符集切换 (G0-G3, SI/SO)
- [x] 控制字符处理 (BS, CR, LF, HT, BEL)
- [x] 备用屏幕切换 (TUI 程序支持)
- [x] 滚动区域管理

### 字符渲染
- [x] Xft/FreeType 字体渲染
- [x] UTF-8 编解码
- [x] 宽字符 (CJK) 支持
- [x] 字体回退机制 (Fallback)
- [x] 粗体/斜体/下划线/删除线样式
- [x] 反色显示
- [x] TrueColor (24 位真彩色)
- [x] 256 色调色板
- [x] Box Drawing 字符手动绘制 (单线、双线、重线、Braille)
- [x] HarfBuzz 连字支持

### 光标
- [x] 多种光标样式 (Block, Underline, Bar, Hollow)
- [x] 光标闪烁
- [x] 文本闪烁属性
- [x] 焦点状态处理

### 键盘输入
- [x] 普通字符输入
- [x] 功能键映射 (F1-F12, Home, End, PageUp, PageDown)
- [x] 组合键支持 (Ctrl/Alt/Shift + Key)
- [x] Application Keypad/Cursor 模式
- [x] 括号粘贴模式

### 鼠标支持
- [x] 鼠标点击报告 (X10, URXVT, SGR 1006)
- [x] 鼠标滚轮滚动
- [x] 鼠标拖拽选择

### 文本选择
- [x] 鼠标拖选文本
- [x] 双击选词 (Word Snap)
- [x] 三击选行 (Line Snap)
- [x] X11 PRIMARY Selection
- [x] X11 CLIPBOARD Selection
- [x] 中键粘贴
- [x] Ctrl+Shift+V 粘贴

### 滚动
- [x] 滚动缓冲区 (Scrollback)
- [x] Shift+PgUp/PgDn 查看历史
- [x] 鼠标滚轮滚动历史

### 其他功能
- [x] URL 自动检测 (http://, https://, ftp://)
- [x] Ctrl+点击打开 URL (xdg-open)
- [x] 打印屏幕内容 (Shift+Print)
- [x] 打印选择内容 (Print)
- [x] 切换自动打印模式 (Ctrl+Print)
- [x] OSC 52 剪贴板 (远程复制到本地剪贴板)

## 待完善 / 技术债

### 功能差距
- [ ] **OSC 104 颜色重置**: 目前强制重置整个调色板，不支持按索引重置特定颜色
- [ ] **字体缩放**: config.zig 已定义快捷键 (Ctrl+Shift+PgUp/PgDn)，但功能未实现

### 性能优化
- [x] **渲染脏行优化**: 重新启用 dirty 标记检查，避免每一帧全屏重绘 (Renderer)
- [x] **X11 同步优化**: 将热路径(present)中的 XSync 替换为 XFlush，减少阻塞
- [ ] **URL 检测优化**: 避免在处理 PTY 数据的主循环中频繁触发正则扫描，改为空闲/节流触发
- [ ] **渲染内存分配**: 优化波浪线绘制等热路径的堆内存分配 (Renderer)
- [ ] **字体回退缓存**: 缓存字符到字体的映射，减少 XftCharExists 和 FcFontMatch 调用

### 高级特性
- [ ] **透明度**: X11 Alpha 通道支持 (window.zig 有 TODO 注释)

### 代码质量
- [ ] 增加单元测试覆盖率
- [ ] 完善错误处理和日志

## 已知问题

1. **Resize 闪烁**: 调整窗口大小时可能有短暂黑屏
