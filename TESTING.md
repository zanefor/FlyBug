# 验证记录

本文只记录可重复的自动化检查和已经确认的边界，不把内置试写窗口当作跨应用证据。

## 自动化检查

在本机重新构建后运行：

```sh
./build.sh
./FlyBug.app/Contents/MacOS/FlyBug --self-test
python3 -m unittest discover -s tests -p 'test_*.py' -v
node --check extension/extension.js
node extension/test_extension.js
codesign --verify --deep --strict FlyBug.app
```

这些检查覆盖原生诊断与坐标转换、文字规则、bridge 鉴权/错误解析、安装器幂等性、Claude hook 和 VS Code 扩展模拟宿主行为。`test_native_live.py` 只在 FlyBug.app 已启动且发现 bridge 时运行；否则会跳过。

## 手动跨应用验证

启动 FlyBug 并授予辅助功能权限后，在普通 Chrome input/textarea 中输入 `This is is a sentence.` 或 `sentnce`，停笔约 1 秒。然后运行：

```sh
python3 tests/observe_external.py --expect found --app "Google Chrome" --timeout 30
```

把文字修正后用 `--expect clear` 验证清除；密码框用 `--expect protected` 验证跳过。此脚本只读取 `/health`，不会代填输入。

VS Code 的真实验收需要安装 `extension/flybug-companion-0.1.0.vsix`，让 Python/TypeScript 语言服务在当前可见行产生错误，然后观察状态栏和 FlyBug 面板的来源/行号。扩展的离线模拟测试不等同于真实 VS Code 端到端验收；应记录实际编辑器版本、诊断文本、`currentSource` 和目标坐标。

微信使用独立的窄底部编辑条 OCR 兼容路径，只在真实输入事件后运行，不读取聊天记录。验收时应点击微信消息输入框并输入拼写错误，确认 `textStatus` 变为微信发现问题且 `flyTarget` 有坐标；屏幕录制权限缺失时会保持不可用。

## 诊断 bridge 验收

使用真实文件和行号发送一条确认过的问题：

```sh
python3 bridge/flybug.py report --file /absolute/path/example.py --line 3 \
  --message 'integration verification'
python3 bridge/flybug.py status
```

健康状态应显示 `currentSource=bridge`、`writingIssueCount` 与 `writingTargetCount`（若前台文件可见且权限完整）。测试后运行 `python3 bridge/flybug.py clear`。VS Code 扩展、Codex skill 和 Claude hook 都应只向这个 bridge 发请求，应用进程数仍只有一个 FlyBug.app。

## 当前已知限制

- macOS 权限无法由测试自动开启；首次运行必须在系统设置中手动允许。
- 屏幕观察是启发式，会漏掉遮挡、折叠或非标准主题中的错误。
- 没有可靠文件、行号或坐标时只记录诊断，不移动苍蝇。
- 程序不能自动理解所有逻辑错误；逻辑问题必须来自失败测试、语言服务或用户/工具明确上报。
- 本机已安装 VS Code 1.137.0 的 FlyBug 扩展，状态栏显示已连接，真实 bridge 上报已确认；错误行定位使用 OCR 模糊匹配并在无法匹配时回退到窗口级目标。微信窄编辑条路径已编译并纳入应用，仍需在微信输入框实际输入一次来确认 OCR 结果。
