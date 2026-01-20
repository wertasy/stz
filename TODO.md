# stz 开发计划 (TODO)

## ✅ 已完成功能

- [x] **构建系统**: Zig build system (build.zig) 配置完成
- [x] **X11 窗口**: 基本 X11 窗口创建和事件循环
- [x] **PTY**: 伪终端创建、Fork、Exec 和 I/O 重定向
- [x] **ANSI 解析**: 状态机解析 VT100/VT220 转义序列 (包括私有模式处理)
- [x] **Xft 渲染**: 使用 FreeType/Xft 进行字体渲染 (支持 UTF-8)
- [x] **双缓冲**: 使用 X11 Pixmap 防止闪烁
- [x] **基本输入**: 键盘字符输入和简单控制键映射
- [x] **键盘输入完善**:
    - [x] 完整的功能键映射 (F1-F12, Home, End, PageUp, PageDown)
    - [x] 组合键支持 (Ctrl/Alt/Shift + Key)
    - [x] Keypad 模式支持 (支持 Application Keypad 和 Numeric Keypad)
- [x] **渲染优化**:
    - [x] 脏矩形优化 (目前全屏重绘)
    - [x] 粗体/斜体/下划线样式渲染 (支持 Bold 颜色, Underline, Reverse, Strikethrough)
    - [x] 宽字符 (CJK) 渲染对其问题修复 (`wcwidth` 逻辑修正)
    - [x] Box Drawing 字符手动绘制 (无需字体支持)
- [x] **字体处理**:
    - [x] 字体回退 (Fallback) 机制 (Config -> Default -> Fixed)
- [x] **剪贴板与选择**:
    - [x] 鼠标左键拖拽选择文本
    - [x] X11 PRIMARY Selection 支持
    - [x] 中键粘贴 (Middle click paste)
    - [x] 释放鼠标时自动复制到剪贴板
- [x] **控制序列修复**:
    - [x] BS/CR/LF/HT 处理 (解决双重回显和光标错位)
    - [x] CSI 参数解析修复 (支持 `?` 私有模式)
- [x] **滚动缓冲区 (Scrollback)**: 支持历史输出存储和 Shift+PgUp/PgDn 查看历史
- [x] **Resize 处理**: 
    - [x] 滑动屏幕以保持光标位置
    - [x] 优化 resize 时的重绘逻辑
    - [x] PTY resize 通知
- [x] **配置重载**: 支持运行时重载配置 (SIGHUP 信号)
 - [x] **鼠标支持**:
     - [x] 鼠标点击报告 (X10, URXVT, SGR pixel mode 1006)
     - [x] 鼠标滚轮滚动
- [x] **URL 点击打开**:
     - [x] URL 自动检测（http://, https://, ftp://）
     - [x] Ctrl+点击打开 URL（通过 xdg-open）
- [x] **打印/导出功能**:
     - [x] 打印屏幕内容（Shift+Print - printscreen）
     - [x] 打印选择内容（Print - printsel）
     - [x] 切换自动打印模式（Ctrl+Print - toggleprinter）

## 🚧 进行中 / 待修复

## 📋 待办事项 (Backlog)

### 核心功能 (对比 st)
- [ ] **光标闪烁**: 实现光标闪烁逻辑 (st `x.c` 中的 `xdrawcursor`)

### 高级特性
- [ ] **Box Drawing 完整支持**: 目前仅实现了单线字符，需扩展到双线、圆角等
- [ ] **TrueColor**: 确认 24 位真彩色支持的完整性
- [ ] **透明度**: X11 Alpha 通道支持

### 代码质量
- [ ] **测试**: 增加单元测试覆盖率 (Parser, Screen)
- [ ] **文档**: 完善模块文档注释
- [ ] **错误处理**: 更优雅的错误恢复机制

## 已知问题

1. **Resize 闪烁**: 调整窗口大小时可能会有短暂的黑屏或闪烁。
2. **IME 支持**: 尚未实现 XIM/XIC 输入法支持。
