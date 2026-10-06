import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/services/verified_resumable_downloader.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/services/pixai_tagger_download_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late Directory supportDirectory;
  late LocalStorageService storage;
  late List<int> tagsBytes;
  late List<int> weightsBytes;
  late PixaiTaggerModelSpec testSpec;
  late List<Uri> requestedUris;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'pixai_tagger_download_service_test_',
    );
    supportDirectory = await Directory(
      p.join(tempDirectory.path, 'support'),
    ).create();
    PathProviderPlatform.instance = _TestPathProviderPlatform(
      supportPath: supportDirectory.path,
    );
    Hive.init(p.join(tempDirectory.path, 'hive'));
    await Hive.openBox(StorageKeys.settingsBox);
    storage = LocalStorageService();

    tagsBytes = utf8.encode('{"categories":[]}');
    weightsBytes = utf8.encode('onnx-weights');
    testSpec = PixaiTaggerModelSpec(
      id: 'pixai-test',
      displayName: 'PixAI Tagger Test',
      defaultBaseUrl: 'https://example.test/pixai-tagger-test/resolve/main',
      files: [
        PixaiTaggerFileSpec(
          fileName: 'tags.json',
          sizeBytes: tagsBytes.length,
          sha256: _sha256(tagsBytes),
        ),
        PixaiTaggerFileSpec(
          fileName: 'model.onnx',
          sizeBytes: weightsBytes.length,
          sha256: _sha256(weightsBytes),
        ),
      ],
    );
    requestedUris = [];
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  PixaiTaggerDownloadService createService({
    required Future<void> Function(Uri uri, File targetFile) onDownload,
  }) {
    requestedUris = [];
    return PixaiTaggerDownloadService(
      storage,
      preset: testSpec,
      downloader: _ScriptedDownloader((uri, targetFile, onProgress) async {
        requestedUris.add(uri);
        await onDownload(uri, targetFile);
        onProgress?.call(
          VerifiedDownloadProgress(
            receivedBytes: targetFile.lengthSync(),
            totalBytes: targetFile.lengthSync(),
            progress: 1,
            bytesPerSecond: 0,
          ),
        );
      }),
    );
  }

  test(
    'downloads preset files in order with aggregate progress and verifies',
    () async {
      final service = createService(
        onDownload: (uri, targetFile) async {
          await targetFile.writeAsBytes(
            uri.path.endsWith('tags.json') ? tagsBytes : weightsBytes,
          );
        },
      );

      final progressEvents = <double>[];
      await service.download(
        onProgress: (progress) =>
            progressEvents.add(progress.receivedBytes / progress.totalBytes),
      );

      expect(requestedUris.map((uri) => uri.toString()).toList(), [
        '${testSpec.defaultBaseUrl}/tags.json',
        '${testSpec.defaultBaseUrl}/model.onnx',
      ]);
      expect(progressEvents.last, 1.0);
      expect(await service.isInstalled(), isTrue);
      final directory = Directory(
        await service.targetDirectoryPathForTesting(),
      );
      expect(
        await File(p.join(directory.path, 'tags.json')).readAsString(),
        '{"categories":[]}',
      );
      expect(
        await File(p.join(directory.path, 'model.onnx')).readAsString(),
        'onnx-weights',
      );
      // 未配置过模型目录时，下载完成后应指向托管目录，保证扫描可见。
      expect(storage.getSetting<String>(StorageKeys.onnxTaggerModelDirectory),
          directory.parent.path);
    },
  );

  test(
    'keeps finished files when a later file fails and resumes without them',
    () async {
      var failSecondFile = true;
      final service = createService(
        onDownload: (uri, targetFile) async {
          if (uri.path.endsWith('model.onnx') && failSecondFile) {
            throw const VerifiedDownloadException(
              VerifiedDownloadFailure.checksumMismatch,
              'checksum mismatch',
            );
          }
          await targetFile.writeAsBytes(
            uri.path.endsWith('tags.json') ? tagsBytes : weightsBytes,
          );
        },
      );

      await expectLater(service.download(), throwsException);
      expect(
        requestedUris.map((uri) => uri.pathSegments.last).toList(),
        ['tags.json', 'model.onnx'],
      );
      expect(await service.isInstalled(), isFalse);

      failSecondFile = false;
      await service.download();

      // tags.json 已完成且尺寸正确，第二次不应重复下载。
      expect(
        requestedUris.map((uri) => uri.pathSegments.last).toList(),
        ['tags.json', 'model.onnx', 'model.onnx'],
      );
      expect(await service.isInstalled(), isTrue);
    },
  );

  test('rejects insecure or invalid download source overrides', () async {
    final service = PixaiTaggerDownloadService(storage, preset: testSpec);

    await expectLater(
      service.setDownloadBaseUrl('http://mirror.example/base'),
      throwsArgumentError,
    );
    await expectLater(
      service.setDownloadBaseUrl('not a url'),
      throwsArgumentError,
    );

    await service.setDownloadBaseUrl('https://mirror.example/pixai/resolve/main');
    expect(service.downloadBaseUrl, 'https://mirror.example/pixai/resolve/main');
    expect(
      service.fileUrl(testSpec.files.first).toString(),
      'https://mirror.example/pixai/resolve/main/tags.json',
    );

    await service.setDownloadBaseUrl('');
    expect(service.downloadBaseUrl, testSpec.defaultBaseUrl);
  });

  test('deleteInstalled removes the preset directory', () async {
    final service = createService(
      onDownload: (uri, targetFile) async {
        await targetFile.writeAsBytes(
          uri.path.endsWith('tags.json') ? tagsBytes : weightsBytes,
        );
      },
    );
    await service.download();
    expect(await service.isInstalled(), isTrue);

    await service.deleteInstalled();

    expect(await service.isInstalled(), isFalse);
    expect(Directory(await service.targetDirectoryPathForTesting()).existsSync(),
        isFalse);
  });
}

String _sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

class _ScriptedDownloader extends VerifiedResumableDownloader {
  _ScriptedDownloader(this._onDownload) : super(dio: Dio());

  final Future<void> Function(
    Uri uri,
    File targetFile,
    void Function(VerifiedDownloadProgress progress)? onProgress,
  ) _onDownload;

  @override
  Future<VerifiedDownloadResult> download({
    required Uri uri,
    required File targetFile,
    required int expectedSize,
    required String expectedSha256,
    void Function(VerifiedDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _onDownload(uri, targetFile, onProgress);
    return VerifiedDownloadResult(
      file: targetFile,
      length: expectedSize,
      reusedExistingFile: false,
    );
  }
}

class _TestPathProviderPlatform extends PathProviderPlatform {
  _TestPathProviderPlatform({required this.supportPath});

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}
