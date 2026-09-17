(() => {
  'use strict';
  const nativeBridge = window.webkit?.messageHandlers?.flybug;
  const preview = !nativeBridge;
  const byId = (id) => document.getElementById(id);
  let state = {
    running: false,
    settings: {size: 28, speed: 1, opacity: .9, idleFlight: true, includeWarnings: false, screenMonitoring: false, scanInterval: 3, textChecking: true, checkSpelling: true, textLanguage: 'auto'},
    permissions: {accessibility: false, screen: false},
    bridge: {port: 0, connected: false, status: '等待本地接口'},
    status: preview ? '当前是浏览器界面预览，设置仅用于演示。' : '正在连接本地应用…',
    textStatus: preview ? '浏览器预览：未读取输入文字，需在本地应用中检查。' : '正在连接文字检查…',
    diagnostic: null,
    events: [],
    version: '1.2.0'
  };
  let toastTimer;
  const sliderLabels = {size: (v) => `${Math.round(v)} px`, speed: (v) => `${Number(v).toFixed(1)} ×`, opacity: (v) => `${Math.round(v * 100)} %`};

  function toast(message) {
    byId('toast').textContent = message;
    byId('toast').hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { byId('toast').hidden = true; }, 3300);
  }

  function addPreviewEvent(message, severity = 'info') {
    state.events.unshift({time: new Date().toLocaleTimeString('zh-CN', {hour12: false}), message, severity});
    state.events = state.events.slice(0, 20);
  }

  function send(action, payload = {}) {
    if (nativeBridge) {
      try { nativeBridge.postMessage({action, ...payload}); }
      catch { toast('暂时无法连接本地应用，请重新打开 FlyBug。'); }
      return;
    }
    if (action === 'ready') return;
    if (action === 'settings') {
      state.settings = {...state.settings, ...payload.settings};
      state.status = '浏览器预览：设置仅在当前页面生效。';
      state.textStatus = state.settings.textChecking ? '浏览器预览：未读取输入文字，需在本地应用中检查。' : '文字检查已关闭。';
    } else if (action === 'toggleRunning') {
      state.running = !state.running;
      state.status = state.running ? '预览：苍蝇已放飞。桌面效果需在本地应用中体验。' : '预览：飞行已暂停。';
      addPreviewEvent(state.running ? '预览飞行已开始' : '预览飞行已暂停');
    } else if (action === 'demo') {
      state.running = true;
      state.diagnostic = {message: '示例：Cannot find name “userName”', source: '试飞演示', severity: 'error', file: 'demo.ts', line: 12};
      state.status = '浏览器预览：这是一条演示诊断，未读取任何编辑器内容。';
      addPreviewEvent('演示定位 · demo.ts:12', 'error');
    } else if (action === 'writingDemo') {
      state.running = true;
      state.diagnostic = {message: '示例：建议将 “a apple” 改为 “an apple”', source: 'writing', severity: 'warning', line: 1};
      state.status = '浏览器预览：这是一条文字检查示例，并非实际检查结果。';
      state.textStatus = '请在 FlyBug.app 中打开可编辑的试写窗口。';
      addPreviewEvent('文字检查示例 · a apple → an apple', 'warning');
      toast('浏览器仅显示示例。本地应用会打开可编辑的试写窗口。');
    } else if (action === 'clear') {
      state.diagnostic = null;
      state.events = [];
      state.status = '预览记录已清空。';
    } else if (action === 'permission') {
      toast('请从 FlyBug.app 中开启 macOS 权限。');
    } else if (action === 'copyBridgeCommand') {
      toast('请启动 FlyBug.app 后复制本地接口接入示例。');
    } else if (action === 'openDataFolder') {
      toast('请在 FlyBug.app 中打开配置目录。');
    } else if (action === 'quit') {
      toast('这是浏览器预览，关闭当前页面即可退出。');
    }
    render();
  }

  function updateRange(id, value) {
    const input = byId(id);
    input.value = value;
    input.style.setProperty('--range', `${(Number(input.value) - Number(input.min)) / (Number(input.max) - Number(input.min)) * 100}%`);
    byId(`${id}-value`).textContent = sliderLabels[id](value);
  }

  function formatTime(value) {
    const text = String(value ?? '');
    if (/^\d{2}:\d{2}/.test(text)) return text;
    const parsed = new Date(text);
    return Number.isNaN(parsed.getTime()) ? text : parsed.toLocaleTimeString('zh-CN', {hour12: false});
  }

  function render() {
    const settings = state.settings;
    byId('preview-banner').hidden = !preview;
    byId('specimen').classList.toggle('is-running', !!state.running);
    byId('running-dot').classList.toggle('active', !!state.running);
    byId('running-status').textContent = preview ? (state.running ? '预览模式 · 正在飞行' : '预览模式 · 等待放飞')
      : !state.running ? '已暂停 · 飞行与检查均停止'
      : settings.textChecking && !state.permissions.accessibility ? '已放飞 · 文字检查待授权'
      : '已放飞 · 检查已运行';
    byId('flight-caption').textContent = state.running ? (state.diagnostic ? '目标已发现' : '自由飞行中') : '静候放飞';
    byId('toggle-running').replaceChildren(document.createTextNode(state.running ? '暂停飞行 ' : '放出苍蝇 '));
    const toggleIcon = document.createElement('span');
    toggleIcon.setAttribute('aria-hidden', 'true');
    toggleIcon.textContent = state.running ? 'Ⅱ' : '↗';
    byId('toggle-running').append(toggleIcon);
    byId('toggle-running').setAttribute('aria-pressed', String(!!state.running));
    for (const id of Object.keys(sliderLabels)) updateRange(id, settings[id]);
    for (const id of ['idleFlight', 'includeWarnings', 'screenMonitoring', 'textChecking', 'checkSpelling']) byId(id).checked = !!settings[id];
    byId('checkSpelling').disabled = !settings.textChecking;
    byId('textLanguage').disabled = !settings.textChecking;
    byId('textLanguage').value = ['auto', 'en_US', 'zh_Hans'].includes(settings.textLanguage) ? settings.textLanguage : 'auto';
    const textBlockers = [];
    if (!state.running) textBlockers.push('已暂停：点击上方“放出苍蝇”恢复检查');
    if (!settings.textChecking) textBlockers.push('键盘输入检查已关闭');
    if (settings.textChecking && !state.permissions.accessibility) textBlockers.push('尚未授权：请在系统设置 → 隐私与安全性 → 辅助功能中允许 FlyBug');
    byId('text-status').textContent = preview ? state.textStatus : textBlockers.length ? textBlockers.join('。') : (state.textStatus || '等待文字检查状态…');
    byId('text-status').classList.toggle('needs-attention', !preview && textBlockers.length > 0);
    byId('spelling-status').hidden = !!settings.checkSpelling || !settings.textChecking;
    const interval = String(settings.scanInterval);
    if (![...byId('scanInterval').options].some((option) => option.value === interval)) {
      const option = document.createElement('option');
      option.value = interval;
      option.textContent = `每 ${interval} 秒`;
      byId('scanInterval').append(option);
    }
    byId('scanInterval').value = interval;

    const screenAllowed = !!state.permissions.screen;
    byId('permission-summary').textContent = preview ? '启动应用后可授权' : screenAllowed ? '屏幕录制权限已允许' : '屏幕录制权限未开启';
    byId('permission-indicator').className = `permission-indicator${screenAllowed ? ' enabled' : settings.screenMonitoring ? ' partial' : ''}`;
    byId('screen-permission').textContent = screenAllowed ? '已授权' : '开启权限 ↗';
    byId('screen-permission').disabled = screenAllowed;
    byId('accessibility-permission').textContent = state.permissions.accessibility ? '辅助功能已授权' : '辅助功能权限 ↗';
    byId('accessibility-permission').disabled = !!state.permissions.accessibility;
    byId('text-permission').textContent = state.permissions.accessibility ? '辅助功能已授权' : '辅助功能权限 ↗';
    byId('text-permission').disabled = !!state.permissions.accessibility;
    byId('bridge-dot').classList.toggle('active', !!state.bridge.connected);
    byId('bridge-status').textContent = preview ? '浏览器预览 · 本地接口未连接' : String(state.bridge.status || (state.bridge.connected ? '本地接口已连接' : '等待本地接口'));
    byId('bridge-address').textContent = `127.0.0.1:${state.bridge.port || '—'}`;
    byId('native-status').textContent = state.status || '';
    byId('version').textContent = `v${state.version || '1.2.0'}`;

    const diagnostic = state.diagnostic;
    const warning = diagnostic && diagnostic.severity === 'warning';
    const writing = diagnostic && ['writing', 'writing-demo'].includes(diagnostic.source);
    byId('diagnostic').className = `diagnostic${diagnostic ? warning ? ' has-warning' : ' has-error' : ''}`;
    byId('diagnostic-icon').textContent = diagnostic ? '!' : '·';
    byId('diagnostic-message').textContent = diagnostic ? String(diagnostic.message || '发现一条诊断') : '还没有发现问题';
    byId('diagnostic-tag').textContent = diagnostic ? writing ? 'TEXT' : warning ? 'WARNING' : 'DETECTED' : 'WAITING';
    byId('diagnostic-location').textContent = diagnostic
      ? [writing ? '文字检查' : diagnostic.source, diagnostic.file ? `${diagnostic.file}${diagnostic.line ? `:${diagnostic.line}` : ''}` : diagnostic.line ? `第 ${diagnostic.line} 行` : '', diagnostic.target ? '已获得屏幕位置' : ''].filter(Boolean).join(' / ')
      : '输入文字进行检查，或连接编辑器诊断。';

    const events = Array.isArray(state.events) ? state.events.slice(0, 30) : [];
    byId('event-count').textContent = String(events.length);
    byId('activity-history').hidden = !events.length;
    const list = document.createDocumentFragment();
    for (const event of events) {
      const item = document.createElement('li');
      const time = document.createElement('time');
      time.textContent = formatTime(event.time);
      const message = document.createElement('span');
      message.textContent = String(event.message || '');
      item.append(time, message);
      list.append(item);
    }
    byId('event-list').replaceChildren(list);
  }

  window.flybugUpdate = (next) => {
    if (!next || typeof next !== 'object') return;
    state = {...state, ...next, settings: {...state.settings, ...(next.settings || {})}, permissions: {...state.permissions, ...(next.permissions || {})}, bridge: {...state.bridge, ...(next.bridge || {})}};
    render();
  };

  for (const id of Object.keys(sliderLabels)) {
    byId(id).addEventListener('input', (event) => {
      const value = Number(event.target.value);
      updateRange(id, value);
      send('settings', {settings: {[id]: value}});
    });
  }
  for (const id of ['idleFlight', 'includeWarnings', 'screenMonitoring', 'textChecking', 'checkSpelling']) {
    byId(id).addEventListener('change', (event) => send('settings', {settings: {[id]: event.target.checked}}));
  }
  byId('scanInterval').addEventListener('change', (event) => send('settings', {settings: {scanInterval: Number(event.target.value)}}));
  byId('textLanguage').addEventListener('change', (event) => send('settings', {settings: {textLanguage: event.target.value}}));
  for (const [id, action] of Object.entries({'toggle-running': 'toggleRunning', demo: 'demo', 'writing-demo': 'writingDemo', clear: 'clear', 'copy-command': 'copyBridgeCommand', 'open-data': 'openDataFolder', quit: 'quit'})) {
    byId(id).addEventListener('click', () => send(action));
  }
  byId('screen-permission').addEventListener('click', () => send('permission', {kind: 'screen'}));
  byId('accessibility-permission').addEventListener('click', () => send('permission', {kind: 'accessibility'}));
  byId('text-permission').addEventListener('click', () => send('permission', {kind: 'accessibility'}));
  render();
  send('ready');
})();
