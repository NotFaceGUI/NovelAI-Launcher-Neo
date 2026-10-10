import 'package:flutter/material.dart';

import '../../agent_chat/widgets/agent_chat_panel.dart';
import '../../widgets/common/owned_scroll_controller.dart';
import 'mobile_generation_chrome.dart';
import 'mobile_generation_controller.dart';
import 'mobile_generation_gestures.dart';
import 'mobile_generation_view_data.dart';
import 'mobile_generation_workspace.dart';
import 'widgets/prompt_input_controller.dart';

class MobileGenerationShell extends StatelessWidget {
  const MobileGenerationShell({
    super.key,
    required this.controller,
    required this.data,
    required this.historyViewport,
    required this.promptInputController,
    required this.promptInputKey,
  });

  final MobileGenerationController controller;
  final MobileGenerationViewData data;
  final OwnedViewportOffset historyViewport;
  final PromptInputController promptInputController;
  final GlobalKey promptInputKey;

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      // 分镜编辑器同样先吃掉返回键：它与预览共用一块工作区，返回等同于退出分镜。
      canPop:
          !data.isPromptMaximized &&
          !data.isStoryboardMode &&
          !controller.agentFullScreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          controller.handleBack(
            isPromptMaximized: data.isPromptMaximized,
            isStoryboardMode: data.isStoryboardMode,
          );
        }
      },
      child: MobileGenerationChrome(
        controller: controller,
        data: data,
        historyViewport: historyViewport,
        body: Stack(
          key: const ValueKey('generation-mobile-primary-workspaces'),
          children: [
            MobileGenerationWorkspace(
              controller: controller,
              data: data,
              promptInputController: promptInputController,
              promptInputKey: promptInputKey,
            ),
            Positioned.fill(
              child: MobileWorkspaceMotion(
                active: controller.agentFullScreen,
                hiddenOffset: const Offset(0, 0.08),
                child: TickerMode(
                  enabled: controller.agentFullScreen,
                  child: controller.agentHasOpened
                      ? ColoredBox(
                          key: const ValueKey('generation-agent-fullscreen'),
                          color: Theme.of(context).colorScheme.surface,
                          child: FocusScope(
                            node: controller.agentFocusScope,
                            child: AgentChatPanel(
                              key: const ValueKey(
                                'generation-agent-chat-panel',
                              ),
                              fullScreen: true,
                              onClose: controller.handleAgentBack,
                              onOpenSettings: () =>
                                  controller.openAgentSettings(context),
                              mobileHeaderWrapper: (child) =>
                                  MobileVerticalCloseGesture(
                                    key: const ValueKey(
                                      'generation-agent-close-drag-handle',
                                    ),
                                    closeDirection: AxisDirection.down,
                                    onClose: controller.closeAgentChat,
                                    child: child,
                                  ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
