import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;

import '../enums/precise_reference_image_mode.dart';
import '../network/error_mappers/api_error_mapper.dart';
import 'app_logger.dart';

/// NAI API 工具类
/// 提供 NovelAI API 相关的共享静态方法
class NAIApiUtils {
  static final Expando<Set<PreciseReferenceImageMode>>
  _normalizedPreciseReferenceCache = Expando<Set<PreciseReferenceImageMode>>(
    'normalizedPreciseReference',
  );

  /// 标记该字节对象已经是指定模式的精准参考 PNG。
  static Uint8List markNormalizedPreciseReferencePng(
    Uint8List imageBytes, {
    PreciseReferenceImageMode mode = PreciseReferenceImageMode.directorCanvas,
  }) {
    final modes = _normalizedPreciseReferenceCache[imageBytes] ??=
        <PreciseReferenceImageMode>{};
    modes.add(mode);
    return imageBytes;
  }

  /// 当前会话中是否已确认该字节对象是指定模式的精准参考 PNG。
  static bool isKnownNormalizedPreciseReferencePng(
    Uint8List imageBytes, {
    PreciseReferenceImageMode mode = PreciseReferenceImageMode.directorCanvas,
  }) {
    return _normalizedPreciseReferenceCache[imageBytes]?.contains(mode) ??
        false;
  }

  /// 已缓存的规范化模式；旧代码只看 V4.5 画布模式。
  static PreciseReferenceImageMode? normalizedModeOf(Uint8List imageBytes) {
    final modes = _normalizedPreciseReferenceCache[imageBytes];
    if (modes == null) return null;
    for (final mode in PreciseReferenceImageMode.values) {
      if (modes.contains(mode)) return mode;
    }
    return null;
  }

  /// 将 double 转换为 JSON 数值（整数或浮点数）
  /// 如果是整数值（如 5.0），返回 int；否则返回 double
  static num toJsonNumber(double value) {
    return value == value.truncateToDouble() ? value.toInt() : value;
  }

  /// 将图片转换为 NovelAI Director Reference 要求的格式
  /// 按官方 Web 客户端 Q6 路径处理：
  /// - 选择三种目标画布之一：(1024,1536), (1536,1024), (1472,1472)
  /// - 选择宽高比最接近原图的目标画布
  /// - 按比例缩放图像，黑色背景居中粘贴
  /// - 转换为 PNG 格式
  static Uint8List ensurePngFormat(Uint8List imageBytes) {
    // 解码图片
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      AppLogger.w('Failed to decode image, returning original bytes', 'Utils');
      return imageBytes;
    }

    final int width = originalImage.width;
    final int height = originalImage.height;

    AppLogger.d(
      'Processing character reference: ${width}x$height, channels: ${originalImage.numChannels}',
      'Utils',
    );

    final targets = [
      (1024, 1536), // portrait
      (1536, 1024), // landscape
      (1472, 1472), // square
    ];

    final imageAspectRatio = width / height;
    var bestTarget = targets.first;
    var bestAspectDelta = (bestTarget.$1 / bestTarget.$2 - imageAspectRatio)
        .abs();
    for (final target in targets.skip(1)) {
      final aspectDelta = (target.$1 / target.$2 - imageAspectRatio).abs();
      if (aspectDelta < bestAspectDelta) {
        bestAspectDelta = aspectDelta;
        bestTarget = target;
      }
    }
    final targetW = bestTarget.$1;
    final targetH = bestTarget.$2;

    final targetAspectRatio = targetW / targetH;
    final (newW, newH) = imageAspectRatio > targetAspectRatio
        ? (targetW, (targetW / imageAspectRatio).round())
        : ((targetH * imageAspectRatio).round(), targetH);
    final resized = img.copyResize(
      originalImage,
      width: newW,
      height: newH,
      interpolation: img.Interpolation.cubic,
    );

    final newImg = img.Image(
      width: targetW,
      height: targetH,
      numChannels: 3,
      backgroundColor: img.ColorRgb8(0, 0, 0), // 黑色背景
    );

    final left = (targetW - newW) ~/ 2;
    final top = (targetH - newH) ~/ 2;
    img.compositeImage(newImg, resized, dstX: left, dstY: top);

    final pngBytes = Uint8List.fromList(img.encodePng(newImg));
    AppLogger.d(
      'Character reference processed: ${width}x$height -> ${targetW}x$targetH (centered on black), '
          '${imageBytes.length} bytes -> ${pngBytes.length} bytes',
      'Utils',
    );

    return markNormalizedPreciseReferencePng(pngBytes);
  }

  /// 在后台 isolate 中执行 Director Reference 图片规范化，避免阻塞 UI isolate。
  static Future<Uint8List> ensurePngFormatAsync(Uint8List imageBytes) async {
    final normalizedBytes = await Isolate.run(
      () => ensurePngFormat(imageBytes),
    );
    return markNormalizedPreciseReferencePng(normalizedBytes);
  }

  /// V5 官方精准参考使用的 1 MP 宽高比桶。
  static const List<(int, int)> _v5ReferenceBuckets = [
    (256, 4096),
    (256, 4032),
    (256, 3968),
    (256, 3904),
    (256, 3840),
    (256, 3776),
    (256, 3712),
    (256, 3648),
    (256, 3584),
    (256, 3520),
    (256, 3456),
    (256, 3392),
    (256, 3328),
    (320, 3264),
    (320, 3200),
    (320, 3136),
    (320, 3072),
    (320, 3008),
    (320, 2944),
    (320, 2880),
    (320, 2816),
    (320, 2752),
    (384, 2688),
    (384, 2624),
    (384, 2560),
    (384, 2496),
    (384, 2432),
    (384, 2368),
    (448, 2304),
    (448, 2240),
    (448, 2176),
    (448, 2112),
    (512, 2048),
    (512, 1984),
    (512, 1920),
    (512, 1856),
    (576, 1792),
    (576, 1728),
    (576, 1664),
    (640, 1600),
    (640, 1536),
    (704, 1472),
    (704, 1408),
    (768, 1344),
    (768, 1280),
    (832, 1216),
    (896, 1152),
    (960, 1088),
    (1024, 1024),
    (1088, 960),
    (1152, 896),
    (1216, 832),
    (1280, 768),
    (1344, 768),
    (1408, 704),
    (1472, 704),
    (1536, 640),
    (1600, 640),
    (1664, 576),
    (1728, 576),
    (1792, 576),
    (1856, 512),
    (1920, 512),
    (1984, 512),
    (2048, 512),
    (2112, 448),
    (2176, 448),
    (2240, 448),
    (2304, 448),
    (2368, 384),
    (2432, 384),
    (2496, 384),
    (2560, 384),
    (2624, 384),
    (2688, 384),
    (2752, 320),
    (2816, 320),
    (2880, 320),
    (2944, 320),
    (3008, 320),
    (3072, 320),
    (3136, 320),
    (3200, 320),
    (3264, 320),
    (3328, 256),
    (3392, 256),
    (3456, 256),
    (3520, 256),
    (3584, 256),
    (3648, 256),
    (3712, 256),
    (3776, 256),
    (3840, 256),
    (3904, 256),
    (3968, 256),
    (4032, 256),
    (4096, 256),
  ];

  /// 选择宽高比最接近的 1 MP 桶（官方用对数比值比较）。
  static (int, int) _selectV5ReferenceBucket(int width, int height) {
    final aspectLog = math.log(math.max(width, 1) / math.max(height, 1));
    var best = _v5ReferenceBuckets.first;
    var bestDelta = (aspectLog - math.log(best.$1 / best.$2)).abs();
    for (final bucket in _v5ReferenceBuckets.skip(1)) {
      final delta = (aspectLog - math.log(bucket.$1 / bucket.$2)).abs();
      if (delta < bestDelta) {
        best = bucket;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// V5：把参考图 cover 缩放到 1 MP 宽高比桶并居中裁剪。
  ///
  /// 官方 V5 客户端不再像 V4.5 那样补边到三张大画布，而是按最接近的
  /// 宽高比桶裁剪；参考图会被重编码为 PNG。
  static Uint8List ensureV5BucketedPng(Uint8List imageBytes) {
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      AppLogger.w('Failed to decode image, returning original bytes', 'Utils');
      return imageBytes;
    }

    final width = originalImage.width;
    final height = originalImage.height;
    final (bucketWidth, bucketHeight) = _selectV5ReferenceBucket(width, height);
    final scale = math.max(bucketWidth / width, bucketHeight / height);
    final resizeWidth = math.max((width * scale).round(), bucketWidth);
    final resizeHeight = math.max((height * scale).round(), bucketHeight);

    final resized = img.copyResize(
      originalImage,
      width: resizeWidth,
      height: resizeHeight,
      interpolation: img.Interpolation.cubic,
    );
    final cropped = img.copyCrop(
      resized,
      x: (resizeWidth - bucketWidth) ~/ 2,
      y: (resizeHeight - bucketHeight) ~/ 2,
      width: bucketWidth,
      height: bucketHeight,
    );

    final pngBytes = Uint8List.fromList(img.encodePng(cropped));
    AppLogger.d(
      'V5 character reference: ${width}x$height -> '
          '${bucketWidth}x$bucketHeight (cover crop), '
          '${imageBytes.length} bytes -> ${pngBytes.length} bytes',
      'Utils',
    );
    return markNormalizedPreciseReferencePng(
      pngBytes,
      mode: PreciseReferenceImageMode.aspectBucket,
    );
  }

  /// 在后台 isolate 中执行 V5 精准参考分桶。
  static Future<Uint8List> ensureV5BucketedPngAsync(
    Uint8List imageBytes,
  ) async {
    final normalizedBytes = await Isolate.run(
      () => ensureV5BucketedPng(imageBytes),
    );
    return markNormalizedPreciseReferencePng(
      normalizedBytes,
      mode: PreciseReferenceImageMode.aspectBucket,
    );
  }

  /// 格式化 DioException 为错误代码（供 UI 层本地化显示）
  /// 返回格式: "ERROR_CODE|详细信息"
  static String formatDioError(DioException e) {
    return ApiErrorMapper.formatDioError(e);
  }
}
