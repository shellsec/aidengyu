# 状态灯语

每个 Codex、Claude Code 或 Cursor 主会话占用一组红、黄、绿灯。会话身份来自 Hook payload 的 `session_id` 或 `conversation_id`；子 Agent 事件汇总到所属主会话，不额外占用灯组。

| 状态 | 灯效 | 默认周期 | 含义 |
| --- | --- | --- | --- |
| `ready` | 绿灯常亮 | - | 会话在线，等待新任务 |
| `thinking` | 绿灯呼吸 | 1.6 秒 | 模型正在推理 |
| `working` | 绿灯慢闪 | 1.0 秒 | 正在调用工具、改代码或运行测试 |
| `waiting_input` | 黄灯慢闪 | 1.0 秒 | Agent 提出普通问题，等待用户回答 |
| `waiting_approval` | 黄灯快闪 | 0.4 秒，最多持续 30 秒 | 必须批准或拒绝才能继续；无结果 Hook 时转为黄灯常亮 |
| `completed` | 绿灯双闪后常亮 | 显示 15 秒 | 本轮成功完成，随后回到 `ready` |
| `attention` | 黄灯常亮 | - | 有通知或配置变化，建议检查 |
| `stale` | 黄灯常亮 | - | 活跃状态超过 10 分钟没有新事件 |
| `failed` | 红灯常亮 | - | 工具或本轮执行失败 |
| `blocked` | 红灯快闪 | 0.4 秒 | 限额、认证、权限拒绝等原因阻止继续执行 |
| `offline` | 三灯熄灭 | 淡出 3 秒 | 会话已经退出，灯组随后移除 |

补充：盘上仍是 `working` 且最后事件为 `postToolUse`（或同类收尾事件）时，若超过 45 秒没有新 Hook，展示态回落到 `ready`。这样可覆盖 Cursor 在 Task 子会话或中断后偶尔不发 `stop` 的情况；进行中的长工具（最后事件仍是 `preToolUse`）不会被提前回落。仅有 `sessionStart`、且没有工作区/`cwd` 的空窗会话不会进入面板，避免重复的「未知项目 / 就绪」。

## 设计原则

- 绿灯只表达正常状态：就绪、思考、工作、完成。
- 黄灯统一表达“需要人或需要检查”，授权与普通问答用闪烁速度区分。
- 红灯只表达异常，避免把正常的授权流程误报为故障。
- 同一会话发生并发事件时，优先级为：`blocked > failed > waiting_approval > waiting_input > attention > working > thinking > completed > ready > offline > stale`。
- 状态灯列表按同一套优先级降序排列：有效展示态在前，「状态过期」(`stale`) 始终排在最后。
- `Stop` 会解除已经回答或拒绝的授权/问答等待，但不会覆盖刚发生的失败或阻塞。
- Claude 拒绝授权时可能不发送结果 Hook；授权快闪超过 30 秒后会回落为 `attention`，重复的授权通知不会重新计时。
- Cursor 当前没有独立的授权请求 Hook，因此 Cursor 的授权弹窗不会单独切换为 `waiting_approval`。

## Hook 映射

| 事件 | 状态 |
| --- | --- |
| `SessionStart` | `ready` |
| `UserPromptSubmit` | `thinking` |
| `PreToolUse` | `working` |
| `PreToolUse` + `AskUserQuestion` / `request_user_input` | `waiting_input` |
| `PermissionRequest` | `waiting_approval` |
| `Notification` + permission | `waiting_approval` |
| `SubagentStart` | `working` |
| `SubagentStop` | `completed` |
| `Notification` + idle prompt / question | `waiting_input` |
| `PostToolUseFailure` 或结构化失败字段 | `failed` |
| 限额、认证、拒绝、阻塞类错误 | `blocked` |
| `Stop` | `completed` |
| `SessionEnd` | `offline` |
| Cursor `sessionStart` | `ready` |
| Cursor `beforeSubmitPrompt` | `thinking` |
| Cursor `preToolUse` / `postToolUse` / `preCompact` | `working` |
| Cursor `postToolUseFailure` 或 `stop` + `status: error` | `failed` |
| Cursor `stop` | `completed` |
| Cursor `sessionEnd` | `offline` |
