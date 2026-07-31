'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const core = require('../core');

function payload(event, extra = {}) {
  return { session_id: 'session-1', hook_event_name: event, cwd: 'C:\\work\\example', ...extra };
}

test('maps lifecycle events to the shared state language', () => {
  assert.equal(core.stateForEvent('SessionStart', {}), core.STATES.READY);
  assert.equal(core.stateForEvent('UserPromptSubmit', {}), core.STATES.THINKING);
  assert.equal(core.stateForEvent('PreToolUse', {}), core.STATES.WORKING);
  assert.equal(core.stateForEvent('PreToolUse', { tool_name: 'AskUserQuestion' }), core.STATES.WAITING_INPUT);
  assert.equal(core.stateForEvent('PermissionRequest', {}), core.STATES.WAITING_APPROVAL);
  assert.equal(core.stateForEvent('PostToolUseFailure', {}), core.STATES.FAILED);
  assert.equal(core.stateForEvent('beforeSubmitPrompt', {}), core.STATES.THINKING);
  assert.equal(core.stateForEvent('stop', { status: 'error' }), core.STATES.FAILED);
  assert.equal(core.stateForEvent('SubagentStop', {}), core.STATES.COMPLETED);
  assert.equal(core.stateForEvent('Stop', { stop_reason: 'rate_limit' }), core.STATES.BLOCKED);
});

test('maps Cursor conversation fields and workspace root', () => {
  const signal = core.mapHookPayload({
    conversation_id: 'cursor-conversation-1',
    hook_event_name: 'beforeSubmitPrompt',
    workspace_roots: ['C:\\work\\cursor-project'],
    prompt: '支持 Cursor 状态灯'
  }, core.AGENT_CURSOR);
  assert.equal(signal.session_id, 'cursor-conversation-1');
  assert.equal(signal.cwd, 'C:\\work\\cursor-project');
  assert.equal(signal.task_title, '支持 Cursor 状态灯');
  assert.equal(signal.state, core.STATES.THINKING);
});

test('extracts and truncates a task title by Unicode characters', () => {
  const title = core.taskTitleFromPayload({ prompt: '  ## 优化登录页面的状态管理和错误提示\n不要修改接口协议' });
  assert.equal(title, '优化登录页面的状态管理和错误提示');
  assert.equal(Array.from(core.taskTitleFromPayload({ prompt: 'x'.repeat(50) })).length, 39);
});

test('display state settles completed and stale transient states', () => {
  const now = new Date('2026-07-31T12:00:00.000Z');
  assert.equal(core.displayState({ state: 'completed', updated_at: '2026-07-31T11:59:44.000Z' }, now), 'ready');
  assert.equal(core.displayState({ state: 'waiting_approval', updated_at: '2026-07-31T11:59:29.000Z' }, now), 'attention');
  assert.equal(core.displayState({ state: 'working', updated_at: '2026-07-31T11:49:59.000Z' }, now), 'stale');
});

test('Stop clears permission waiting but does not hide a failure', () => {
  const waiting = core.mapHookPayload(payload('PermissionRequest'), core.AGENT_CLAUDE);
  const failure = core.mapHookPayload(payload('PostToolUseFailure'), core.AGENT_CLAUDE);
  const completed = core.mapHookPayload(payload('Stop'), core.AGENT_CLAUDE);
  assert.equal(core.mergeSignal(waiting, completed).state, core.STATES.COMPLETED);
  assert.equal(core.mergeSignal(failure, completed).state, core.STATES.FAILED);
});

test('duplicate permission notification keeps the first timestamp', () => {
  const waiting = core.mapHookPayload(payload('PermissionRequest'), core.AGENT_CLAUDE,
    undefined, new Date('2026-07-31T10:00:00.000Z'));
  const notification = core.mapHookPayload(payload('Notification', { notification_type: 'permission_prompt' }),
    core.AGENT_CLAUDE, undefined, new Date('2026-07-31T10:00:05.000Z'));
  assert.equal(core.mergeSignal(waiting, notification).updated_at, waiting.updated_at);
});

test('writes separate session files and preserves the task title', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-signal-win-state-'));
  try {
    const titled = core.mapHookPayload(payload('UserPromptSubmit', { prompt: '修复 Windows 状态灯' }), core.AGENT_CODEX);
    core.writeSignal(titled, root);
    core.writeSignal(core.mapHookPayload(payload('PreToolUse'), core.AGENT_CODEX), root);
    core.writeSignal(core.mapHookPayload(payload('SessionStart', { session_id: 'session-2' }), core.AGENT_CLAUDE), root);
    const signals = core.loadSignals(root);
    assert.equal(signals.length, 2);
    assert.equal(signals.find((signal) => signal.session_id === 'session-1').task_title, '修复 Windows 状态灯');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('hook installation is idempotent and preserves existing config', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-signal-win-home-'));
  const executable = 'C:\\Program Files\\Codex Claude Signal\\Codex Claude Signal.exe';
  const codexFile = core.codexHooksPath(home);
  const cursorFile = core.cursorHooksPath(home);
  fs.mkdirSync(path.dirname(codexFile), { recursive: true });
  fs.writeFileSync(codexFile, JSON.stringify({
    description: 'keep me',
    hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'echo existing' }] }] }
  }));
  fs.mkdirSync(path.dirname(cursorFile), { recursive: true });
  fs.writeFileSync(cursorFile, JSON.stringify({
    version: 1,
    description: 'keep cursor config',
    hooks: { sessionStart: [{ command: 'echo existing-cursor' }] }
  }));
  try {
    core.installHooks(executable, home);
    core.installHooks(executable, home);
    const installed = JSON.parse(fs.readFileSync(codexFile, 'utf8'));
    assert.equal(installed.description, 'keep me');
    assert.equal(installed.hooks.SessionStart.length, 2);
    assert.match(installed.hooks.SessionStart[1].hooks[0].command, /^"C:\\Program Files/);
    const installedCursor = JSON.parse(fs.readFileSync(cursorFile, 'utf8'));
    assert.equal(installedCursor.description, 'keep cursor config');
    assert.equal(installedCursor.hooks.sessionStart.length, 2);
    assert.equal(installedCursor.hooks.sessionStart[0].command, 'echo existing-cursor');
    assert.match(installedCursor.hooks.sessionStart[1].command, /--agent cursor$/);
    assert.ok(core.CURSOR_HOOK_EVENTS.every((event) => installedCursor.hooks[event].length ===
      (event === 'sessionStart' ? 2 : 1)));
    assert.deepEqual(core.hookStatus(executable, home), {
      codex_installed: true,
      claude_installed: true,
      cursor_installed: true,
      all_installed: true
    });
    core.uninstallHooks(home);
    const uninstalled = JSON.parse(fs.readFileSync(codexFile, 'utf8'));
    assert.equal(uninstalled.hooks.SessionStart.length, 1);
    assert.equal(uninstalled.hooks.SessionStart[0].hooks[0].command, 'echo existing');
    const uninstalledCursor = JSON.parse(fs.readFileSync(cursorFile, 'utf8'));
    assert.deepEqual(uninstalledCursor.hooks.sessionStart, [{ command: 'echo existing-cursor' }]);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('settings default to single lamp and persist a position', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-signal-win-settings-'));
  try {
    assert.deepEqual(core.loadSettings(root), { lampMode: 1, panelPosition: null });
    core.saveSettings({ lampMode: 3, panelPosition: { x: 120, y: 48 } }, root);
    assert.deepEqual(core.loadSettings(root), { lampMode: 3, panelPosition: { x: 120, y: 48 } });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('window bounds always leave a draggable area on screen', () => {
  const workArea = { x: 100, y: 40, width: 1920, height: 1040 };
  assert.deepEqual(
    core.constrainBounds({ x: -1000, y: -900, width: 294, height: 278 }, workArea),
    { x: -122, y: -166, width: 294, height: 278 }
  );
  assert.deepEqual(
    core.constrainBounds({ x: 3000, y: 2000, width: 294, height: 278 }, workArea),
    { x: 1948, y: 1008, width: 294, height: 278 }
  );
});
