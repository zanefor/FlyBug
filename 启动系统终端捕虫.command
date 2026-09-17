#!/bin/bash
set -euo pipefail
FLYBUG_ROOT="$(cd "$(dirname "$0")" && pwd)"
# FlyBug itself is the single resident process.  The app observes the real
# Terminal/Codex/Claude/editor windows through Accessibility and Screen
# Capture; no second shell or relay process is inserted between the user and
# the system terminal.
/usr/bin/open "$FLYBUG_ROOT/FlyBug.app"
echo "FlyBug 已启动。请在任意系统终端、Codex、Claude Code 或编辑器中照常输入和运行命令。"
echo "错误会由同一个 FlyBug 进程接收并定位；此窗口可直接关闭。"
