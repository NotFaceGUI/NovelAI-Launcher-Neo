import 'dart:convert';
import 'dart:typed_data';

import '../../../core/agent/agent_types.dart';
import '../../../core/agent/resources/agent_chat_resource_reference_codec.dart';
import '../../../core/utils/inpaint_mask/inpaint_mask_geometry.dart';
import '../../../core/utils/inpaint_mask/inpaint_mask_operations.dart';
import '../../../core/utils/inpaint_outpaint_utils.dart';
import '../../../core/utils/nai_resolution_adapter.dart';
import '../../../data/models/image/image_params.dart';
import '../../../data/models/inpaint/inpaint_draft.dart';
import '../../../data/models/inpaint/inpaint_draft_status.dart';
import '../../../data/services/inpaint_draft_repository.dart';
import '../../providers/generation/generation_request_preparation_service.dart';
import 'agent_image_observation_ledger.dart';
import 'defined_agent_tool.dart';
import 'inpaint_mask_authoring.dart';
import 'manual_inpaint_toolbox_serialization.dart';

/// [filePath] 只用于观察台账比对，不进入模型可见输出。
typedef InpaintResolvedSource = ({Uint8List bytes, String? filePath});

class InpaintSourceResolution {
  const InpaintSourceResolution.ok(this.resource) : error = null;
  const InpaintSourceResolution.failed(this.error) : resource = null;

  final InpaintResolvedSource? resource;
  final AgentToolResult? error;
}

/// 机器生成蒙版所需的共享草稿设施，由 ManualInpaintToolbox 提供。
abstract interface class InpaintDraftAuthoringHost {
  InpaintDraftRepository get draftRepository;
  String? get currentSessionId;
  int get requestBatchSize;
  ImageParams get baseGenerationParams;

  /// 生成页当前的重绘面板状态：聚焦重绘开关与上下文像素下限。
  ///
  /// 用户手绘的蒙版与页面上这套设置是配套的，采用时必须一起快照，否则 chat 提交
  /// 与面板提交会得到不同的裁剪与计价。
  GenerationFocusedSnapshot get pageFocusedInpaint;

  Future<InpaintSourceResolution> resolveInpaintSource(
    Map<String, dynamic> args,
  );

  int estimateInfillAnlas(
    ImageParams params, {
    required int batchSize,
    required Uint8List? maskImage,
    required GenerationFocusedSnapshot focused,
  });

  GenerationFocusedSnapshot readFocusedSnapshot(Map<String, dynamic> snapshot);

  void bindDraftSession(String draftId, String sessionId);

  Future<void> notifyDraftChanged(InpaintDraft draft);
}

/// Builds inpaint drafts whose mask comes from geometry or canvas expansion
/// instead of the editor.
class InpaintDraftAuthoringService {
  InpaintDraftAuthoringService(this._host);

  final InpaintDraftAuthoringHost _host;
  AgentImageObservationLedger? _observationLedger;
  String Function()? _observationSessionId;

  void configureObservationLedger(
    AgentImageObservationLedger ledger, {
    required String Function() activeSessionId,
  }) {
    _observationLedger = ledger;
    _observationSessionId = activeSessionId;
  }

  Future<AgentToolResult> createFromGeometry(Map<String, dynamic> args) async {
    final prompt = (args['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      return agentToolError('invalid_prompt', 'prompt must not be empty.');
    }
    final InpaintMaskAuthoringRequest request;
    try {
      request = InpaintMaskAuthoring.parse(args);
    } on InpaintMaskAuthoringException catch (error) {
      return agentToolError(error.code, error.message);
    }

    final resolution = await _host.resolveInpaintSource(args);
    final resolutionError = resolution.error;
    if (resolutionError != null) return resolutionError;
    final resource = resolution.resource!;
    final notObserved = _requireObservedSource(resource.filePath);
    if (notObserved != null) return notObserved;

    final size = NaiResolutionAdapter.readImageSize(resource.bytes);
    if (size == null) {
      return agentToolError(
        'invalid_source',
        'The source image could not be decoded.',
      );
    }
    final (width, height) = size;

    final Uint8List maskBinary;
    try {
      maskBinary = InpaintMaskGeometry.rasterizeBinary(
        regions: request.regions,
        width: width,
        height: height,
        expandRatio: request.expandRatio,
      );
    } on InpaintMaskGeometryException catch (error) {
      return agentToolError('invalid_regions', error.message);
    }

    final maskedPixels = maskBinary.fold<int>(0, (total, v) => total + v);
    if (maskedPixels == 0) {
      return agentToolError(
        'empty_mask',
        'The regions produced an empty mask. Widen them or raise expand_ratio.',
      );
    }

    final focusedEnabled = InpaintMaskAuthoring.resolveFocusedEnabled(
      preference: request.focus,
      maskedPixels: maskedPixels,
      imagePixels: width * height,
    );

    return _commit(
      source: resource.bytes,
      maskBinary: maskBinary,
      width: width,
      height: height,
      prompt: prompt,
      paramOverrides: args['params'],
      encodedReference: args['source_ref'],
      focusedEnabled: focusedEnabled,
      contextPadding: request.contextPadding,
      includePreview: args['preview'] != false,
    );
  }

  /// 读生成页当前的底图与用户手绘蒙版。
  ///
  /// 用户画在生成页上的蒙版才是他要重绘的区域；模型看不到它，就会用
  /// create_inpaint_mask 自己编一个区域。这里先把现状报清楚，并给出该走哪条路。
  Future<AgentToolResult> describeCurrentMask(Map<String, dynamic> args) async {
    final includePreview = args['preview'] != false;
    final params = _host.baseGenerationParams;
    final source = params.sourceImage;
    final maskBytes = params.maskImage;
    final prompt = params.prompt.trim();
    final focused = _host.pageFocusedInpaint;
    final details = <String, dynamic>{
      'ok': true,
      'maskSource': 'generation_page',
      'hasSourceImage': source != null,
      'hasMask': false,
      'focusedInpaint': focused.enabled,
      'isOutpaint': params.isOutpaint,
      if (prompt.isNotEmpty) 'prompt': prompt,
    };
    final decoded =
        maskBytes == null || !InpaintMaskUtils.hasMaskedPixels(maskBytes)
        ? null
        : InpaintMaskUtils.decodeBinaryMask(maskBytes);
    if (source == null || decoded == null) {
      details['next_step'] =
          'The Generation page has no user-drawn mask right now. Do not invent '
          'the region with create_inpaint_mask: ask the user to paint it in the '
          'inpaint editor (create_manual_inpaint_draft), or use a geometry mask '
          'only if they explicitly asked for that shape.';
      return agentToolJsonResult(details);
    }
    details['hasMask'] = true;
    final sourceSize = NaiResolutionAdapter.readImageSize(source);
    details['maskSize'] = '${decoded.width}x${decoded.height}';
    if (sourceSize != null) {
      details['sourceSize'] = '${sourceSize.$1}x${sourceSize.$2}';
      details['sizeMatchesSource'] =
          sourceSize.$1 == decoded.width && sourceSize.$2 == decoded.height;
    }
    details['maskCoverage'] = _maskCoverage(decoded.mask);
    details['next_step'] =
        'This is the mask the user painted. adopt_current_inpaint_mask stores '
        'it as a ready draft and submit_manual_inpaint_draft generates with it. '
        'Never re-draw it with create_inpaint_mask.';
    final content = <ToolResultContent>[
      ToolResultTextContent(jsonEncode(details)),
    ];
    if (includePreview && sourceSize != null) {
      final overlay = await buildMaskOverlayContent(
        source: source,
        maskBinary: decoded.mask,
        width: decoded.width,
        height: decoded.height,
      );
      if (overlay != null) content.add(overlay);
    }
    return AgentToolResult(content: content, details: details);
  }

  /// 把用户画在生成页上的蒙版连同底图、参数与聚焦设置存成 ready 草稿。
  ///
  /// 之后复用既有的 get / submit / reedit / load_inpaint_draft_into_panel 流程，
  /// 不给 chat 单开一条绕过估价与审批的生成路径。
  Future<AgentToolResult> createFromCurrentMask(
    Map<String, dynamic> args,
  ) async {
    final params = _host.baseGenerationParams;
    final source = params.sourceImage;
    if (source == null) {
      return agentToolError(
        'no_source_image',
        'The Generation page has no img2img source image, so there is nothing '
            'to adopt a mask for.',
      );
    }
    final maskBytes = params.maskImage;
    final decoded =
        maskBytes == null || !InpaintMaskUtils.hasMaskedPixels(maskBytes)
        ? null
        : InpaintMaskUtils.decodeBinaryMask(maskBytes);
    if (decoded == null) {
      return agentToolError(
        'no_current_mask',
        'The Generation page has no user-drawn mask. Ask the user to paint one '
            '(create_manual_inpaint_draft) instead of inventing the region.',
      );
    }
    final sourceSize = NaiResolutionAdapter.readImageSize(source);
    if (sourceSize == null) {
      return agentToolError(
        'invalid_source',
        'The page source image could not be decoded.',
      );
    }
    if (sourceSize.$1 != decoded.width || sourceSize.$2 != decoded.height) {
      return agentToolError(
        'mask_source_mismatch',
        'The mask is ${decoded.width}x${decoded.height} but the source image '
            'is ${sourceSize.$1}x${sourceSize.$2}; ask the user to repaint it.',
      );
    }
    final prompt = (args['prompt'] as String?)?.trim() ?? params.prompt.trim();
    if (prompt.isEmpty) {
      return agentToolError('invalid_prompt', 'prompt must not be empty.');
    }
    final focused = _host.pageFocusedInpaint;
    return _commit(
      source: source,
      maskBinary: decoded.mask,
      width: decoded.width,
      height: decoded.height,
      prompt: prompt,
      paramOverrides: args['params'],
      encodedReference: null,
      focusedEnabled: focused.enabled,
      contextPadding: focused.minimumContextMegaPixels.round(),
      includePreview: args['preview'] != false,
      sourceIsOutpaint: params.isOutpaint,
      extraDetails: const {'maskSource': 'generation_page'},
    );
  }

  double _maskCoverage(Uint8List maskBinary) {
    if (maskBinary.isEmpty) return 0;
    final masked = maskBinary.fold<int>(0, (total, value) => total + value);
    return double.parse((masked / maskBinary.length).toStringAsFixed(4));
  }

  Future<AgentToolResult> createFromExpansion(Map<String, dynamic> args) async {
    final prompt = (args['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) {
      return agentToolError('invalid_prompt', 'prompt must not be empty.');
    }
    final rawEdges = args['edges'];
    if (rawEdges is! Map) {
      return agentToolError(
        'invalid_edges',
        'edges must be an object with left, top, right and bottom pixels.',
      );
    }
    final edges = Map<String, dynamic>.from(rawEdges);
    int edge(String name) {
      final value = edges[name];
      if (value == null) return 0;
      final pixels = value is num ? value.toInt() : -1;
      if (pixels < 0 || pixels > 4096) {
        throw const FormatException(
          'edges values must be integers from 0 to 4096 pixels.',
        );
      }
      return pixels;
    }

    final OutpaintEdges expansion;
    try {
      expansion = OutpaintEdges(
        left: edge('left'),
        top: edge('top'),
        right: edge('right'),
        bottom: edge('bottom'),
      );
    } on FormatException catch (error) {
      return agentToolError('invalid_edges', error.message);
    }
    if (expansion.isEmpty) {
      return agentToolError(
        'invalid_edges',
        'At least one edge must be greater than zero.',
      );
    }

    // 扩图只用四个边距、不依赖视觉定位，因此不做观察台账校验。
    final resolution = await _host.resolveInpaintSource(args);
    final resolutionError = resolution.error;
    if (resolutionError != null) return resolutionError;
    final resource = resolution.resource!;

    final OutpaintExpansionResult expanded;
    try {
      expanded = await InpaintOutpaintUtils.expandAsync(
        sourceImage: resource.bytes,
        edges: expansion,
      );
    } on Object catch (error) {
      return agentToolError('expand_failed', '$error');
    }

    final decodedMask = InpaintMaskUtils.decodeBinaryMask(expanded.maskImage);
    if (decodedMask == null) {
      return agentToolError(
        'expand_failed',
        'The generated outpaint mask could not be decoded.',
      );
    }

    return _commit(
      source: expanded.sourceImage,
      maskBinary: decodedMask.mask,
      width: decodedMask.width,
      height: decodedMask.height,
      prompt: prompt,
      paramOverrides: args['params'],
      encodedReference: null,
      // 新增画布本身就是整块空白，裁剪到局部反而丢掉衔接所需的上下文。
      focusedEnabled: false,
      contextPadding: null,
      includePreview: args['preview'] != false,
      sourceIsOutpaint: true,
      extraDetails: {
        'appliedEdges': {
          'left': expanded.appliedEdges.left,
          'top': expanded.appliedEdges.top,
          'right': expanded.appliedEdges.right,
          'bottom': expanded.appliedEdges.bottom,
        },
        'size': '${expanded.width}x${expanded.height}',
      },
    );
  }

  Future<AgentToolResult> _commit({
    required Uint8List source,
    required Uint8List maskBinary,
    required int width,
    required int height,
    required String prompt,
    required Object? paramOverrides,
    required Object? encodedReference,
    required bool focusedEnabled,
    required int? contextPadding,
    required bool includePreview,
    bool sourceIsOutpaint = false,
    Map<String, dynamic> extraDetails = const {},
  }) async {
    final repository = _host.draftRepository;
    final sessionId = _host.currentSessionId;
    bool isCurrentSession() => _host.currentSessionId == sessionId;
    String? createdDraftId;
    try {
      final maskPng = InpaintMaskUtils.encodeBinaryMask(
        maskBinary,
        width,
        height,
      );
      final snapshot = buildManualInpaintParameterSnapshot(
        _host.baseGenerationParams,
        prompt,
        paramOverrides,
        sourceImage: source,
      );
      if (encodedReference != null) {
        snapshot['_agentSourceReference'] =
            AgentChatResourceReferenceCodec.encodeJsonMap(
              AgentChatResourceReferenceCodec.decodeJsonMap(
                Map<String, dynamic>.from(encodedReference as Map),
              ),
            );
      }
      snapshot['_agentFocusedInpaint'] = {
        'enabled': focusedEnabled,
        if (contextPadding != null) 'contextPadding': contextPadding,
      };
      snapshot['_agentSourceIsOutpaint'] = sourceIsOutpaint;
      final batchSize = _host.requestBatchSize;
      snapshot['_agentBatchSize'] = batchSize;
      final estimatedAnlas = _host.estimateInfillAnlas(
        ImageParams.fromJson(snapshot),
        batchSize: batchSize,
        maskImage: maskPng,
        focused: _host.readFocusedSnapshot(snapshot),
      );
      final prepared = await repository.prepare(
        sourceBytes: source,
        parameterSnapshot: snapshot,
        estimatedAnlas: estimatedAnlas,
      );
      createdDraftId = prepared.id;
      if (!isCurrentSession()) {
        await repository.cancel(prepared.id);
        return agentToolError(
          'session_switched',
          'The Agent session changed before the inpaint draft was stored.',
        );
      }
      _host.bindDraftSession(prepared.id, sessionId ?? '');
      final editing = await repository.beginEditing(prepared.id);
      final ready = await repository.complete(
        editing.id,
        sourceBytes: source,
        maskBytes: maskPng,
        parameterSnapshot: snapshot,
        estimatedAnlas: editing.estimatedAnlas,
      );
      await _host.notifyDraftChanged(ready);

      final details = <String, dynamic>{
        'ok': true,
        'draft': manualInpaintDraftJson(ready),
        'maskCoverage': double.parse(
          (maskBinary.fold<int>(0, (total, v) => total + v) / (width * height))
              .toStringAsFixed(4),
        ),
        'focusedInpaint': focusedEnabled,
        ...extraDetails,
      };
      final content = <ToolResultContent>[
        ToolResultTextContent(jsonEncode(details)),
      ];
      if (includePreview) {
        final overlay = await _buildMaskPreview(
          source: source,
          maskBinary: maskBinary,
          width: width,
          height: height,
        );
        if (overlay != null) content.add(overlay);
      }
      return AgentToolResult(content: content, details: details);
    } on Object catch (error) {
      if (createdDraftId != null) {
        final current = await repository.get(createdDraftId);
        if (current != null &&
            (current.status == InpaintDraftStatus.prepared ||
                current.status == InpaintDraftStatus.editing)) {
          await repository.cancel(createdDraftId);
        }
      }
      return agentToolError('create_failed', '$error');
    }
  }

  Future<ToolResultContent?> _buildMaskPreview({
    required Uint8List source,
    required Uint8List maskBinary,
    required int width,
    required int height,
  }) => buildMaskOverlayContent(
    source: source,
    maskBinary: maskBinary,
    width: width,
    height: height,
  );

  /// 没有台账记录说明模型没真正看过这张图，坐标只能是猜的，不能放行到扣费环节。
  AgentToolResult? _requireObservedSource(String? filePath) {
    final ledger = _observationLedger;
    final sessionId = _observationSessionId?.call();
    if (ledger == null || sessionId == null) return null;
    if (filePath != null && ledger.hasObserved(sessionId, filePath)) {
      return null;
    }
    return agentToolError(
      'image_not_observed',
      'Read the source image with the read tool before authoring a mask for '
          'it, so the coordinates come from the image instead of a guess. '
          'Generated images expose a workspace path only when they are saved '
          'to disk.',
    );
  }
}
