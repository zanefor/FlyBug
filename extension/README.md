# FlyBug Companion

将 VS Code 系列编辑器中**当前窗口、当前可见代码**的错误与警告发送给本机 FlyBug。适用于支持 VS Code 扩展 API 的 VS Code、Cursor、Windsurf；其他编辑器可以使用项目中的 Python 命令桥接。

## 安装

1. 先启动 FlyBug 桌面应用。
2. 在此项目根目录运行 `python3 extension/build_vsix.py`，生成 `extension/flybug-companion-0.1.0.vsix`。
3. 编辑器打开「扩展」，点击右上角 `…` →「从 VSIX 安装…」，选择该文件。也可在已配置命令行的编辑器中运行 `code --install-extension extension/flybug-companion-0.1.0.vsix`，Cursor 使用 `cursor --install-extension …`。
4. 打开存在错误的代码文件，保持出错行可见。状态栏显示 `FlyBug` 表示本机连接成功。

错误来源是编辑器已经产生的真实诊断：例如 Python/Pylance、TypeScript 或 ESLint 提供的提示。需要对应语言服务先正常工作。苍蝇能否精确落在代码行上，取决于 FlyBug 的辅助功能/屏幕定位权限和编辑器提供的可访问内容。

## 命令与设置

- `FlyBug: Reconnect`：立即重读本机连接信息。
- `FlyBug: Report Selection as Logic Issue`：选中问题行，填写人工或 AI 已确认的问题；编辑该文件后会自动清除手动标记。
- `FlyBug: Clear Manual Logic Issues`：清除手动问题。
- 设置 `flybug.enabled`：启用/停用报告。
- 设置 `flybug.includeWarnings`：是否报告警告。

扩展不会自动推理未被语言服务发现的逻辑错误。它只传递当前可见行的文件名、行号、行文本和诊断描述，不读取整个项目，不发送到云端。切换文件、滚动、失去窗口焦点时更新或清除当前来源；每 5 秒刷新一次，扩展退出后旧信息会自动过期。多个编辑器窗口使用不同来源标识，互不清除。

自定义发现文件可用设置 `flybug.bridgeFile` 或环境变量 `FLYBUG_BRIDGE_FILE`。默认位于 `~/Library/Application Support/FlyBug/bridge.json`，只连接 `127.0.0.1`，使用本机应用创建的认证令牌。
