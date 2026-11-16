import 'dart:convert';

import '../../../core/agent/agent_types.dart';

/// 单个工具结果进入模型上下文前的硬预算。
///
/// 只修改本次请求的消息视图；UI 与 JSONL 仍保留完整结果，避免为了省 token
/// 丢失用户可见的数据。
const int maxToolResultTextChars = 32000;
const int maxToolResultImages = 2;

/// 对消息列表中的所有工具结果应用预算；没有变化时返回原列表。
List<AgentMessage> budgetToolResultMessages(List<AgentMessage> messages) {
  var changed = false;
  final result = <AgentMessage>[];
  for (final message in messages) {
    if (message is ToolResultMessage) {
      final budgeted = budgetToolResultMessage(message);
      if (!identical(budgeted, message)) changed = true;
      result.add(budgeted);
    } else {
      result.add(message);
    }
  }
  return changed ? result : messages;
}

ToolResultMessage budgetToolResultMessage(ToolResultMessage message) {
  final content = budgetToolResultContent(message.content);
  if (identical(content, message.content)) return message;
  return ToolResultMessage(
    toolCallId: message.toolCallId,
    toolName: message.toolName,
    content: content,
    details: message.details,
    usage: message.usage,
    addedToolNames: message.addedToolNames,
    isError: message.isError,
    timestamp: message.timestamp,
  );
}

List<ToolResultContent> budgetToolResultContent(
  List<ToolResultContent> content,
) {
  final images = content.whereType<ToolResultImageContent>().toList();
  final texts = content.whereType<ToolResultTextContent>().toList();
  final keptImages = images.take(maxToolResultImages).toList();
  final droppedImages = images.length - keptImages.length;
  final totalTextChars = texts.fold<int>(
    0,
    (total, item) => total + item.text.length,
  );
  if (totalTextChars <= maxToolResultTextChars && droppedImages == 0) {
    return content;
  }

  final result = <ToolResultContent>[];
  if (totalTextChars > maxToolResultTextChars) {
    result.add(
      ToolResultTextContent(
        _budgetText(
          texts.map((item) => item.text).join('\n\n'),
          isJson: texts.length == 1,
        ),
      ),
    );
  } else {
    result.addAll(content.where((item) => item is! ToolResultImageContent));
  }
  result.addAll(keptImages);
  if (droppedImages > 0) {
    result.add(
      ToolResultTextContent(
        '[$droppedImages image(s) omitted from this tool result to save '
        'context. The data remains available in the conversation UI.]',
      ),
    );
  }
  return result;
}

String _budgetText(String text, {required bool isJson}) {
  if (isJson) {
    final parsed = _tryDecodeJson(text);
    if (parsed != null) {
      // 预留转义与 envelope 空间，避免 JSON 字符串在编码后重新膨胀。
      const previewLength = maxToolResultTextChars * 45 ~/ 100;
      return jsonEncode({
        'truncated': true,
        'originalChars': text.length,
        'preview': _headTail(text, previewLength),
        'message':
            'Tool result exceeded $maxToolResultTextChars characters and was '
            'truncated. Request a narrower view, or re-query only if the tool '
            'is safe to repeat.',
      });
    }
  }
  return _headTail(
    text,
    maxToolResultTextChars,
    marker:
        '\n\n[... ${text.length - maxToolResultTextChars} characters omitted '
        'to save context. Request a narrower view, or re-query only if the '
        'tool is safe to repeat.]\n\n',
  );
}

Object? _tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

String _headTail(String text, int maxChars, {String marker = '\n\n[...]\n\n'}) {
  if (text.length <= maxChars) return text;
  final markerLength = marker.length;
  final available = maxChars - markerLength;
  if (available <= 0) {
    return text.substring(0, maxChars);
  }
  final headLength = (available * 0.7).floor();
  final tailLength = available - headLength;
  final head = text.substring(0, headLength);
  final tail = text.substring(text.length - tailLength);
  return '$head$marker$tail';
}
