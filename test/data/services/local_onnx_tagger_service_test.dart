import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/utils/isolate_pool.dart';
import 'package:nai_launcher/data/services/local_onnx_model_service.dart';
import 'package:nai_launcher/data/services/local_onnx_tagger_preprocessor.dart';
import 'package:nai_launcher/data/services/local_onnx_tagger_service.dart';

void main() {
  group('LocalOnnxTaggerService preprocessing', () {
    test(
      'letterboxes extreme source images directly into input-sized canvas',
      () {
        final layout = LocalOnnxTaggerService.debugLetterboxLayoutForTesting(
          sourceWidth: 20000,
          sourceHeight: 1000,
          inputSize: 448,
        );

        expect(layout.canvasWidth, 448);
        expect(layout.canvasHeight, 448);
        expect(layout.resizedWidth, 448);
        expect(layout.resizedHeight, 22);
        expect(layout.offsetX, 0);
        expect(layout.offsetY, 213);
        expect(layout.canvasPixels, 448 * 448);
      },
    );

    test('uses AnimeTimm official RGB NCHW normalization profile', () {
      const descriptor = LocalOnnxModelDescriptor(
        name: 'eva02_large_patch14.onnx',
        path: 'eva02_large_patch14.onnx',
        kind: LocalOnnxModelKind.animeTimmEva02,
      );
      final source = img.Image(width: 2, height: 1);
      img.fill(source, color: img.ColorRgb8(255, 0, 0));

      final input = LocalOnnxTaggerPreprocessor.preprocess(source, descriptor);
      final profile = LocalOnnxTaggerPreprocessor.profileFor(descriptor);
      const planeSize = 448 * 448;
      const centerPixel = 224 * 448 + 224;

      expect(input.shape, [1, 3, 448, 448]);
      expect(input.data[centerPixel], closeTo(1.9303, 0.001));
      expect(input.data[planeSize + centerPixel], closeTo(-1.7521, 0.001));
      expect(input.data[planeSize * 2 + centerPixel], closeTo(-1.4802, 0.001));
      expect(input.data[planeSize], closeTo(2.0749, 0.001));
      expect(input.data[planeSize * 2], closeTo(2.1459, 0.001));
      expect(profile.normalizeScores([0]).single, closeTo(0.5, 0.000001));
    });

    test(
      'uses the PixAI 1008 letterbox with black padding and [-1, 1] range',
      () {
        const descriptor = LocalOnnxModelDescriptor(
          name: 'model.onnx',
          path: 'pixai-tagger-v1.0/model.onnx',
          kind: LocalOnnxModelKind.pixaiTagger,
        );
        final profile = LocalOnnxTaggerPreprocessor.profileFor(descriptor);
        expect(profile.inputSize, 1008);
        expect(
          profile.outputActivation,
          OnnxTaggerOutputActivation.sigmoid,
        );

        final source = img.Image(width: 1008, height: 504);
        img.fill(source, color: img.ColorRgb8(255, 255, 255));

        final input = LocalOnnxTaggerPreprocessor.preprocess(
          source,
          descriptor,
        );
        const planeSize = 1008 * 1008;
        // 源图 1008×504 居中粘贴在 y ∈ [252, 756)。
        const contentPixel = 252 * 1008 + 500;
        const paddingPixel = 251 * 1008 + 500; // 粘贴区上方的黑边。

        expect(input.shape, [1, 3, 1008, 1008]);
        expect(input.data[contentPixel], closeTo(1.0, 0.000001));
        expect(input.data[paddingPixel], closeTo(-1.0, 0.000001));
        expect(input.data[planeSize + contentPixel], closeTo(1.0, 0.000001));
        expect(input.data[planeSize * 2 + paddingPixel], closeTo(-1.0, 0.000001));
        expect(profile.normalizeScores([0]).single, closeTo(0.5, 0.000001));
      },
    );
  });

  group('LocalOnnxTaggerService PixAI tags.json', () {
    late Directory tempDirectory;
    late LocalOnnxTaggerService service;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'local_onnx_tagger_pixai_test_',
      );
      service = const LocalOnnxTaggerService();
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    Future<String> writeTagsJson(String content) async {
      final file = File(
        '${tempDirectory.path}${Platform.pathSeparator}tags.json',
      );
      await file.writeAsString(content, encoding: utf8);
      return file.path;
    }

    test('parses category offset/count layout into ordered labels', () async {
      final labelsPath = await writeTagsJson(
        jsonEncode({
          'num_classes': 5,
          'category_order': ['general', 'character'],
          'categories': [
            {
              'name': 'general',
              'offset': 0,
              'count': 3,
              'tags': ['1girl', 'solo', 'smile'],
            },
            {
              'name': 'character',
              'offset': 3,
              'count': 2,
              'tags': ['hakurei_reimu', 'hatsune_miku'],
            },
          ],
        }),
      );

      final labels = await service.loadLabels(labelsPath);

      expect(labels, hasLength(5));
      expect(labels.map((label) => label.name).toList(), [
        '1girl',
        'solo',
        'smile',
        'hakurei_reimu',
        'hatsune_miku',
      ]);
      expect(labels.first.isGeneral, isTrue);
      expect(labels[3].isCharacter, isTrue);
    });

    test('rejects offset/count layouts that do not add up', () async {
      final labelsPath = await writeTagsJson(
        jsonEncode({
          'num_classes': 6,
          'categories': [
            {
              'name': 'general',
              'offset': 0,
              'count': 3,
              'tags': ['1girl', 'solo', 'smile'],
            },
            {
              'name': 'character',
              'offset': 2,
              'count': 2,
              'tags': ['hakurei_reimu', 'hatsune_miku'],
            },
          ],
        }),
      );

      expect(await service.loadLabels(labelsPath), isEmpty);
    });

    test(
      'includes copyright and style with official thresholds and filters meta',
      () {
        final labels = [
          const OnnxTaggerLabel(name: '1girl', category: 'general'),
          const OnnxTaggerLabel(name: 'hakurei_reimu', category: 'character'),
          const OnnxTaggerLabel(name: 'touhou', category: 'copyright'),
          const OnnxTaggerLabel(name: 'bkub', category: 'style'),
          const OnnxTaggerLabel(name: 'highres', category: 'meta'),
          const OnnxTaggerLabel(name: 'rating:s', category: 'rating'),
        ];
        final scores = [0.50, 0.40, 0.25, 0.16, 0.99, 0.42];

        final tags = LocalOnnxTaggerService.debugBuildTagsForTesting(
          labels: labels,
          scores: scores,
          generalThreshold: 0.35,
          characterThreshold: 0.35,
        );

        expect(tags.map((tag) => tag.name).toList(), [
          '1girl',
          'hakurei_reimu',
          'touhou',
          'bkub',
        ]);

        final filtered = LocalOnnxTaggerService.debugBuildTagsForTesting(
          labels: labels,
          scores: [0.34, 0.34, 0.25, 0.14, 0.99, 0.42],
          generalThreshold: 0.35,
          characterThreshold: 0.35,
          includeRatings: true,
        );
        expect(
          filtered.map((tag) => tag.name),
          containsAllInOrder(['rating:s', 'touhou']),
        );
        expect(filtered.map((tag) => tag.name), isNot(contains('1girl')));
        expect(filtered.map((tag) => tag.name), isNot(contains('bkub')));
        expect(filtered.map((tag) => tag.name), isNot(contains('highres')));
      },
    );
  });

  group('LocalOnnxTaggerService session loading', () {
    test('uses a patched file session for single-file models', () {
      const descriptor = LocalOnnxModelDescriptor(
        name: 'cl_tagger_1_02',
        path: r'G:\models\cl_tagger_1_02\model.onnx',
        kind: LocalOnnxModelKind.clTagger,
      );

      expect(
        LocalOnnxTaggerService.debugSessionLoadModeForTesting(descriptor),
        OnnxSessionLoadMode.patchedSingleFile,
      );
    });

    test('keeps external-data models on external-data file sessions', () async {
      final directory = await Directory.systemTemp.createTemp(
        'nai_launcher_onnx_external_data_test_',
      );
      try {
        final modelPath =
            '${directory.path}${Platform.pathSeparator}model.onnx';
        await File(modelPath).writeAsBytes(const []);
        await File('$modelPath.data').writeAsBytes(const []);

        final descriptor = LocalOnnxModelDescriptor(
          name: 'cl_tagger_v2',
          path: modelPath,
          kind: LocalOnnxModelKind.clTaggerV2,
          labelsPath:
              '${directory.path}${Platform.pathSeparator}model_vocabulary.json',
        );

        expect(
          LocalOnnxTaggerService.debugSessionLoadModeForTesting(descriptor),
          OnnxSessionLoadMode.externalDataFile,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  group('ComputeGate', () {
    test('provides a serial gate for memory-heavy ONNX work', () {
      expect(ComputeGate.singleTask().maxConcurrentTasks, 1);
    });
  });
}
