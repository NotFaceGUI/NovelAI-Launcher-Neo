import 'package:flutter/material.dart';

import '../../../core/utils/localization_extension.dart';
import 'tag_editor_scope.dart';
import 'tag_editor_session.dart';

/// 当前文本选择可切换启用/禁用时的目标状态。
///
/// 返回 null 表示没有可切换的完整片段：未选中、提示词结构不完整，或
/// 当前编辑器没有标签编辑会话（例如未启用标签模式）。
({TagEditorSession session, bool enable})? resolvePromptTextSelectionToggle(
  BuildContext context,
) {
  final session = TagEditorScope.maybeOf(context);
  final tags = session?.textSelectionTags;
  if (session == null || tags == null || tags.isEmpty) return null;
  return (session: session, enable: tags.every((tag) => tag.span.disabled));
}

/// 切换当前选中片段的启用/禁用。
///
/// 右键菜单的「禁用/启用」与 Ctrl+/ 快捷键共用这条路径；
/// 返回 false 表示当前没有可切换的选择。
bool togglePromptTextSelectionEnabled(BuildContext context) {
  final toggle = resolvePromptTextSelectionToggle(context);
  if (toggle == null) return false;
  toggle.session.setTextSelectionEnabled(toggle.enable);
  return true;
}

ContextMenuButtonItem? promptTextSelectionEnabledAction(
  BuildContext context,
  EditableTextState editable,
) {
  if (editable.widget.readOnly) return null;
  final toggle = resolvePromptTextSelectionToggle(editable.context);
  if (toggle == null) return null;
  final session = toggle.session;
  final enable = toggle.enable;
  return ContextMenuButtonItem(
    label: enable ? context.l10n.tagMode_enable : context.l10n.tagMode_disable,
    onPressed: () {
      editable.hideToolbar();
      session.setTextSelectionEnabled(enable);
    },
  );
}
