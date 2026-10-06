import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/storage_keys.dart';
import '../../core/services/verified_resumable_downloader.dart';
import '../../core/storage/local_storage_service.dart';
import 'local_onnx_model_service.dart';

/// One immutable file of a downloadable tagger preset.
class PixaiTaggerFileSpec {
  const PixaiTaggerFileSpec({
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
  });

  final String fileName;
  final int sizeBytes;
  final String sha256;
}

class PixaiTaggerModelSpec {
  const PixaiTaggerModelSpec({
    required this.id,
    required this.displayName,
    required this.defaultBaseUrl,
    required this.files,
  });

  /// pixai-labs/pixai-tagger-v1.0 的社区 ONNX 导出（Apache-2.0）。
  /// 尺寸与 SHA256 固定自 Hugging Face 的 LFS 对象，下载后逐一校验。
  static const PixaiTaggerModelSpec pixaiTaggerV1 = PixaiTaggerModelSpec(
    id: 'pixai-tagger-v1.0',
    displayName: 'PixAI Tagger v1.0',
    defaultBaseUrl:
        'https://huggingface.co/noaione/pixai-tagger-v1.0-onnx/resolve/main',
    files: [
      PixaiTaggerFileSpec(
        fileName: 'tags.json',
        sizeBytes: 816539,
        sha256: '0d34f2078016798808dc066dc206b18fb6ce7622f64241002ecd24172a4da068',
      ),
      PixaiTaggerFileSpec(
        fileName: 'model.onnx',
        sizeBytes: 2633225,
        sha256:
            '563f4576c2668560c20f403b957f0ec4a7bd6a2275da2c2aa7f82f898ad34e5c',
      ),
      PixaiTaggerFileSpec(
        fileName: 'model.onnx.data',
        sizeBytes: 1955123200,
        sha256:
            '4de1c25a38d1f2a2172fbcb0d2485b5f02a058b6e67bedd7bbbcfdf4de9329dc',
      ),
    ],
  );

  final String id;
  final String displayName;
  final String defaultBaseUrl;
  final List<PixaiTaggerFileSpec> files;

  int get totalBytes =>
      files.fold(0, (total, file) => total + file.sizeBytes);
}

class PixaiTaggerDownloadProgress {
  const PixaiTaggerDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.currentFileName,
  });

  final int receivedBytes;
  final int totalBytes;
  final String currentFileName;

  double get progress => totalBytes <= 0
      ? 0
      : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

class PixaiTaggerDownloadException implements Exception {
  const PixaiTaggerDownloadException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() =>
      details == null ? message : '$message ($details)';
}

/// Downloads the PixAI tagger preset into a dedicated subdirectory of the
/// managed tagger folder. The base URL is user-configurable so mirrors can be
/// used; every file is verified by size and SHA256 before installation.
class PixaiTaggerDownloadService {
  PixaiTaggerDownloadService(
    this._storage, {
    VerifiedResumableDownloader? downloader,
    PixaiTaggerModelSpec preset = PixaiTaggerModelSpec.pixaiTaggerV1,
  }) : _downloader = downloader ?? VerifiedResumableDownloader(dio: Dio()),
       _preset = preset;

  /// Default preset used for the initial progress display before a download.
  static const PixaiTaggerModelSpec spec = PixaiTaggerModelSpec.pixaiTaggerV1;

  /// Effective preset for this instance; tests inject a smaller one.
  final PixaiTaggerModelSpec _preset;

  final LocalStorageService _storage;
  final VerifiedResumableDownloader _downloader;
  Future<void>? _activeDownload;
  CancelToken? _cancelToken;

  /// Raw override stored by the user; empty means the default source.
  String get configuredBaseUrl =>
      _storage.getSetting<String>(StorageKeys.pixaiTaggerDownloadBaseUrl) ?? '';

  /// Effective base URL used to build file URLs.
  String get downloadBaseUrl {
    final configured = _normalizeBaseUrl(configuredBaseUrl);
    return configured ?? _preset.defaultBaseUrl;
  }

  /// Returns null when [value] is empty (reset to default) or a normalized
  /// URL, and throws [ArgumentError] when the value is a non-empty invalid or
  /// insecure base URL.
  String? _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
        trimmed,
        'baseUrl',
        'Download source must be an HTTPS URL',
      );
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Stores a custom mirror base URL. An empty [value] restores the default.
  Future<void> setDownloadBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value);
    await _storage.setSetting(
      StorageKeys.pixaiTaggerDownloadBaseUrl,
      normalized ?? '',
    );
  }

  Future<Directory> _targetDirectory() async {
    final modelService = LocalOnnxModelService(_storage);
    final managedDirectory = await modelService.getManagedTaggerDirectory();
    return Directory(p.join(managedDirectory, _preset.id));
  }

  /// Visible for tests.
  Future<String> targetDirectoryPathForTesting() async =>
      (await _targetDirectory()).path;

  Uri fileUrl(PixaiTaggerFileSpec file) =>
      Uri.parse('$downloadBaseUrl/${file.fileName}');

  /// All preset files present with their declared sizes. Byte-level integrity
  /// is guaranteed by the verified download, so no repeated hashing here.
  Future<bool> isInstalled() async {
    final directory = await _targetDirectory();
    if (!await directory.exists()) {
      return false;
    }
    for (final file in _preset.files) {
      final target = File(p.join(directory.path, file.fileName));
      if (!await target.exists() || await target.length() != file.sizeBytes) {
        return false;
      }
    }
    return true;
  }

  /// Whether a previous download left resumable partial files behind.
  Future<int> partialBytes() async {
    final directory = await _targetDirectory();
    if (!await directory.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!p.basename(entity.path).endsWith('.part')) continue;
      total += await entity.length();
    }
    return total;
  }

  Future<void> download({
    void Function(PixaiTaggerDownloadProgress progress)? onProgress,
  }) {
    if (_activeDownload != null) {
      return _activeDownload!;
    }
    final completer = Completer<void>();
    _activeDownload = completer.future;
    // 清理链单独消费结果；错误由返回给调用方的 completer.future 负责。
    completer.future
        .whenComplete(() {
          _activeDownload = null;
          _cancelToken = null;
        })
        .ignore();
    _runDownload(onProgress).then(
      completer.complete,
      onError: completer.completeError,
    );
    return completer.future;
  }

  Future<void> _runDownload(
    void Function(PixaiTaggerDownloadProgress progress)? onProgress,
  ) async {
    final directory = await _targetDirectory();
    await directory.create(recursive: true);
    // 与文件导入行为一致：未配置过模型目录时指向托管目录，
    // 避免下载完成后因目录未配置而扫描不到。
    if (_storage
        .getSetting<String>(StorageKeys.onnxTaggerModelDirectory)
        ?.trim()
        .isEmpty ??
        true) {
      await _storage.setSetting(
        StorageKeys.onnxTaggerModelDirectory,
        directory.parent.path,
      );
    }
    final token = _cancelToken = CancelToken();

    var completedBytes = 0;
    for (final file in _preset.files) {
      final target = File(p.join(directory.path, file.fileName));
      if (await target.exists() && await target.length() == file.sizeBytes) {
        completedBytes += file.sizeBytes;
        onProgress?.call(
          PixaiTaggerDownloadProgress(
            receivedBytes: completedBytes,
            totalBytes: _preset.totalBytes,
            currentFileName: file.fileName,
          ),
        );
        continue;
      }
      try {
        await _downloader.download(
          uri: fileUrl(file),
          targetFile: target,
          expectedSize: file.sizeBytes,
          expectedSha256: file.sha256,
          cancelToken: token,
          onProgress: (progress) => onProgress?.call(
            PixaiTaggerDownloadProgress(
              receivedBytes: completedBytes + progress.receivedBytes,
              totalBytes: _preset.totalBytes,
              currentFileName: file.fileName,
            ),
          ),
        );
      } on VerifiedDownloadException catch (error) {
        throw PixaiTaggerDownloadException(
          'PixAI tagger download failed: ${file.fileName}',
          details: error.toString(),
        );
      }
      completedBytes += file.sizeBytes;
    }
  }

  bool get isDownloadInProgress => _activeDownload != null;

  /// Cancels the active download. Completed files are kept and the next
  /// download resumes from the remaining `.part` files.
  void cancel() {
    _cancelToken?.cancel();
  }

  Future<void> deleteInstalled() async {
    cancel();
    if (_activeDownload != null) {
      await _activeDownload;
    }
    final directory = await _targetDirectory();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

final pixaiTaggerDownloadServiceProvider = Provider<PixaiTaggerDownloadService>((
  ref,
) {
  return PixaiTaggerDownloadService(ref.read(localStorageServiceProvider));
});
