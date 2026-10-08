import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_chat_clipboard_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('剪贴板不可用时按没有图片处理', () async {
    // 测试环境没有系统剪贴板插件，读取必须安全失败，让输入区回退文本粘贴。
    expect(await AgentChatClipboardImage.read(), isNull);
  });
}
