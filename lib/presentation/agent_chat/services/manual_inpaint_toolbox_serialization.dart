import 'dart:convert';
import 'dart:typed_data';

import '../../../core/agent/agent_types.dart';
import '../../../core/agent/harness/tools/image.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/display_thumbnail_utils.dart';
import '../../../core/utils/inpaint_mask/inpaint_mask_preview.dart';
import '../../../core/utils/nai_resolution_adapter.dart';
import '../../../data/models/image/image_params.dart';
import '../../../data/models/inpaint/inpaint_draft.dart';
import '../../../data/services/inpaint_draft_repository.dart';

const manualInpaintDraftIdSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'draft_id': {'type': 'string'},
  },
  'required': ['draft_id'],
};

Map<String, dynamic> manualInpaintDraftJson(InpaintDraft draft) => {
  'draftId': draft.id,
  'status': draft.status.name,
  'prompt': draft.parameterSnapshot['prompt'],
  'params': draft.parameterSnapshot,
  if (draft.parameterSnapshot['_agentSourceReference'] case final Map value)
    'sourceReference': value,
  'source': draft.source.toJson(),
  if (draft.mask != null) 'mask': draft.mask!.toJson(),
  'estimatedAnlas': draft.estimatedAnlas,
  'createdAt': draft.createdAt.toIso8601String(),
  'updatedAt': draft.updatedAt.toIso8601String(),
  if (draft.failureMessage != null) 'failure': draft.failureMessage,
};

Map<String, dynamic> buildManualInpaintParameterSnapshot(
  ImageParams base,
  String prompt,
  Object? overrides, {
  Uint8List? sourceImage,
}) {
  final snapshot = <String, dynamic>{...base.toJson()};
  if (overrides != null) {
    if (overrides is! Map<String, dynamic>) {
      throw const FormatException('params must be an object.');
    }
    snapshot.addAll(overrides);
  }
  snapshot['prompt'] = prompt;
  snapshot['action'] = ImageGenerationAction.infill.name;
  if (sourceImage != null) {
    // 请求尺寸必须跟随底图：normalizeImageForRequest 是无视宽高比的直接重采样，
    // 沿用生成页尺寸会把底图拉伸变形。
    final model = snapshot['model']?.toString() ?? base.model;
    final imported = NaiResolutionAdapter.describeImageForImport(
      sourceImage,
      currentWidth: (snapshot['width'] as num?)?.toInt(),
      currentHeight: (snapshot['height'] as num?)?.toInt(),
      isStableDiffusionFamily: ImageModels.usesStableDiffusionImportBounds(
        model,
      ),
    );
    if (imported != null) {
      snapshot['width'] = imported.width;
      snapshot['height'] = imported.height;
    }
  }
  return ImageParams.fromJson(snapshot).toJson();
}

Future<AgentToolResult> buildManualInpaintDraftResult(
  InpaintDraft draft,
  InpaintDraftRepository repository,
) async {
  final details = <String, dynamic>{
    'ok': true,
    'draft': manualInpaintDraftJson(draft),
  };
  final content = <ToolResultContent>[
    ToolResultTextContent(jsonEncode(details)),
  ];
  final previews = <Uint8List>[await repository.readSource(draft.id)];
  if (draft.mask != null) {
    final mask = await repository.readMask(draft.id);
    if (mask != null) previews.add(mask);
  }
  for (final bytes in previews) {
    final thumbnail = await DisplayThumbnailUtils.normalize(bytes);
    if (thumbnail == null) continue;
    final mimeType = detectSupportedImageMimeType(thumbnail);
    if (mimeType == null) continue;
    content.add(
      ToolResultImageContent(
        ImageContent(
          source: ImageSource.base64(
            mimeType: mimeType,
            base64Data: base64Encode(thumbnail),
          ),
        ),
      ),
    );
  }
  return AgentToolResult(content: content, details: details);
}

/// 把源图与二值蒙版叠加成一张预览，供模型确认蒙版落在什么位置。
///
/// 渲染失败时返回 null（只丢预览，不影响工具结果本身）。
Future<ToolResultContent?> buildMaskOverlayContent({
  required Uint8List source,
  required Uint8List maskBinary,
  required int width,
  required int height,
}) async {
  try {
    final preview = await InpaintMaskPreview.renderAsync(
      sourceImage: source,
      maskBinary: maskBinary,
      width: width,
      height: height,
    );
    if (preview == null) return null;
    final mimeType = detectSupportedImageMimeType(preview);
    if (mimeType == null) return null;
    return ToolResultImageContent(
      ImageContent(
        source: ImageSource.base64(
          mimeType: mimeType,
          base64Data: base64Encode(preview),
        ),
      ),
    );
  } on Object catch (error, stackTrace) {
    AppLogger.e(
      'Inpaint mask preview rendering failed',
      error,
      stackTrace,
      'AgentChat',
    );
    return null;
  }
}
