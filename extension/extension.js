'use strict';

const vscode = require('vscode');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');

const source = `vscode:${vscode.env.appName}:${crypto.randomBytes(8).toString('hex')}`;
let timer;
let heartbeat;
let status;
let running = false;
let currentSend;
let queued = false;
let stopped = false;
let focused = vscode.window.state.focused;
let manualIssues = [];

function config() { return vscode.workspace.getConfiguration('flybug'); }

async function sendSnapshot(diagnostics) {
  const file = config().get('bridgeFile') || process.env.FLYBUG_BRIDGE_FILE ||
    path.join(os.homedir(), 'Library', 'Application Support', 'FlyBug', 'bridge.json');
  const discovery = JSON.parse(await fs.readFile(file, 'utf8'));
  if (!Number.isInteger(discovery.port) || discovery.port < 1 || discovery.port > 65535 ||
      typeof discovery.token !== 'string' || !discovery.token || /[\r\n]/.test(discovery.token)) {
    throw new Error('无效的 FlyBug 本地连接信息');
  }
  const body = JSON.stringify({ source, replace: true, diagnostics });
  await new Promise((resolve, reject) => {
    const request = http.request({
      host: '127.0.0.1', port: discovery.port, path: '/diagnostics', method: 'POST',
      headers: { 'Authorization': `Bearer ${discovery.token}`, 'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body) }
    }, response => {
      response.resume();
      response.on('error', reject);
      response.on('end', () => response.statusCode === 200 ? resolve() : reject(new Error(`HTTP ${response.statusCode}`)));
    });
    request.setTimeout(2000, () => request.destroy(new Error('连接超时')));
    request.on('error', reject);
    request.end(body);
  });
}

function visible(editor, line) {
  return editor.visibleRanges.some(range => line >= range.start.line && line <= range.end.line);
}

function asDiagnostic(editor, diagnostic, kind) {
  const line = diagnostic.range.start.line;
  const message = diagnostic.message.slice(0, 2000);
  const identity = [editor.document.uri.toString(), line, diagnostic.range.start.character, message, kind].join('\n');
  return {
    id: crypto.createHash('sha256').update(identity).digest('hex').slice(0, 24),
    source, message, severity: kind,
    file: editor.document.uri.scheme === 'file' ? editor.document.uri.fsPath : editor.document.uri.path,
    line: line + 1, column: diagnostic.range.start.character + 1,
    lineText: editor.document.lineAt(line).text.slice(0, 1000)
  };
}

function snapshot() {
  const editor = vscode.window.activeTextEditor;
  if (stopped || !focused || !config().get('enabled', true) || !editor || editor.document.isClosed) return [];
  const warnings = config().get('includeWarnings', true);
  const items = vscode.languages.getDiagnostics(editor.document.uri)
    .filter(item => (item.severity === vscode.DiagnosticSeverity.Error ||
      (warnings && item.severity === vscode.DiagnosticSeverity.Warning)) &&
      item.range.start.line < editor.document.lineCount && visible(editor, item.range.start.line))
    .sort((a, b) => a.severity - b.severity || a.range.start.line - b.range.start.line)
    .slice(0, 20)
    .map(item => asDiagnostic(editor, item, item.severity === vscode.DiagnosticSeverity.Error ? 'error' : 'warning'));
  for (const issue of manualIssues) {
    if (issue.uri === editor.document.uri.toString() && issue.range.start.line < editor.document.lineCount &&
        visible(editor, issue.range.start.line)) {
      items.push(asDiagnostic(editor, issue, 'warning'));
    }
  }
  return items.sort((a, b) => (a.severity === 'error' ? 0 : 1) - (b.severity === 'error' ? 0 : 1)).slice(0, 20);
}

async function publish() {
  if (stopped) return;
  if (running) { queued = true; return; }
  running = true;
  try {
    currentSend = sendSnapshot(snapshot());
    await currentSend;
    if (status) {
      status.text = '$(bug) FlyBug';
      status.tooltip = '已连接本机 FlyBug · 只报告当前可见代码的诊断';
    }
  } catch (_) {
    if (status) {
      status.text = '$(bug) FlyBug 离线';
      status.tooltip = '请先启动 FlyBug 桌面应用。点击重新连接。';
    }
  } finally {
    running = false;
    currentSend = undefined;
    if (queued && !stopped) { queued = false; void publish(); }
  }
}

function schedule() {
  clearTimeout(timer);
  timer = setTimeout(() => void publish(), 200);
}

function activate(context) {
  stopped = false;
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 0);
  status.command = 'flybug.reconnect';
  status.text = '$(bug) FlyBug';
  status.show();
  context.subscriptions.push(status,
    vscode.languages.onDidChangeDiagnostics(schedule),
    vscode.window.onDidChangeActiveTextEditor(schedule),
    vscode.window.onDidChangeTextEditorVisibleRanges(schedule),
    vscode.window.onDidChangeWindowState(state => { focused = state.focused; schedule(); }),
    vscode.workspace.onDidChangeConfiguration(event => { if (event.affectsConfiguration('flybug')) schedule(); }),
    vscode.workspace.onDidChangeTextDocument(event => {
      manualIssues = manualIssues.filter(issue => issue.uri !== event.document.uri.toString());
      schedule();
    }),
    vscode.workspace.onDidCloseTextDocument(document => {
      manualIssues = manualIssues.filter(issue => issue.uri !== document.uri.toString());
      schedule();
    }),
    vscode.commands.registerCommand('flybug.reconnect', async () => { await publish(); }),
    vscode.commands.registerCommand('flybug.clearLogicIssues', () => { manualIssues = []; schedule(); }),
    vscode.commands.registerCommand('flybug.reportLogicIssue', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) return;
      const range = new vscode.Range(editor.selection.start, editor.selection.start);
      const uri = editor.document.uri.toString();
      const version = editor.document.version;
      const message = await vscode.window.showInputBox({
        title: '标记已确认的逻辑问题',
        prompt: '描述这行代码的问题。FlyBug 负责定位，不会自动判断程序逻辑。',
        placeHolder: '例如：边界条件遗漏，空数组时访问了不存在的元素',
        validateInput: value => value.trim() ? undefined : '请填写问题描述'
      });
      if (!message || editor.document.isClosed || editor.document.version !== version) return;
      manualIssues = manualIssues.filter(issue => issue.uri !== uri || issue.range.start.line !== range.start.line);
      manualIssues.push({ uri, range, message: `逻辑问题：${message.trim()}` });
      schedule();
    })
  );
  heartbeat = setInterval(() => void publish(), 5000);
  schedule();
}

async function deactivate() {
  stopped = true;
  clearTimeout(timer);
  clearInterval(heartbeat);
  // Complete a pending snapshot before clearing so it cannot resurrect stale diagnostics.
  try { if (currentSend) await currentSend; } catch (_) { /* Connection may have closed. */ }
  try { await sendSnapshot([]); } catch (_) { /* App may already have exited. */ }
}

module.exports = { activate, deactivate };
