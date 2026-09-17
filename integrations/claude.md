# Claude Code 接入

本地 Claude Code 的工具执行失败时，hook 会把真实错误发送给本机 FlyBug。无需上传代码；需要 Python 3，以及同时运行的 FlyBug.app。

1. 保留 FlyBug 整个文件夹，确保 `integrations/claude-hook.py` 旁的 `../bridge/flybug.py` 存在。
2. 打开 `claude-hooks.example.json`，将两处 `/ABSOLUTE/PATH/FlyBug` 替换为实际绝对路径。路径外的引号应保留；Python 不在 Claude Code 的 PATH 中时，把 `python3` 也改成它的绝对路径。
3. 将示例中的两个事件条目**追加合并**到已有配置的 `hooks` 中。推荐先使用项目内的 `.claude/settings.local.json`；若要覆盖所有项目，可使用 `~/.claude/settings.json`。保留已有事件数组、其他 hooks 和所有无关设置，不要用示例覆盖整个文件。文件尚不存在时，才以修改后的示例创建它。
4. 在该项目中重新开启 Claude Code 会话，并通过 `/hooks` 检查这两个条目已加载。让 Claude Code 运行一个项目里已有的失败测试；FlyBug 控制页面应出现来源为 `claude-code:…` 的诊断。

此交付没有修改你的 Claude Code 配置。删除添加的这两个条目即可停用接入；删除前保留其他 hooks。

## 报告范围与行为

- `PostToolUseFailure` 是主要入口：读取官方定义的顶层 `error`、`tool_name`、`tool_input`、`session_id` 和 `cwd`，跳过 `is_interrupt: true`。从错误堆栈／编译器输出提取文件与行号；文件操作失败时也可保留 `tool_input.file_path`，但不会猜测代码行。
- 官方把 `PostToolUse` 定义为工具执行成功。其 Bash 响应包含 `stdout`、`stderr`、`interrupted`、`isImage`，**并不保证退出码字段**。示例中的第二个 hook 仅用于兼容实际携带整数 `exit_code`／`exitCode` 的版本或适配器，只在该值非零时报告。它不会根据正常输出中出现的 “error” 等单词生成诊断。
- 不会把任意工具输出当成逻辑问题。逻辑缺陷需要测试、检查器或代码工具明确确认后主动报告。
- 使用 `async: true`，不等待 FlyBug 才继续编码。脚本不输出 Claude 决策或修改工具结果；无论应用离线、输入无效还是超时，都以 0 退出且不输出内容。桥接连接超时为 2 秒，整个 hook 自带 3 秒期限，输入最多 256 KiB，每次最多 10 条诊断。
- 无关工具成功不会清空之前的失败；记录由 FlyBug 更新或过期。只有可见且能确认的位置才会吸引苍蝇，没有行号时不会凭空定位。
- 这是本机集成。运行在远端服务器／云端的 Claude Code 无法通过它连接你 Mac 的 `127.0.0.1`。

依据：[Claude Code 官方 hooks 参考](https://code.claude.com/docs/en/hooks)，尤其是 [PostToolUseFailure](https://code.claude.com/docs/en/hooks#posttoolusefailure)、[PostToolUse](https://code.claude.com/docs/en/hooks#posttooluse) 和 [后台运行 hooks](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)。
