'use strict';
// Test the real activation and HTTP flow with a minimal VS Code API fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

async function main() {
  const records = [];
  const server = http.createServer((request, response) => {
    let body = '';
    request.on('data', chunk => body += chunk);
    request.on('end', () => {
      records.push({ auth: request.headers.authorization, body: JSON.parse(body) });
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end('{"ok":true}');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const temp = await fsp.mkdtemp(path.join(os.tmpdir(), 'flybug-extension-'));
  const discovery = path.join(temp, 'bridge.json');
  await fsp.writeFile(discovery, JSON.stringify({ port: server.address().port, token: 'test-token' }));
  const events = {}, commands = {};
  const settings = { enabled: true, includeWarnings: true, bridgeFile: discovery };
  const on = name => callback => { events[name] = callback; return { dispose() {} }; };
  const uri = { scheme: 'file', fsPath: '/project/demo.ts', toString: () => 'file:///project/demo.ts' };
  const lineTexts = ['manual issue here', 'bad = value', 'unused = 2', 'offscreen error'];
  const editor = { document: { uri, version: 1, lineCount: 4, isClosed: false, lineAt: line => ({ text: lineTexts[line] }) },
    visibleRanges: [{ start: { line: 0 }, end: { line: 2 } }], selection: { start: { line: 0, character: 0 } } };
  const diagnostics = [
    { severity: 1, range: { start: { line: 2, character: 0 } }, message: 'Unused variable' },
    { severity: 0, range: { start: { line: 1, character: 2 } }, message: 'Unknown symbol' },
    { severity: 0, range: { start: { line: 3, character: 0 } }, message: 'Offscreen' }
  ];
  const vscode = {
    env: { appName: 'Test Code' }, DiagnosticSeverity: { Error: 0, Warning: 1 }, StatusBarAlignment: { Right: 2 },
    Range: class { constructor(start, end) { this.start = start; this.end = end; } },
    workspace: {
      getConfiguration: () => ({ get: (key, fallback) => settings[key] === undefined ? fallback : settings[key] }),
      onDidChangeConfiguration: on('configuration'), onDidChangeTextDocument: on('text'), onDidCloseTextDocument: on('close')
    },
    languages: { getDiagnostics: () => diagnostics, onDidChangeDiagnostics: on('diagnostics') },
    window: {
      state: { focused: true }, activeTextEditor: editor,
      createStatusBarItem: () => ({ show() {}, dispose() {} }),
      onDidChangeActiveTextEditor: on('active'), onDidChangeTextEditorVisibleRanges: on('visible'), onDidChangeWindowState: on('focus'),
      showInputBox: async () => 'This condition misses zero'
    },
    commands: { registerCommand: (id, fn) => { commands[id] = fn; return { dispose() {} }; } }
  };
  const moduleFixture = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'extension.js'), 'utf8'), {
    require: name => name === 'vscode' ? vscode : require(name), module: moduleFixture,
    process, Buffer, setTimeout, clearTimeout, setInterval, clearInterval
  }, { filename: 'extension.js' });
  const extension = moduleFixture.exports;
  const until = async predicate => {
    const deadline = Date.now() + 3000;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error('Timed out waiting for local snapshot');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  };
  try {
    extension.activate({ subscriptions: [] });
    await until(() => records.length > 0);
    let item = records.at(-1);
    assert.equal(item.auth, 'Bearer test-token');
    assert.equal(item.body.replace, true);
    assert.ok(item.body.source.startsWith('vscode:Test Code:'));
    assert.equal(item.body.diagnostics.length, 2);
    assert.deepEqual(Array.from(item.body.diagnostics, issue => issue.severity), ['error', 'warning']);
    assert.equal(item.body.diagnostics[0].line, 2);
    assert.equal(item.body.diagnostics[0].column, 3);
    assert.equal(item.body.diagnostics[0].lineText, 'bad = value');
    const stableId = item.body.diagnostics[0].id;
    await commands['flybug.reconnect']();
    assert.equal(records.at(-1).body.diagnostics[0].id, stableId);

    const count = records.length;
    events.focus({ focused: false });
    await until(() => records.length > count);
    assert.equal(records.at(-1).body.diagnostics.length, 0);
    events.focus({ focused: true });
    settings.includeWarnings = false;
    await commands['flybug.reconnect']();
    assert.equal(records.at(-1).body.diagnostics.length, 1);

    await commands['flybug.reportLogicIssue']();
    await commands['flybug.reconnect']();
    assert.equal(records.at(-1).body.diagnostics.length, 2);
    assert.ok(records.at(-1).body.diagnostics[1].message.includes('This condition misses zero'));
    events.text({ document: editor.document });
    await commands['flybug.reconnect']();
    assert.equal(records.at(-1).body.diagnostics.length, 1);
    await extension.deactivate();
    assert.equal(records.at(-1).body.diagnostics.length, 0);
    console.log('PASS: visible filtering, severity order, stable IDs, loopback auth, focus clearing, manual issue lifecycle, shutdown clearing');
  } finally {
    await extension.deactivate();
    await new Promise(resolve => server.close(resolve));
    await fsp.rm(temp, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
