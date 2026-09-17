#!/bin/bash
set -euo pipefail
FLYBUG_ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "为当前用户安装 FlyBug 诊断技能，并合并 Claude Code 失败事件 hook。"
echo "已有配置会保留；发生修改前会备份。"
python3 "$FLYBUG_ROOT/integrations/install.py" --apply --tool all
echo "完成后请重启 Codex / Claude Code，或开启新会话。"
echo "按回车关闭此窗口。"
read -r
