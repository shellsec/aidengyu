'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const AGENT_CODEX = 'codex';
const AGENT_CLAUDE = 'claude';
const AGENT_CURSOR = 'cursor';

const STATES = Object.freeze({
  READY: 'ready',
  THINKING: 'thinking',
  WORKING: 'working',
  WAITING_INPUT: 'waiting_input',
  WAITING_APPROVAL: 'waiting_approval',
  ATTENTION: 'attention',
  COMPLETED: 'completed',
  FAILED: 'failed',
  BLOCKED: 'blocked',
  STALE: 'stale',
  OFFLINE: 'offline'
});

const CODEX_HOOK_EVENTS = Object.freeze([
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'PermissionRequest', 'SubagentStart', 'SubagentStop', 'Stop', 'SessionEnd'
]);

const CLAUDE_HOOK_EVENTS = Object.freeze([
  'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'PostToolUseFailure', 'PermissionRequest', 'Notification',
  'SubagentStart', 'SubagentStop', 'Stop', 'SessionEnd'
]);

const CURSOR_HOOK_EVENTS = Object.freeze([
  'sessionStart', 'beforeSubmitPrompt', 'preToolUse', 'postToolUse',
  'postToolUseFailure', 'subagentStart', 'subagentStop', 'preCompact',
  'stop', 'sessionEnd'
]);

const STATE_TITLES = Object.freeze({
  [STATES.READY]: '就绪',
  [STATES.THINKING]: '思考中',
  [STATES.WORKING]: '执行中',
  [STATES.WAITING_INPUT]: '等待回答',
  [STATES.WAITING_APPROVAL]: '等待授权',
  [STATES.ATTENTION]: '需要留意',
  [STATES.COMPLETED]: '已完成',
  [STATES.FAILED]: '执行失败',
  [STATES.BLOCKED]: '已阻塞',
  [STATES.STALE]: '状态过期',
  [STATES.OFFLINE]: '已退出'
});

function firstString(value, keys) {
  for (const key of keys) {
    if (typeof value?.[key] === 'string' && value[key].length > 0) return value[key];
  }
  return undefined;
}

function normalize(value) {
  return typeof value === 'string' ? value.toLowerCase().replace(/[^a-z0-9]/g, '') : '';
}

function stateTitle(state) {
  return STATE_TITLES[state] || '未知';
}

function statePriority(state) {
  if (state === STATES.BLOCKED) return 100;
  if (state === STATES.FAILED) return 90;
  if (state === STATES.WAITING_APPROVAL) return 80;
  if (state === STATES.WAITING_INPUT) return 70;
  if (state === STATES.ATTENTION || state === STATES.STALE) return 60;
  if (state === STATES.WORKING) return 50;
  if (state === STATES.THINKING) return 40;
  if (state === STATES.COMPLETED) return 30;
  if (state === STATES.READY) return 20;
  return 0;
}

function displayState(signal, now = new Date()) {
  const state = signal?.state || STATES.STALE;
  const updatedAt = new Date(signal?.updated_at || 'invalid');
  if (Number.isNaN(updatedAt.getTime())) return STATES.STALE;

  const ageMs = now.getTime() - updatedAt.getTime();
  if (state === STATES.COMPLETED && ageMs > 15_000) return STATES.READY;
  if (state === STATES.WAITING_APPROVAL && ageMs > 30_000) return STATES.ATTENTION;
  const terminal = new Set([STATES.OFFLINE, STATES.COMPLETED, STATES.FAILED, STATES.BLOCKED]);
  if (!terminal.has(state) && ageMs > 600_000) return STATES.STALE;
  return state;
}

function lampPresentation(state) {
  if (state === STATES.READY) return { color: 'green', effect: 'steady' };
  if (state === STATES.THINKING) return { color: 'green', effect: 'breathe' };
  if (state === STATES.WORKING) return { color: 'green', effect: 'slow-blink' };
  if (state === STATES.WAITING_INPUT) return { color: 'yellow', effect: 'slow-blink' };
  if (state === STATES.WAITING_APPROVAL) return { color: 'yellow', effect: 'fast-blink' };
  if (state === STATES.ATTENTION || state === STATES.STALE) return { color: 'yellow', effect: 'steady' };
  if (state === STATES.COMPLETED) return { color: 'green', effect: 'double-flash' };
  if (state === STATES.FAILED) return { color: 'red', effect: 'steady' };
  if (state === STATES.BLOCKED) return { color: 'red', effect: 'fast-blink' };
  return { color: 'off', effect: 'off' };
}

function constrainBounds(bounds, workArea, minimumVisible = 72) {
  return {
    ...bounds,
    x: Math.min(Math.max(bounds.x, workArea.x - bounds.width + minimumVisible),
      workArea.x + workArea.width - minimumVisible),
    y: Math.min(Math.max(bounds.y, workArea.y - bounds.height + minimumVisible),
      workArea.y + workArea.height - minimumVisible)
  };
}

function taskTitleFromPayload(payload) {
  const prompt = firstString(payload, ['prompt', 'user_prompt', 'userPrompt']);
  if (!prompt) return undefined;
  const firstLine = prompt.split(/\r?\n/u).map((line) => line.trim()).find(Boolean);
  if (!firstLine) return undefined;
  const clean = firstLine.replace(/\s+/gu, ' ').replace(/^[ #>*\-`\t]+|[ #>*\-`\t]+$/gu, '');
  if (!clean) return undefined;
  const characters = Array.from(clean);
  return characters.length > 36 ? `${characters.slice(0, 36).join('')}...` : clean;
}

function valueMeansFailure(value) {
  if (value === undefined || value === null || value === false || value === 0 || value === '') return false;
  return true;
}

function hasStructuredFailure(payload) {
  for (const key of ['error', 'failure', 'exception']) {
    if (valueMeansFailure(payload?.[key])) return true;
  }
  for (const key of ['exit_status', 'exitStatus', 'exit_code', 'exitCode']) {
    const value = payload?.[key];
    if (value !== undefined && Number(value) !== 0) return true;
  }
  for (const key of ['is_error', 'isError']) {
    if (payload?.[key] === true) return true;
  }
  const nested = payload?.tool_response || payload?.toolResponse;
  return nested && typeof nested === 'object' ? hasStructuredFailure(nested) : false;
}

function isHardBlock(payload, event) {
  const reason = firstString(payload, ['error', 'failure', 'reason', 'stop_reason', 'stopReason']) || '';
  const combined = `${normalize(event)}${normalize(reason)}`;
  return [
    'ratelimit', 'usagelimit', 'maxbudget', 'maxtokens', 'authentication',
    'unauthorized', 'forbidden', 'permissiondenied', 'blocked'
  ].some((term) => combined.includes(term));
}

function stateForEvent(eventName, payload = {}) {
  const event = normalize(eventName);
  const tool = normalize(firstString(payload, ['tool_name', 'toolName']) || '');
  const notification = normalize(firstString(payload, ['notification_type', 'notificationType', 'type']) || '');
  const status = normalize(firstString(payload, ['status']) || '');

  if (status === 'error' || hasStructuredFailure(payload) || event.includes('failure') || event.includes('error')) {
    return isHardBlock(payload, event) ? STATES.BLOCKED : STATES.FAILED;
  }
  if (event.includes('permissiondenied')) return STATES.BLOCKED;
  if (event === 'permissionrequest') return STATES.WAITING_APPROVAL;
  if (event === 'notification') {
    if (notification.includes('permission')) return STATES.WAITING_APPROVAL;
    if (notification.includes('idleprompt') || notification.includes('question')) return STATES.WAITING_INPUT;
    return STATES.ATTENTION;
  }
  if (event === 'pretooluse') {
    if (['askuserquestion', 'requestuserinput', 'elicitation'].some((term) => tool.includes(term))) {
      return STATES.WAITING_INPUT;
    }
    return STATES.WORKING;
  }
  if (event === 'sessionstart') return STATES.READY;
  if (event === 'userpromptsubmit' || event === 'userpromptexpansion' || event === 'beforesubmitprompt') {
    return STATES.THINKING;
  }
  if (event === 'subagentstop') return STATES.COMPLETED;
  if (new Set([
    'posttooluse', 'posttoolbatch', 'precompact', 'postcompact', 'subagentstart',
    'taskcreated', 'taskcompleted', 'worktreecreate', 'elicitationresult'
  ]).has(event)) return STATES.WORKING;
  if (new Set(['askuserquestion', 'requestuserinput', 'elicitation']).has(event)) return STATES.WAITING_INPUT;
  if (new Set(['configchange', 'cwdchanged', 'filechanged', 'instructionsloaded', 'worktreeremove']).has(event)) {
    return STATES.ATTENTION;
  }
  if (event === 'stop') return isHardBlock(payload, event) ? STATES.BLOCKED : STATES.COMPLETED;
  if (event === 'sessionend') return STATES.OFFLINE;
  return STATES.THINKING;
}

function mapHookPayload(payload, agent, fallbackEvent, now = new Date()) {
  const sessionId = firstString(payload, ['session_id', 'sessionId', 'conversation_id', 'conversationId']);
  if (!sessionId) throw new Error('Hook input has no session id.');
  const eventName = firstString(payload, ['hook_event_name', 'hookEventName', 'event', 'event_name', 'eventName']) || fallbackEvent || 'Unknown';
  const workspaceRoots = Array.isArray(payload?.workspace_roots) ? payload.workspace_roots : [];
  const cwd = firstString(payload, ['cwd', 'working_directory', 'workingDirectory']) ||
    workspaceRoots.find((value) => typeof value === 'string' && value.length > 0);
  const detail = firstString(payload, [
    'message', 'error', 'reason', 'stop_reason', 'stopReason', 'notification_type', 'notificationType'
  ]);
  const signal = {
    schema_version: 1,
    agent,
    session_id: sessionId,
    state: stateForEvent(eventName, payload),
    event_name: eventName,
    updated_at: now.toISOString()
  };
  if (cwd) signal.cwd = cwd;
  if (detail) signal.detail = detail;
  const taskTitle = taskTitleFromPayload(payload);
  if (taskTitle) signal.task_title = taskTitle;
  return signal;
}

function mergeSignal(existing, incoming) {
  if (!existing) return incoming;
  const oldState = existing.state;
  const newState = incoming.state;
  const event = normalize(incoming.event_name || '');
  const oldNeedsProtection = [STATES.ATTENTION, STATES.FAILED, STATES.BLOCKED].includes(oldState);
  const resolvingEvent = ['sessionstart', 'userpromptsubmit', 'posttooluse'].includes(event);
  const lowPriorityEvent = event === 'stop' || event.startsWith('subagent');

  if (oldState === STATES.WAITING_APPROVAL && newState === STATES.WAITING_APPROVAL && event === 'notification') {
    return {
      ...incoming,
      updated_at: existing.updated_at || incoming.updated_at,
      task_title: incoming.task_title || existing.task_title
    };
  }
  if (oldNeedsProtection && !resolvingEvent && lowPriorityEvent &&
      statePriority(oldState) > statePriority(newState)) return existing;
  return { ...incoming, task_title: incoming.task_title || existing.task_title };
}

function signalRoot() {
  if (process.env.CODEX_CLAUDE_SIGNAL_HOME) return path.resolve(process.env.CODEX_CLAUDE_SIGNAL_HOME);
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'CodexClaudeSignal');
  }
  return path.join(os.homedir(), 'Library', 'Application Support', 'CodexClaudeSignalWindows');
}

function safeFilePart(value) {
  return String(value).slice(0, 160).replace(/[^a-zA-Z0-9_-]/g, '_');
}

function sessionsDirectory(root = signalRoot()) {
  return path.join(root, 'sessions');
}

function loadJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  try {
    fs.renameSync(temporary, file);
  } catch {
    try { fs.rmSync(file, { force: true }); } catch {}
    fs.renameSync(temporary, file);
  }
}

function writeSignal(signal, root = signalRoot()) {
  const file = path.join(sessionsDirectory(root), `${signal.agent}-${safeFilePart(signal.session_id)}.json`);
  const existing = loadJson(file, undefined);
  writeJsonAtomic(file, mergeSignal(existing, signal));
  return file;
}

function loadSignals(root = signalRoot()) {
  const directory = sessionsDirectory(root);
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
    .map((entry) => loadJson(path.join(directory, entry.name), undefined))
    .filter((signal) => signal && signal.schema_version === 1);
}

function clearSignals(root = signalRoot()) {
  const directory = sessionsDirectory(root);
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith('.json')) fs.rmSync(path.join(directory, entry.name));
  }
}

function codexHooksPath(home = os.homedir()) {
  return path.join(home, '.codex', 'hooks.json');
}

function claudeSettingsPath(home = os.homedir()) {
  return path.join(process.env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'), 'settings.json');
}

function cursorHooksPath(home = os.homedir()) {
  return path.join(home, '.cursor', 'hooks.json');
}

function isManagedCommand(command) {
  return typeof command === 'string' && command.includes('--codex-claude-signal-hook');
}

function isManagedGroup(group) {
  return Array.isArray(group?.hooks) && group.hooks.some((handler) =>
    isManagedCommand(handler?.command));
}

function windowsQuote(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function backupAndWriteConfig(file, root) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file)) {
    const stamp = new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 17);
    fs.copyFileSync(file, `${file}.bak-${stamp}`);
  }
  writeJsonAtomic(file, root);
}

function mergeHooksAtPath(file, events, agent, executablePath) {
  const root = loadJson(file, {});
  if (!root || Array.isArray(root) || typeof root !== 'object') throw new Error(`配置文件不是有效 JSON 对象：${file}`);
  const hooks = root.hooks && !Array.isArray(root.hooks) && typeof root.hooks === 'object' ? root.hooks : {};
  const command = `${windowsQuote(executablePath)} --codex-claude-signal-hook --agent ${agent}`;
  for (const event of events) {
    const current = Array.isArray(hooks[event]) ? hooks[event] : [];
    hooks[event] = [
      ...current.filter((group) => !isManagedGroup(group)),
      { hooks: [{ type: 'command', command, timeout: event === 'PermissionRequest' ? 5 : 3 }] }
    ];
  }
  root.hooks = hooks;
  backupAndWriteConfig(file, root);
}

function mergeCursorHooksAtPath(file, executablePath) {
  const root = loadJson(file, {});
  if (!root || Array.isArray(root) || typeof root !== 'object') throw new Error(`配置文件不是有效 JSON 对象：${file}`);
  const hooks = root.hooks && !Array.isArray(root.hooks) && typeof root.hooks === 'object' ? root.hooks : {};
  const command = `${windowsQuote(executablePath)} --codex-claude-signal-hook --agent ${AGENT_CURSOR}`;
  for (const event of CURSOR_HOOK_EVENTS) {
    const current = Array.isArray(hooks[event]) ? hooks[event] : [];
    hooks[event] = [...current.filter((entry) => !isManagedCommand(entry?.command)), { command }];
  }
  if (root.version === undefined) root.version = 1;
  root.hooks = hooks;
  backupAndWriteConfig(file, root);
}

function installHooks(executablePath, home = os.homedir()) {
  mergeHooksAtPath(codexHooksPath(home), CODEX_HOOK_EVENTS, AGENT_CODEX, executablePath);
  mergeHooksAtPath(claudeSettingsPath(home), CLAUDE_HOOK_EVENTS, AGENT_CLAUDE, executablePath);
  mergeCursorHooksAtPath(cursorHooksPath(home), executablePath);
}

function removeHooksAtPath(file) {
  if (!fs.existsSync(file)) return;
  const root = loadJson(file, {});
  if (!root || Array.isArray(root) || typeof root !== 'object') throw new Error(`配置文件不是有效 JSON 对象：${file}`);
  const hooks = root.hooks && !Array.isArray(root.hooks) && typeof root.hooks === 'object' ? root.hooks : {};
  for (const [event, groups] of Object.entries(hooks)) {
    const filtered = Array.isArray(groups) ? groups.filter((group) => !isManagedGroup(group)) : [];
    if (filtered.length > 0) hooks[event] = filtered;
    else delete hooks[event];
  }
  root.hooks = hooks;
  backupAndWriteConfig(file, root);
}

function removeCursorHooksAtPath(file) {
  if (!fs.existsSync(file)) return;
  const root = loadJson(file, {});
  if (!root || Array.isArray(root) || typeof root !== 'object') throw new Error(`配置文件不是有效 JSON 对象：${file}`);
  const hooks = root.hooks && !Array.isArray(root.hooks) && typeof root.hooks === 'object' ? root.hooks : {};
  for (const [event, entries] of Object.entries(hooks)) {
    const filtered = Array.isArray(entries) ? entries.filter((entry) => !isManagedCommand(entry?.command)) : [];
    if (filtered.length > 0) hooks[event] = filtered;
    else delete hooks[event];
  }
  root.hooks = hooks;
  backupAndWriteConfig(file, root);
}

function uninstallHooks(home = os.homedir()) {
  removeHooksAtPath(codexHooksPath(home));
  removeHooksAtPath(claudeSettingsPath(home));
  removeCursorHooksAtPath(cursorHooksPath(home));
}

function configContainsHook(file, executablePath, agent) {
  const root = loadJson(file, {});
  const groups = root?.hooks?.SessionStart;
  return Array.isArray(groups) && groups.some((group) => Array.isArray(group?.hooks) && group.hooks.some((handler) =>
    typeof handler?.command === 'string' && handler.command.includes(executablePath) &&
    handler.command.includes(`--agent ${agent}`)));
}

function cursorConfigContainsHook(file, executablePath) {
  const root = loadJson(file, {});
  const entries = root?.hooks?.sessionStart;
  return Array.isArray(entries) && entries.some((entry) =>
    typeof entry?.command === 'string' && entry.command.includes(executablePath) &&
    entry.command.includes(`--agent ${AGENT_CURSOR}`));
}

function hookStatus(executablePath, home = os.homedir()) {
  const codex = configContainsHook(codexHooksPath(home), executablePath, AGENT_CODEX);
  const claude = configContainsHook(claudeSettingsPath(home), executablePath, AGENT_CLAUDE);
  const cursor = cursorConfigContainsHook(cursorHooksPath(home), executablePath);
  return {
    codex_installed: codex,
    claude_installed: claude,
    cursor_installed: cursor,
    all_installed: codex && claude && cursor
  };
}

function settingsPath(root = signalRoot()) {
  return path.join(root, 'settings.json');
}

function loadSettings(root = signalRoot()) {
  const value = loadJson(settingsPath(root), {});
  return {
    lampMode: value?.lampMode === 3 ? 3 : 1,
    panelPosition: value?.panelPosition && Number.isFinite(value.panelPosition.x) && Number.isFinite(value.panelPosition.y)
      ? { x: value.panelPosition.x, y: value.panelPosition.y }
      : null
  };
}

function saveSettings(settings, root = signalRoot()) {
  writeJsonAtomic(settingsPath(root), settings);
}

module.exports = {
  AGENT_CODEX,
  AGENT_CLAUDE,
  AGENT_CURSOR,
  STATES,
  CODEX_HOOK_EVENTS,
  CLAUDE_HOOK_EVENTS,
  CURSOR_HOOK_EVENTS,
  stateTitle,
  statePriority,
  displayState,
  lampPresentation,
  constrainBounds,
  taskTitleFromPayload,
  stateForEvent,
  mapHookPayload,
  mergeSignal,
  signalRoot,
  writeSignal,
  loadSignals,
  clearSignals,
  codexHooksPath,
  claudeSettingsPath,
  cursorHooksPath,
  installHooks,
  uninstallHooks,
  hookStatus,
  loadSettings,
  saveSettings
};
