'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  nativeImage,
  screen,
  Tray
} = require('electron');
const core = require('./core');

const argv = process.argv;
const HOOK_FLAG = '--codex-claude-signal-hook';

function argumentValue(name) {
  const index = argv.indexOf(name);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : undefined;
}

function readHookPayload() {
  try {
    const input = fs.readFileSync(0, 'utf8').trim();
    return input ? JSON.parse(input) : {};
  } catch {
    return {};
  }
}

function runCommandLineMode() {
  if (argv.includes(HOOK_FLAG)) {
    try {
      const agent = argumentValue('--agent');
      if (![core.AGENT_CODEX, core.AGENT_CLAUDE, core.AGENT_CURSOR].includes(agent)) process.exit(0);
      const payload = readHookPayload();
      if (!payload.session_id && argumentValue('--session')) payload.session_id = argumentValue('--session');
      if (!payload.cwd && argumentValue('--cwd')) payload.cwd = argumentValue('--cwd');
      const signal = core.mapHookPayload(payload, agent, argumentValue('--event'));
      core.writeSignal(signal);
      if (agent === core.AGENT_CURSOR) process.stdout.write('{}\n');
    } catch {
      // Lifecycle reporting must never break the agent command that invoked it.
    }
    process.exit(0);
  }

  try {
    if (argv.includes('--install-hooks')) {
      core.installHooks(process.execPath);
      process.exit(0);
    }
    if (argv.includes('--uninstall-hooks')) {
      core.uninstallHooks();
      process.exit(0);
    }
    if (argv.includes('--hook-status')) {
      process.stdout.write(`${JSON.stringify(core.hookStatus(process.execPath))}\n`);
      process.exit(0);
    }
  } catch {
    process.exit(1);
  }
}

runCommandLineMode();

let panelWindow;
let tray;
let monitorTimer;
let trayAnimationTimer;
let lastFingerprint = '';
let currentSignals = [];
let settings = core.loadSettings();
let suppressMove = false;
let positionSaveTimer;
let isQuitting = false;

function visibleSignals(now = new Date()) {
  return core.loadSignals()
    .filter((signal) => {
      if (signal.state !== core.STATES.OFFLINE) return true;
      const updated = new Date(signal.updated_at || 'invalid');
      return !Number.isNaN(updated.getTime()) && now.getTime() - updated.getTime() <= 3_000;
    })
    .sort((left, right) => {
      const priority = core.statePriority(core.displayState(right, now)) -
        core.statePriority(core.displayState(left, now));
      if (priority !== 0) return priority;
      const agentOrder = String(left.agent).localeCompare(String(right.agent));
      if (agentOrder !== 0) return agentOrder;
      return String(right.updated_at).localeCompare(String(left.updated_at));
    });
}

function publicSignals(signals, now = new Date()) {
  return signals.map((signal) => ({ ...signal, display_state: core.displayState(signal, now) }));
}

function aggregateState(now = new Date()) {
  let best = core.STATES.OFFLINE;
  for (const signal of currentSignals) {
    const state = core.displayState(signal, now);
    if (core.statePriority(state) > core.statePriority(best)) best = state;
  }
  return best;
}

function displayForPoint(point) {
  return screen.getDisplayNearestPoint({ x: Math.round(point.x), y: Math.round(point.y) });
}

function constrainBounds(bounds, display) {
  return core.constrainBounds(bounds, display.workArea);
}

function desiredPanelBounds(signals = currentSignals) {
  const oldBounds = panelWindow?.getBounds() || { x: 0, y: 0, width: 294, height: 100 };
  const point = settings.panelPosition || screen.getCursorScreenPoint();
  const display = displayForPoint(point);
  const rowHeight = settings.lampMode === 3 ? 124 : 88;
  const height = Math.min(display.workArea.height - 24, Math.max(rowHeight, signals.length * rowHeight) + 14);
  const width = 294;
  const initial = settings.panelPosition
    ? { x: settings.panelPosition.x, y: settings.panelPosition.y, width, height }
    : {
        x: Math.round(display.workArea.x + (display.workArea.width - width) / 2),
        y: display.workArea.y + 7,
        width,
        height
      };
  if (panelWindow && settings.panelPosition) {
    initial.x = oldBounds.x;
    initial.y = oldBounds.y;
  }
  return constrainBounds(initial, display);
}

function updatePanelSize() {
  if (!panelWindow || panelWindow.isDestroyed()) return;
  suppressMove = true;
  panelWindow.setBounds(desiredPanelBounds(), false);
  suppressMove = false;
}

function savePanelPosition(position) {
  settings.panelPosition = { x: position.x, y: position.y };
  clearTimeout(positionSaveTimer);
  positionSaveTimer = setTimeout(() => core.saveSettings(settings), 120);
}

function handlePanelMove() {
  if (suppressMove || !panelWindow || panelWindow.isDestroyed()) return;
  const bounds = panelWindow.getBounds();
  const cursorDisplay = displayForPoint(screen.getCursorScreenPoint());
  const constrained = constrainBounds(bounds, cursorDisplay);
  if (constrained.x !== bounds.x || constrained.y !== bounds.y) {
    suppressMove = true;
    panelWindow.setBounds(constrained, false);
    suppressMove = false;
  }
  savePanelPosition(constrained);
}

function sendUiState() {
  if (!panelWindow || panelWindow.isDestroyed()) return;
  panelWindow.webContents.send('ui-state', {
    lampMode: settings.lampMode,
    signals: publicSignals(currentSignals)
  });
}

function monitorSignals() {
  const now = new Date();
  const signals = visibleSignals(now);
  const fingerprint = signals.map((signal) =>
    `${signal.agent}:${signal.session_id}:${signal.updated_at}:${core.displayState(signal, now)}`).join('|');
  if (fingerprint !== lastFingerprint) {
    lastFingerprint = fingerprint;
    currentSignals = signals;
    updatePanelSize();
    sendUiState();
    refreshTrayMenu();
  }
}

function createPanelWindow() {
  const platformMaterial = process.platform === 'win32'
    ? { backgroundMaterial: 'acrylic' }
    : { vibrancy: 'hud', visualEffectState: 'active' };
  panelWindow = new BrowserWindow({
    width: 294,
    height: 100,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    roundedCorners: true,
    hasShadow: false,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    show: false,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    },
    ...platformMaterial
  });
  panelWindow.setAlwaysOnTop(true, 'floating');
  panelWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  panelWindow.loadFile(path.join(__dirname, 'index.html'));
  panelWindow.on('move', handlePanelMove);
  panelWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      panelWindow.hide();
    }
  });
  panelWindow.once('ready-to-show', () => {
    updatePanelSize();
    panelWindow.showInactive();
    sendUiState();
  });
}

function effectIntensity(effect, nowMs = Date.now()) {
  if (effect === 'off') return 0;
  if (effect === 'steady') return 1;
  if (effect === 'breathe') return 0.32 + 0.68 * ((Math.sin(nowMs * Math.PI * 2 / 1600) + 1) / 2);
  if (effect === 'slow-blink') return nowMs % 1000 < 580 ? 1 : 0.12;
  if (effect === 'fast-blink') return nowMs % 400 < 200 ? 1 : 0.1;
  return 1;
}

function trayImage() {
  const presentation = core.lampPresentation(aggregateState());
  const intensity = effectIntensity(presentation.effect);
  const colors = { red: '#f2302e', yellow: '#ffb81f', green: '#2ed164', off: '#787878' };
  const circles = settings.lampMode === 3
    ? ['red', 'yellow', 'green'].map((name, index) => {
        const active = name === presentation.color;
        return `<circle cx="${4 + index * 8}" cy="7" r="3" fill="${colors[name]}" fill-opacity="${active ? 0.42 + intensity * 0.58 : 0.2}"/>`;
      }).join('')
    : `<circle cx="7" cy="7" r="5" fill="${colors[presentation.color] || colors.off}" fill-opacity="${presentation.color === 'off' ? 0.25 : 0.42 + intensity * 0.58}"/>`;
  const width = settings.lampMode === 3 ? 24 : 14;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="14" viewBox="0 0 ${width} 14">${circles}</svg>`;
  return nativeImage.createFromDataURL(`data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`);
}

function showMessage(title, detail) {
  dialog.showMessageBox({ type: 'info', title, message: title, detail, buttons: ['好'] });
}

function setLampMode(mode) {
  settings.lampMode = mode === 3 ? 3 : 1;
  core.saveSettings(settings);
  updatePanelSize();
  sendUiState();
  refreshTrayMenu();
  if (tray) tray.setImage(trayImage());
}

function resetPanelPosition() {
  const display = displayForPoint(screen.getCursorScreenPoint());
  const width = 294;
  settings.panelPosition = {
    x: Math.round(display.workArea.x + (display.workArea.width - width) / 2),
    y: display.workArea.y + 7
  };
  core.saveSettings(settings);
  updatePanelSize();
  panelWindow.showInactive();
}

function togglePanel() {
  if (panelWindow.isVisible()) panelWindow.hide();
  else panelWindow.showInactive();
  refreshTrayMenu();
}

function installHooks() {
  try {
    core.installHooks(process.execPath);
    showMessage('状态连接已安装', '请新开 Codex、Claude Code 和 Cursor 会话。Codex 首次加载时还需要确认 Hook 信任。');
  } catch (error) {
    showMessage('无法安装状态连接', error.message);
  }
}

function uninstallHooks() {
  try {
    core.uninstallHooks();
    showMessage('状态连接已卸载', '现有会话不受影响，新会话将不再上报状态。');
  } catch (error) {
    showMessage('无法卸载状态连接', error.message);
  }
}

function sessionMenuItems() {
  if (currentSignals.length === 0) return [{ label: '无活动会话', enabled: false }];
  return currentSignals.map((signal) => {
    const project = String(signal.cwd || '').split(/[\\/]/u).filter(Boolean).pop() || '未知项目';
    const title = signal.task_title || project;
    return { label: `${title} · ${core.stateTitle(core.displayState(signal))}`, enabled: false };
  });
}

function buildTrayMenu() {
  return Menu.buildFromTemplate([
    ...sessionMenuItems(),
    { type: 'separator' },
    { label: '安装/修复状态连接', click: installHooks },
    { label: '卸载状态连接', click: uninstallHooks },
    { label: '显示顶部指示灯', type: 'checkbox', checked: panelWindow?.isVisible() || false, click: togglePanel },
    {
      label: '指示灯样式',
      submenu: [
        { label: '单灯', type: 'radio', checked: settings.lampMode === 1, click: () => setLampMode(1) },
        { label: '三灯', type: 'radio', checked: settings.lampMode === 3, click: () => setLampMode(3) }
      ]
    },
    { label: '重置窗口位置', click: resetPanelPosition },
    {
      label: '清除历史灯组',
      click: () => {
        core.clearSignals();
        lastFingerprint = '';
        monitorSignals();
      }
    },
    { type: 'separator' },
    {
      label: '退出',
      click: () => {
        isQuitting = true;
        app.quit();
      }
    }
  ]);
}

function refreshTrayMenu() {
  if (tray) tray.setContextMenu(buildTrayMenu());
}

function createTray() {
  tray = new Tray(trayImage());
  tray.setToolTip('Codex / Claude Code / Cursor 状态');
  tray.setContextMenu(buildTrayMenu());
  tray.on('click', togglePanel);
}

ipcMain.handle('get-ui-state', () => ({ lampMode: settings.lampMode, signals: publicSignals(currentSignals) }));

const hasLock = app.requestSingleInstanceLock();
if (!hasLock) {
  app.quit();
} else {
  app.on('second-instance', () => panelWindow?.showInactive());
  app.whenReady().then(() => {
    if (process.platform === 'win32') app.setAppUserModelId('local.codex-claude-signal');
    if (process.platform === 'darwin') app.dock?.hide();
    currentSignals = visibleSignals();
    createPanelWindow();
    createTray();
    monitorTimer = setInterval(monitorSignals, 250);
    trayAnimationTimer = setInterval(() => tray?.setImage(trayImage()), 200);
  });
}

app.on('window-all-closed', () => {});
app.on('before-quit', () => {
  isQuitting = true;
  clearInterval(monitorTimer);
  clearInterval(trayAnimationTimer);
  clearTimeout(positionSaveTimer);
});
