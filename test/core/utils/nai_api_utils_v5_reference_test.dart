import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/enums/precise_reference_image_mode.dart';
import 'package:nai_launcher/core/utils/nai_api_utils.dart';

Uint8List _png(int width, int height) => Uint8List.fromList(
  img.encodePng(
    img.Image(width: width, height: height, numChannels: 3)
      ..clear(img.ColorRgb8(20, 40, 60)),
  ),
);

void main() {
  group('NAIApiUtils V5 precise reference bucketing', () {
    test('portrait images use the matching 1 MP aspect bucket', () {
      final output = NAIApiUtils.ensureV5BucketedPng(_png(100, 200));
      final decoded = img.decodePng(output)!;

      expect((decoded.width, decoded.height), (704, 1408));
      expect(
        NAIApiUtils.isKnownNormalizedPreciseReferencePng(
          output,
          mode: PreciseReferenceImageMode.aspectBucket,
        ),
        isTrue,
      );
      expect(
        NAIApiUtils.isKnownNormalizedPreciseReferencePng(
          output,
          mode: PreciseReferenceImageMode.directorCanvas,
        ),
        isFalse,
      );
    });

    test('landscape images use the matching 1 MP aspect bucket', () {
      final output = NAIApiUtils.ensureV5BucketedPng(_png(200, 100));
      final decoded = img.decodePng(output)!;

      expect((decoded.width, decoded.height), (1408, 704));
    });

    test('square images use the 1024 square bucket', () {
      final output = NAIApiUtils.ensureV5BucketedPng(_png(100, 100));
      final decoded = img.decodePng(output)!;

      expect((decoded.width, decoded.height), (1024, 1024));
    });

    test('cover-crops instead of padding wide images', () {
      final output = NAIApiUtils.ensureV5BucketedPng(_png(300, 100));
      final decoded = img.decodePng(output)!;

      expect(decoded.width, 1728);
      expect(decoded.height, 576);
    });
  });
}
