import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/local_onnx_model_service.dart';
import '../../data/services/pixai_tagger_download_service.dart';
import 'reverse_prompt_provider.dart';

enum PixaiTaggerDownloadStatus { idle, running, completed, failed }

class PixaiTaggerDownloadState {
  const PixaiTaggerDownloadState({
    this.status = PixaiTaggerDownloadStatus.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.currentFileName = '',
    this.error,
  });

  final PixaiTaggerDownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final String currentFileName;
  final String? error;

  double get progress => totalBytes <= 0
      ? 0
      : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  PixaiTaggerDownloadState copyWith({
    PixaiTaggerDownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? currentFileName,
    String? error,
    bool clearError = false,
  }) {
    return PixaiTaggerDownloadState(
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      currentFileName: currentFileName ?? this.currentFileName,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class PixaiTaggerDownloadNotifier
    extends StateNotifier<PixaiTaggerDownloadState> {
  PixaiTaggerDownloadNotifier(this._ref) : super(const PixaiTaggerDownloadState());

  final Ref _ref;

  PixaiTaggerDownloadService get _service =>
      _ref.read(pixaiTaggerDownloadServiceProvider);

  /// Starts (or attaches to) the preset download and selects the model in the
  /// reverse prompt panel once it completes.
  Future<void> start() async {
    if (state.status == PixaiTaggerDownloadStatus.running) {
      return;
    }
    state = state.copyWith(
      status: PixaiTaggerDownloadStatus.running,
      receivedBytes: 0,
      totalBytes: PixaiTaggerDownloadService.spec.totalBytes,
      clearError: true,
    );
    try {
      await _service.download(
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          state = state.copyWith(
            receivedBytes: progress.receivedBytes,
            totalBytes: progress.totalBytes,
            currentFileName: progress.currentFileName,
          );
        },
      );
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        status: PixaiTaggerDownloadStatus.completed,
        receivedBytes: PixaiTaggerDownloadService.spec.totalBytes,
      );
      await _selectInstalledModel();
    } catch (error) {
      if (!mounted) {
        return;
      }
      state = state.copyWith(
        status: PixaiTaggerDownloadStatus.failed,
        error: error.toString(),
      );
    }
  }

  Future<void> _selectInstalledModel() async {
    final modelService = _ref.read(localOnnxModelServiceProvider);
    final models = await modelService.scanTaggerModels();
    for (final model in models) {
      if (model.kind != LocalOnnxModelKind.pixaiTagger) {
        continue;
      }
      await _ref
          .read(reversePromptProvider.notifier)
          .setSelectedTaggerModelPath(model.path);
      return;
    }
  }

  /// Cancels the active download; partial files stay resumable.
  void cancel() {
    _service.cancel();
  }

  void resetToIdle() {
    if (state.status == PixaiTaggerDownloadStatus.running) {
      return;
    }
    state = const PixaiTaggerDownloadState();
  }
}

final pixaiTaggerDownloadProvider =
    StateNotifierProvider<PixaiTaggerDownloadNotifier, PixaiTaggerDownloadState>(
      (ref) => PixaiTaggerDownloadNotifier(ref),
    );
