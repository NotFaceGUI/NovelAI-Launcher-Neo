import 'package:super_clipboard/super_clipboard.dart';

import '../../../core/utils/app_logger.dart';
import '../../utils/dropped_file_reader.dart';

/// 读取系统剪贴板里的图片，供 Agent 输入区「粘贴即附件」使用。
///
/// 只认剪贴板里本地的图片数据与本地图片文件，不回源下载远程图片；当前平台没有
/// 系统剪贴板、剪贴板内容不是图片或读取失败时返回 null，由调用方决定回退行为。
class AgentChatClipboardImage {
  const AgentChatClipboardImage._();

  static const String _logTag = 'AgentChatPaste';

  /// 读取失败按「剪贴板里没有图片」处理，不把异常抛进输入区：平台没有系统剪贴板、
  /// 剪贴板内容不是图片、插件读取异常都会走到文本粘贴。
  static Future<DroppedFileData?> read() async {
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return null;
      final reader = await clipboard.read();
      for (final item in reader.items) {
        final file = await DroppedFileReader.read(
          item,
          allowRemoteImages: false,
          logTag: _logTag,
        );
        if (file != null) return file;
      }
    } catch (error) {
      AppLogger.d('Failed to read image from clipboard: $error', _logTag);
    }
    return null;
  }
}
