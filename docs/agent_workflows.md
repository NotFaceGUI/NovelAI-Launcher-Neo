# 智能体调查、提问与确认

## 职责边界

- `agent_research_instructions.dart` 维护默认角色调查策略，由 `buildAgentSystemPrompt` 组装。身份检索、标准标签核实、画廊外观证据复用现有工具，不在 Harness 中建立任务专属协议或第二份标签库。
- 角色知识问答本身不授权修改提示词或生成图片。联网关闭时保留该设置，使用可用的本地标签与画廊证据并说明限制；同一会话中已有的有效调查结果可以复用。
- 角色身份、稳定特征与版本服装分别处理。画廊中的姿势、背景、同图其他角色和画师风格不能直接当作角色固有特征。默认系统提示被用户整体覆盖时，自定义提示负责保留所需调查策略。

## 系统提示词组装

`agent_chat/services/agent_system_prompt.dart` 是聊天请求与设置预览的共同组装入口，沿用 Pi 将自定义正文与运行上下文分开的方式；不修改 Harness 的会话或工具协议。

- **补充要求**：内置正文 → 用户的自然语言要求 → 应用运行上下文。默认输入框为空，留空即使用内置正文。
- **替换正文**：用户正文 → 应用运行上下文。切换到此模式且草稿为空时，载入可编辑的内置正文；用户可以自行精简或重写，保存空正文也不会丢失运行上下文。
- **恢复默认**：只恢复当前模式的内容，不切换模式；补充模式清空自定义要求，替换模式重新载入内置正文，点击保存后生效。
- **内置正文**：默认身份、工具使用建议、NovelAI 写法与角色调查策略。它可以被替换，不含工作目录或 Skills 清单的设备快照。
- **运行上下文**：当前导出工作目录、联网可用性、启用且可由模型调用的 Skills 清单，以及生成准备/提交、提问与权限确认的应用协议。两种模式均由程序自动补充，权限仍由实际工具执行层强制检查。

自定义文本按字面处理，没有模板替换语法，也不要求用户保留占位符。`{tag}`、`[tag]` 和 `1.3::tag::` 是 NovelAI 权重语法示例。设置预览展示与实际请求相同的组装规则，结构化工具定义由 Provider 单独发送。

保存与云同步仍仅使用现有 `customSystemPrompt` 和 `systemPromptMode` 字段；自动上下文不写入自定义配置，不新增同步类型。旧自定义文本原样保留，旧客户端仍按旧版覆盖语义工作；跨设备恢复后，新客户端会重新组装本机上下文。旧文本中手写的目录或 Skills 不做猜测式删除，用户可在编辑器中清理。

## Token 预算与工具集

Agent 每轮都会重发系统提示词、工具 schema 与保留的历史。工具集、缓存和上下文清理共同控制这部分固定开销：

- **工具集**：`agent_tool_packs.dart` 按 toolbox 分组；核心提示词、`read`、图片查看、Skills 与提问始终下发。生成、生成图操作、队列、Inpaint 与标签库（含固定标签）默认开启；画廊、Vibe/精确参考与分镜默认关闭，可在「设置 → 智能体 → 工具集」按需开启。工具包选择是本机性能偏好，不进入云同步。运行时上下文会列出已启用/已关闭的包，模型遇到缺失工具时应提示用户开启。
- **固定前缀缓存**：Anthropic 在 tools、system 与最后一条消息上使用 `cache_control`；OpenAI 兼容/DeepSeek 依赖自动前缀缓存，因此系统提示词和工具顺序保持稳定，Skills 按名称排序后注入。缓存命中量会记录到 `Usage.cacheRead/cacheWrite`，并写入 Agent 调试日志。
- **上下文预算**：`agent_context_budget.dart` 在没有 provider usage 锚点或压缩后锚点失效时补上系统提示词与工具 schema 的估算；有有效锚点时不重复计算。压缩参数按窗口缩放，避免 8k/16k 模型因固定 reserve 每轮触发压缩。
- **工具结果预算**：`agent_tool_result_budget.dart` 在请求上下文边界限制单条结果的文本与图片数量；超限 JSON 会返回合法的截断说明，而不是破坏结构。截断只影响模型看到的内容，UI 与 JSONL 仍保留完整结果。
- **旧结果清理**：`agent_context_pruner.dart` 在上下文达到约 60% 窗口时，把更早的工具结果替换为稳定占位文本并移除旧图片，只影响本次请求，不改 JSONL 或 UI 历史。边界按 `toolCallId` 记忆，避免每轮改写前缀；完整压缩仍由 compaction 兜底。

验证入口：`agent_tool_packs_test.dart`、`agent_context_budget_test.dart`、`agent_context_pruner_test.dart`、`agent_tool_result_budget_test.dart`、`agent_stream_adapters_test.dart` 与 `agent_settings_section_test.dart`。

## 结构化提问

`ask_user_question` 接收非空 `questions` 数组，每题包含：

- `id`：请求内唯一的问题标识。
- `title`：完整问题。
- `options`：恰好三个有意义且实际可行的方向，每项包含唯一 `id`、`label` 与解释影响的 `description`。
- `recommended_option_id`：必须指向其中一个方向。界面显示推荐标记。

第四项“自定义”由界面统一补充，模型不能再加入占位选项。用户选择建议项后进入下一题；自定义项填写后进入下一题；最后检查整组答案再提交，可以返回修改。

通用组件 `UserQuestionFlow` 只依赖问题数据和提交/取消回调，不依赖 Riverpod、智能体、联网或权限。`AgentChatQuestionCard` 负责将其接到当前会话；`AgentUserQuestionController` 持有未完成工具调用，校验请求身份与答案完整性。过期提交、重复提交和无效答案不能完成当前请求。

问题等待期间退出手机对话不会自动作答，主界面入口显示问号与等待回答状态。新提问显示一次 Toast，Android 同时发送系统通知；点击通知打开对应提问，回答、超时或取消后撤销通知。Android 通知沿用运行开始时申请的系统通知权限；拒绝或禁用通知时明确提示，提问本身仍可在应用内完成。取消返回明确的 `cancelled` 结果；中止运行通过既有 `AbortSignal` 结束等待并释放监听器。整组问题默认等待 120 秒，可用 `timeout_seconds` 指定正整数秒数；到期自动提交全部推荐项（包括替换尚未提交的草稿选择），结果标记 `source: timeout_recommendation`，不构成删除或付费授权。倒计时由请求 owner 持有，退出页面不重置；提交、取消、中止会清理计时器。

问题表单与未提交答案是临时界面状态，不新增云同步数据类型。提交的答案走既有工具结果与会话持久化协议，沿用会话现有的备份范围。

## 权限和费用

信息提问与权限审批分开：`ask_user_question` 用于存在实质差异的用户偏好或歧义，不用于重复请求工具授权，也不要求用户代替工具查询事实。

权限的唯一执行判定仍是 `AgentToolPermissionCatalog` / `AgentToolPermissionController`：

- 完全访问允许普通读写，删除、覆盖、移动等破坏性操作仍需确认。
- 生成先准备并取得实际 Anlas 估算；精确为零的提交不要求模型提供确认标志，在完全访问下不弹审批。
- 正数或未知费用仍走审批。付费提交携带原有 `confirmed=true`（重绘为 `confirm=true`）表达提交意图，该标志不能绕过应用审批。
- 不在聊天文本或结构化问题中先索要一次确认、随后又弹一次审批。
- 安全模式和写入前询问模式继续遵循其权限限制；已准备任务仍保持一次提交语义。

## 验证入口

使用 `scripts/test_affected.ps1` 运行对应源码的测试，必要时用 `-Include` 加入以下回归：

- `user_question_toolbox_test.dart`：参数、推荐项、过期答案、取消、中止与只读模式。
- `user_question_flow_test.dart`：逐题推进、自定义、返回修改、推荐标记和响应式可达性。
- `agent_chat_notifier_test.dart`：实际工具注册、等待答案与模型续跑。
- `generation_toolbox_test.dart`、`manual_inpaint_toolbox_test.dart`、`agent_tool_permission_controller_test.dart`：零费用、付费、重复提交与模式约束。
- `agent_system_prompt_test.dart`：策略组装与联网不可用时的边界。

提示策略测试能验证默认指令和工具契约，不能证明每个外部模型都必然遵循调查顺序；评估实际模型时应查看工具轨迹与引用依据。
