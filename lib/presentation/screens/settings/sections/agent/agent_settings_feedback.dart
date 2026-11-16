import 'package:flutter/material.dart';

import '../../../../../core/utils/localization_extension.dart';
import '../../../../widgets/common/app_toast.dart';

/// 统一报告 Agent 设置写入失败，避免各设置卡片各自复制提示逻辑。
Future<void> reportAgentSettingFailure(
  BuildContext context,
  Future<void> operation,
) async {
  try {
    await operation;
  } catch (error) {
    if (context.mounted) {
      AppToast.error(
        context,
        context.l10n.agentSettings_operationFailed(error.toString()),
      );
    }
  }
}
