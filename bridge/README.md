# FlyBug 命令桥接

仅依赖 Python 3 标准库。先启动 FlyBug 桌面应用，再从项目根目录运行：

```sh
python3 bridge/flybug.py status
python3 bridge/flybug.py run -- python3 /绝对路径/example.py
python3 bridge/flybug.py run -- npm test
python3 bridge/flybug.py run -- cargo check
```

`run` 实时保留原命令的标准输出、标准错误和退出码。非零退出时，从 Python 堆栈、JS/TS 堆栈、TypeScript 编译错误、Rust 编译位置中提取文件和行号；无可识别位置时只报告失败，不伪造位置。成功运行会清除同一来源的旧诊断。它适合测试/编译等非交互命令，标准输入连接到空设备，不用于交互式终端程序。每个输出流仅保留末尾 200 KB 用于解析，单行仅分析前 2,000 字符，实际显示的输出不截断。它不能覆盖每一种测试框架或日志格式。

## Codex / Claude Code / 终端交互

在已有交互终端中启动：

```sh
python3 bridge/flybug.py pty --source codex -- codex
python3 bridge/flybug.py pty --source claude -- claude
python3 bridge/flybug.py pty --source terminal -- zsh
```

对应命令需要原本已安装并能正常运行。`pty` 为它建立真实的本地终端，保留键盘交互、Ctrl-C、窗口尺寸变化和原命令退出码；退出时恢复原终端输入设置。可在 Codex、Claude Code 或编辑器集成终端中运行这些命令。它不修改这些工具的配置，也不安装系统组件。`pty` 需要真实的交互终端；管道输入会明确提示改用非交互的 `run`。

交互期间，每秒至多分析一次输出，只识别完整的 Python/JS 堆栈、编译错误位置、Rust 错误结构和 panic 等强信号。普通 AI 说明中的“error”字样、Markdown 代码围栏内的示例不会直接触发。终端文本本身不能证明其来源，重复打印的诊断仍可能触发；这不是自动逻辑审查。将明确的问题通过 `report` 上报最可靠。

诊断通过独立后台线程发送，连接等待不会卡住键盘或终端显示。退出成功时清除该来源，退出失败时保留已识别问题或上报退出码。在长期运行的 shell 中，内部命令打印的强错误信号会实时报告，无需退出 shell；后续命令成功不会立刻清除旧问题，它会约 45 秒后过期，也可显式执行 `clear --source NAME`。PTY 按终端语义合并标准输出和标准错误，保留末尾 200 KB 用于本地解析。已上报问题约 45 秒未更新后过期；成功退出也会立即请求清除。多开会话时给 `--source` 设置不同名称，例如 `codex-project-a`，避免相互清除。

## 明确上报问题

任何编辑器、AI 编码工具或脚本都可显式调用上报命令：

```sh
python3 bridge/flybug.py report --file /绝对路径/example.py --line 12 --message '空数组会触发越界'
python3 bridge/flybug.py report --file /绝对路径/example.py --line 12 --text 'return values[0]' --message '空数组会触发越界' --severity warning
python3 bridge/flybug.py clear
```

`--line`、`--column` 从 1 开始；`--text` 可传编辑器里尚未保存的准确行文本。若未传 `--text`，只读取本次明确指定/命令输出中指向的本地文件行（文件最大 2 MB），不扫描项目。单次最多报告 20 个解析到的问题，诊断描述最多 2,000 字符，行文本最多 1,000 字符。`--source NAME` 可隔离不同工具的诊断；默认来源为 `cli`，`clear --source NAME` 只清除该来源。

默认读取 `~/Library/Application Support/FlyBug/bridge.json`，也可设置环境变量 `FLYBUG_BRIDGE_FILE`。所有请求仅发往 `127.0.0.1`，携带本地认证令牌；服务断开时 `run` 仍返回原命令的退出码。桥接只传递工具已有诊断或人工/AI 已确认的问题，不自行推理程序逻辑。
