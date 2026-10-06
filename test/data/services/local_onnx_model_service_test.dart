import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/services/local_onnx_model_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late Directory supportDirectory;
  late LocalStorageService storage;
  late LocalOnnxModelService service;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'local_onnx_model_service_test_',
    );
    supportDirectory = await Directory(
      p.join(tempDirectory.path, 'support'),
    ).create(recursive: true);
    PathProviderPlatform.instance = _TestPathProviderPlatform(
      supportPath: supportDirectory.path,
      temporaryPath: p.join(tempDirectory.path, 'cache'),
    );
    Hive.init(p.join(tempDirectory.path, 'hive'));
    await Hive.openBox(StorageKeys.settingsBox);
    storage = LocalStorageService();
    service = LocalOnnxModelService(storage);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'imports selected model files atomically into managed storage',
    () async {
      final sourceDirectory = await Directory(
        p.join(tempDirectory.path, 'picked'),
      ).create();
      final model = await File(
        p.join(sourceDirectory.path, 'model.onnx'),
      ).writeAsBytes([1, 2, 3, 4]);
      final labels = await File(
        p.join(sourceDirectory.path, 'selected_tags.csv'),
      ).writeAsString('name,category\ntag,0\n');

      final count = await service.importTaggerFiles([
        LocalOnnxImportSource(name: 'model.onnx', path: model.path),
        LocalOnnxImportSource(name: 'selected_tags.csv', path: labels.path),
      ]);

      final managedDirectory = await service.getManagedTaggerDirectory();
      expect(count, 2);
      expect(await File(p.join(managedDirectory, 'model.onnx')).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(
        await File(
          p.join(managedDirectory, 'selected_tags.csv'),
        ).readAsString(),
        contains('tag,0'),
      );
      expect(service.taggerDirectory, managedDirectory);
      expect(
        Directory(managedDirectory).listSync().whereType<Directory>().where(
          (entry) => p.basename(entry.path).startsWith('.import-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'recovers an interrupted replacement before the next operation',
    () async {
      final managedDirectory = Directory(
        await service.getManagedTaggerDirectory(),
      );
      await managedDirectory.create(recursive: true);
      final destination = await File(
        p.join(managedDirectory.path, 'model.onnx'),
      ).writeAsString('partially committed replacement');
      final transaction = await Directory(
        p.join(managedDirectory.path, '.import-interrupted'),
      ).create();
      final backupDirectory = await Directory(
        p.join(transaction.path, 'backup'),
      ).create();
      await Directory(p.join(transaction.path, 'staged')).create();
      await File(
        p.join(backupDirectory.path, 'model.onnx'),
      ).writeAsString('previous model');
      await File(p.join(transaction.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'phase': 'committing',
          'previousDirectory': 'previous/location',
          'entries': [
            {'fileName': 'model.onnx', 'hadDestination': true},
          ],
        }),
      );
      await service.setTaggerDirectory(managedDirectory.path);

      final count = await service.managedFileCount();

      expect(count, 1);
      expect(await destination.readAsString(), 'previous model');
      expect(service.taggerDirectory, 'previous/location');
      expect(await transaction.exists(), isFalse);
    },
  );

  test(
    'rejects duplicate destination names before changing managed files',
    () async {
      final first = await File(
        p.join(tempDirectory.path, 'first.onnx'),
      ).writeAsBytes([1]);
      final second = await File(
        p.join(tempDirectory.path, 'second.onnx'),
      ).writeAsBytes([2]);

      await expectLater(
        service.importTaggerFiles([
          LocalOnnxImportSource(name: 'MODEL.onnx', path: first.path),
          LocalOnnxImportSource(name: 'model.onnx', path: second.path),
        ]),
        throwsA(isA<FormatException>()),
      );

      final managedDirectory = Directory(
        await service.getManagedTaggerDirectory(),
      );
      expect(
        managedDirectory.existsSync() ? managedDirectory.listSync() : const [],
        isEmpty,
      );
      expect(service.taggerDirectory, isEmpty);
    },
  );

  test(
    'discovers CL Tagger v2 vocabulary beside an external-data model',
    () async {
      final modelDirectory = await Directory(
        p.join(tempDirectory.path, 'cl_tagger_v2', 'v2_01a'),
      ).create(recursive: true);
      final model = await File(
        p.join(modelDirectory.path, 'model.onnx'),
      ).writeAsBytes([1]);
      await File('${model.path}.data').writeAsBytes([2]);
      final vocabulary = await File(
        p.join(modelDirectory.path, 'model_vocabulary.json'),
      ).writeAsString('{"idx_to_tag":{"0":"1girl"}}');
      await service.setTaggerDirectory(modelDirectory.path);

      final models = await service.scanTaggerModels();

      expect(models, hasLength(1));
      expect(models.single.path, model.path);
      expect(models.single.kind, LocalOnnxModelKind.clTaggerV2);
      expect(models.single.labelsPath, vocabulary.path);
    },
  );

  test('recognizes the AnimeTimm EVA02 model family', () async {
    for (final layout in const [
      (
        directory: 'reported_names',
        model: 'eva02_large_patch14.onnx',
        labels: 'eva02_large_patch14.csv',
      ),
      (
        directory: 'eva02_large_patch14_448.dbv4-full',
        model: 'model.onnx',
        labels: 'selected_tags.csv',
      ),
    ]) {
      final modelDirectory = await Directory(
        p.join(tempDirectory.path, 'animetimm', layout.directory),
      ).create(recursive: true);
      final model = await File(
        p.join(modelDirectory.path, layout.model),
      ).writeAsBytes([1]);
      final labels = await File(
        p.join(modelDirectory.path, layout.labels),
      ).writeAsString('name,category,best_threshold\n1girl,0,0.4\n');
      await service.setTaggerDirectory(modelDirectory.path);

      final models = await service.scanTaggerModels();

      expect(models, hasLength(1));
      expect(models.single.path, model.path);
      expect(models.single.kind, LocalOnnxModelKind.animeTimmEva02);
      expect(models.single.labelsPath, labels.path);
    }
  });

  test(
    'discovers PixAI tagger inside a managed subdirectory via tags.json',
    () async {
      final managedDirectory = await Directory(
        await service.getManagedTaggerDirectory(),
      ).create(recursive: true);
      final pixaiDirectory = await Directory(
        p.join(managedDirectory.path, 'pixai-tagger-v1.0'),
      ).create();
      final model = await File(
        p.join(pixaiDirectory.path, 'model.onnx'),
      ).writeAsBytes([1, 2, 3]);
      await File('${model.path}.data').writeAsBytes([4, 5]);
      final tags = await File(
        p.join(pixaiDirectory.path, 'tags.json'),
      ).writeAsString(
        '{"num_classes":1,"categories":[{"name":"general","offset":0,'
        '"count":1,"tags":["1girl"]}]}',
      );
      // 一层子目录之外的旧模型也要继续可见。
      await File(
        p.join(managedDirectory.path, 'wd14.onnx'),
      ).writeAsBytes([9]);
      await File(
        p.join(managedDirectory.path, 'selected_tags.csv'),
      ).writeAsString('name,category\n1girl,0\n');
      await service.setTaggerDirectory(managedDirectory.path);

      final models = await service.scanTaggerModels();

      expect(models, hasLength(2));
      final pixai = models.singleWhere(
        (candidate) => candidate.kind == LocalOnnxModelKind.pixaiTagger,
      );
      expect(pixai.path, model.path);
      expect(pixai.labelsPath, tags.path);
    },
  );

  test(
    'scans the managed directory even when no model directory is configured',
    () async {
      // 一键下载只写入托管目录；从未配置/导入过的安装也必须能看到。
      final managedDirectory = await Directory(
        await service.getManagedTaggerDirectory(),
      ).create(recursive: true);
      final pixaiDirectory = await Directory(
        p.join(managedDirectory.path, 'pixai-tagger-v1.0'),
      ).create();
      await File(
        p.join(pixaiDirectory.path, 'model.onnx'),
      ).writeAsBytes([1]);
      await File(
        p.join(pixaiDirectory.path, 'tags.json'),
      ).writeAsString(
        '{"num_classes":1,"categories":[{"name":"general","offset":0,'
        '"count":1,"tags":["1girl"]}]}',
      );

      expect(service.taggerDirectory, isEmpty);
      final models = await service.scanTaggerModels();

      expect(models, hasLength(1));
      expect(models.single.kind, LocalOnnxModelKind.pixaiTagger);
    },
  );

  test('merges models from a custom directory and the managed directory',
      () async {
    final managedDirectory = await Directory(
      await service.getManagedTaggerDirectory(),
    ).create(recursive: true);
    await File(
      p.join(managedDirectory.path, 'model.onnx'),
    ).writeAsBytes([1]);
    await File(
      p.join(managedDirectory.path, 'tags.json'),
    ).writeAsString(
      '{"num_classes":1,"categories":[{"name":"general","offset":0,'
      '"count":1,"tags":["1girl"]}]}',
    );
    final customDirectory = await Directory(
      p.join(tempDirectory.path, 'custom-models'),
    ).create();
    await File(p.join(customDirectory.path, 'wd14.onnx')).writeAsBytes([2]);
    await File(
      p.join(customDirectory.path, 'selected_tags.csv'),
    ).writeAsString('name,category\n1girl,0\n');
    await service.setTaggerDirectory(customDirectory.path);

    final models = await service.scanTaggerModels();

    expect(models.map((model) => model.kind), containsAll(<LocalOnnxModelKind>[
      LocalOnnxModelKind.pixaiTagger,
      LocalOnnxModelKind.wd14Tagger,
    ]));
  });

  test(
    'rejects unsupported files selected by an unrestricted picker',
    () async {
      final unsupported = await File(
        p.join(tempDirectory.path, 'unrelated.zip'),
      ).writeAsBytes([1, 2, 3]);

      await expectLater(
        service.importTaggerFiles([
          LocalOnnxImportSource(name: 'unrelated.zip', path: unsupported.path),
        ]),
        throwsA(isA<FormatException>()),
      );

      final managedDirectory = Directory(
        await service.getManagedTaggerDirectory(),
      );
      expect(
        managedDirectory.existsSync() ? managedDirectory.listSync() : const [],
        isEmpty,
      );
      expect(service.taggerDirectory, isEmpty);
    },
  );

  test('imports supported model files from a ZIP archive', () async {
    final labels = utf8.encode('name,category\ntag,0\n');
    final archive = Archive()
      ..addFile(ArchiveFile('tagger/model.onnx', 4, [1, 2, 3, 4]))
      ..addFile(ArchiveFile('tagger/selected_tags.csv', labels.length, labels))
      ..addFile(ArchiveFile('tagger/README.md', 7, utf8.encode('ignored')));
    final zip = await File(
      p.join(tempDirectory.path, 'tagger.zip'),
    ).writeAsBytes(ZipEncoder().encode(archive)!);

    final count = await service.importTaggerSelections([
      LocalOnnxImportSource(name: 'tagger.zip', path: zip.path),
    ]);

    final managedDirectory = await service.getManagedTaggerDirectory();
    expect(count, 2);
    expect(await File(p.join(managedDirectory, 'model.onnx')).readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    expect(
      await File(p.join(managedDirectory, 'selected_tags.csv')).readAsString(),
      contains('tag,0'),
    );
    expect(service.taggerDirectory, managedDirectory);
    expect(Directory(p.join(tempDirectory.path, 'cache')).listSync(), isEmpty);
  });

  test('rejects duplicate flattened names in a ZIP archive', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('first/model.onnx', 1, [1]))
      ..addFile(ArchiveFile('second/model.onnx', 1, [2]));
    final zip = await File(
      p.join(tempDirectory.path, 'duplicate.zip'),
    ).writeAsBytes(ZipEncoder().encode(archive)!);

    await expectLater(
      service.importTaggerSelections([
        LocalOnnxImportSource(name: 'duplicate.zip', path: zip.path),
      ]),
      throwsA(isA<FormatException>()),
    );

    final managedDirectory = Directory(
      await service.getManagedTaggerDirectory(),
    );
    expect(
      managedDirectory.existsSync() ? managedDirectory.listSync() : const [],
      isEmpty,
    );
  });
}

class _TestPathProviderPlatform extends PathProviderPlatform {
  _TestPathProviderPlatform({
    required this.supportPath,
    required this.temporaryPath,
  });

  final String supportPath;
  final String temporaryPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async {
    await Directory(temporaryPath).create(recursive: true);
    return temporaryPath;
  }
}
