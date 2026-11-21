import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import 'zh_dictionary_models.dart';

const ffdkjRepositoryUrl =
    'https://github.com/ffdkj/ffdkj-Danbooru_Tag-Chinese-English-Translation-Table';

const _repositoryPath =
    'ffdkj/ffdkj-Danbooru_Tag-Chinese-English-Translation-Table';
const _latestCommitApiUrl =
    'https://api.github.com/repos/$_repositoryPath/commits?path=tag.sqlite&sha=main&per_page=1';
const _commitFeedUrl =
    'https://github.com/$_repositoryPath/commits/main/tag.sqlite.atom';

final _commitFeedIdPattern = RegExp(
  r'Grit::Commit/([0-9a-f]{40})',
  caseSensitive: false,
);

final ffdkjPinnedSource = ZhDictionarySource(
  commitSha: '3049e201002a64702873d7f9f3cc7cb8c45ea325',
  blobSha: '3d74447ca001cd2cb7ba59e30aec441614f24551',
  sha256: 'cd7aa3fa9a2b6153b04a1bce88f98ab3381c20bdabb6348b5fbf1005dad00870',
  size: 22437888,
  downloadUri: Uri.parse(
    'https://raw.githubusercontent.com/$_repositoryPath/'
    '3049e201002a64702873d7f9f3cc7cb8c45ea325/tag.sqlite',
  ),
);

class ZhDictionaryDownloader {
  ZhDictionaryDownloader({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Future<ZhDictionarySource> fetchLatestSource({
    CancelToken? cancelToken,
  }) async {
    try {
      return await _fetchLatestFromApi(cancelToken: cancelToken);
    } on DioException catch (error, stack) {
      if (CancelToken.isCancel(error)) rethrow;
      return _fetchLatestFromCommitFeed(
        cancelToken: cancelToken,
        primary: _fromDio(
          error,
          stack,
          stage: ZhDictionaryFailureStage.metadata,
        ),
      );
    } on ZhDictionaryException catch (error) {
      return _fetchLatestFromCommitFeed(
        cancelToken: cancelToken,
        primary: error,
      );
    } catch (error, stack) {
      return _fetchLatestFromCommitFeed(
        cancelToken: cancelToken,
        primary: ZhDictionaryException(
          stage: ZhDictionaryFailureStage.metadata,
          kind: ZhDictionaryFailureKind.invalidData,
          diagnostic: 'Metadata parsing failed: $error\n$stack',
        ),
      );
    }
  }

  Future<ZhDictionarySource> _fetchLatestFromApi({
    CancelToken? cancelToken,
  }) async {
    final commitResponse = await _dio.get<List<dynamic>>(
      _latestCommitApiUrl,
      cancelToken: cancelToken,
      options: Options(headers: _apiHeaders),
    );
    final commits = commitResponse.data;
    if (commits == null || commits.isEmpty || commits.first is! Map) {
      throw const FormatException('GitHub returned empty commit metadata');
    }
    final commitSha = (commits.first as Map)['sha'] as String?;
    if (!_isGitSha(commitSha)) {
      throw const FormatException('GitHub returned an invalid commit SHA');
    }

    final contentsUri = Uri.https(
      'api.github.com',
      '/repos/$_repositoryPath/contents/tag.sqlite',
      {'ref': commitSha},
    );
    final contentsResponse = await _dio.get<Map<String, dynamic>>(
      contentsUri.toString(),
      cancelToken: cancelToken,
      options: Options(headers: _apiHeaders),
    );
    final data = contentsResponse.data;
    if (data == null || data['path'] != 'tag.sqlite') {
      throw const FormatException('GitHub returned invalid file metadata');
    }
    final blobSha = data['sha'] as String?;
    final size = (data['size'] as num?)?.toInt();
    if (!_isGitSha(blobSha) || size == null || size <= 0) {
      throw const FormatException(
        'GitHub returned invalid file integrity metadata',
      );
    }
    final source = ZhDictionarySource(
      commitSha: commitSha!,
      blobSha: blobSha!,
      size: size,
      downloadUri: _rawUri(commitSha),
      etag: contentsResponse.headers.value('etag'),
    );
    validateSource(source);
    return source;
  }

  /// The unauthenticated Contents API is limited to 60 requests per hour and
  /// is frequently the reason update checks fail on shared networks. GitHub's
  /// commit Atom feed is served from the web host instead, so use it as the
  /// metadata fallback and discover the byte length with a raw URL HEAD. The
  /// blob SHA is then verified locally after the download.
  Future<ZhDictionarySource> _fetchLatestFromCommitFeed({
    required ZhDictionaryException primary,
    CancelToken? cancelToken,
  }) async {
    try {
      final feedResponse = await _dio.get<String>(
        _commitFeedUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            'Accept': 'application/atom+xml',
            'User-Agent': 'Aaalice-NAI-Launcher',
          },
        ),
      );
      final feed = feedResponse.data ?? '';
      final commitSha = _commitFeedIdPattern.firstMatch(feed)?.group(1);
      if (!_isGitSha(commitSha)) {
        throw const FormatException(
          'GitHub commit feed did not contain a commit SHA',
        );
      }
      _logFeedFallback(primary, commitSha!);

      var size = 0;
      String? etag;
      try {
        final head = await _dio.head<void>(
          _rawUri(commitSha).toString(),
          cancelToken: cancelToken,
          options: Options(
            headers: const {
              'Accept': 'application/octet-stream',
              'Accept-Encoding': 'identity',
              'User-Agent': 'Aaalice-NAI-Launcher',
            },
          ),
        );
        size = int.tryParse(
              head.headers.value(Headers.contentLengthHeader) ?? '',
            ) ??
            0;
        etag = head.headers.value('etag');
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        // The download itself still validates size and SQLite integrity.
        AppLogger.w(
          'ffdkj raw HEAD metadata failed; continuing without length\n'
          '${_fromDio(error, StackTrace.current, stage: ZhDictionaryFailureStage.metadata).diagnostic}',
          'ZhDictionary',
        );
      }

      final source = ZhDictionarySource(
        commitSha: commitSha,
        blobSha: null,
        size: size,
        downloadUri: _rawUri(commitSha),
        etag: etag,
      );
      validateSource(source);
      return source;
    } on DioException catch (error, stack) {
      if (CancelToken.isCancel(error)) rethrow;
      final fallback = _fromDio(
        error,
        stack,
        stage: ZhDictionaryFailureStage.metadata,
      );
      throw ZhDictionaryException(
        stage: ZhDictionaryFailureStage.metadata,
        kind: fallback.kind,
        statusCode: fallback.statusCode,
        diagnostic:
            'GitHub Contents API failed:\n${primary.diagnostic}\n\n'
            'Commit feed fallback:\n${fallback.diagnostic}',
      );
    } on ZhDictionaryException {
      rethrow;
    } catch (error, stack) {
      throw ZhDictionaryException(
        stage: ZhDictionaryFailureStage.metadata,
        kind: ZhDictionaryFailureKind.invalidData,
        diagnostic:
            'GitHub Contents API failed:\n${primary.diagnostic}\n\n'
            'Commit feed fallback failed: $error\n$stack',
      );
    }
  }

  void _logFeedFallback(ZhDictionaryException primary, String commitSha) {
    AppLogger.w(
      'ffdkj GitHub Contents API unavailable; using commit feed '
      '($commitSha)\n${primary.diagnostic}',
      'ZhDictionary',
    );
  }

  Future<void> download(
    ZhDictionarySource source,
    String targetPath, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    validateSource(source);
    try {
      await _downloadFromUri(
        source.downloadUri.toString(),
        targetPath,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        headers: const {
          'Accept': 'application/octet-stream',
          'Accept-Encoding': 'identity',
          'User-Agent': 'Aaalice-NAI-Launcher',
        },
      );
    } on DioException catch (error, stack) {
      if (CancelToken.isCancel(error)) rethrow;
      final rawFailure = _fromDio(
        error,
        stack,
        stage: ZhDictionaryFailureStage.download,
      );
      await File(targetPath).deleteIfExists();
      final blobSha = source.blobSha;
      if (blobSha == null) throw rawFailure;
      try {
        await _downloadFromUri(
          _blobApiUri(blobSha).toString(),
          targetPath,
          cancelToken: cancelToken,
          onReceiveProgress: onReceiveProgress,
          headers: const {
            'Accept': 'application/vnd.github.raw+json',
            'Accept-Encoding': 'identity',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'Aaalice-NAI-Launcher',
          },
        );
        AppLogger.w(
          'ffdkj raw download failed; GitHub blob fallback succeeded\n'
              '${rawFailure.diagnostic}',
          'ZhDictionary',
        );
      } on DioException catch (fallbackError, fallbackStack) {
        if (CancelToken.isCancel(fallbackError)) rethrow;
        final fallbackFailure = _fromDio(
          fallbackError,
          fallbackStack,
          stage: ZhDictionaryFailureStage.download,
        );
        throw ZhDictionaryException(
          stage: ZhDictionaryFailureStage.download,
          kind: fallbackFailure.kind,
          statusCode: fallbackFailure.statusCode,
          diagnostic:
              'raw attempt:\n${rawFailure.diagnostic}\n\n'
              'GitHub blob fallback:\n${fallbackFailure.diagnostic}',
        );
      }
    }
  }

  Future<void> _downloadFromUri(
    String uri,
    String targetPath, {
    required Map<String, String> headers,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) => _dio.download(
    uri,
    targetPath,
    cancelToken: cancelToken,
    onReceiveProgress: onReceiveProgress,
    options: Options(headers: headers),
  );

  @visibleForTesting
  static void validateSource(ZhDictionarySource source) {
    if (!_isGitSha(source.commitSha) ||
        (source.blobSha != null && !_isGitSha(source.blobSha))) {
      throw const ZhDictionaryException(
        stage: ZhDictionaryFailureStage.metadata,
        kind: ZhDictionaryFailureKind.invalidData,
        diagnostic: 'Source contains an invalid Git SHA',
      );
    }
    if (source.size < 0) {
      throw const ZhDictionaryException(
        stage: ZhDictionaryFailureStage.metadata,
        kind: ZhDictionaryFailureKind.invalidData,
        diagnostic: 'Source contains an invalid file size',
      );
    }
    final expected = _rawUri(source.commitSha);
    if (source.downloadUri != expected) {
      throw ZhDictionaryException(
        stage: ZhDictionaryFailureStage.metadata,
        kind: ZhDictionaryFailureKind.invalidData,
        diagnostic: 'Unexpected dictionary source URI: ${source.downloadUri}',
      );
    }
  }

  static const _apiHeaders = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Aaalice-NAI-Launcher',
  };

  static Uri _rawUri(String commitSha) => Uri.https(
    'raw.githubusercontent.com',
    '/$_repositoryPath/$commitSha/tag.sqlite',
  );

  static Uri _blobApiUri(String blobSha) =>
      Uri.https('api.github.com', '/repos/$_repositoryPath/git/blobs/$blobSha');

  static bool _isGitSha(String? value) =>
      value != null && RegExp(r'^[0-9a-f]{40}$').hasMatch(value);

  static ZhDictionaryException _fromDio(
    DioException error,
    StackTrace stack, {
    required ZhDictionaryFailureStage stage,
  }) {
    final statusCode = error.response?.statusCode;
    final headers = error.response?.headers;
    final remaining = headers?.value('x-ratelimit-remaining');
    final body = _boundedBody(error.response?.data);
    final rateLimited =
        statusCode == 429 ||
        (statusCode == 403 &&
            (remaining == '0' ||
                body.toLowerCase().contains('rate limit') ||
                headers?.value('retry-after') != null));
    final kind = rateLimited
        ? ZhDictionaryFailureKind.rateLimited
        : statusCode == 403
        ? ZhDictionaryFailureKind.accessDenied
        : statusCode == null
        ? ZhDictionaryFailureKind.network
        : ZhDictionaryFailureKind.unknown;
    final request = error.requestOptions;
    final selectedHeaders = <String, String?>{
      'x-github-request-id': headers?.value('x-github-request-id'),
      'x-ratelimit-limit': headers?.value('x-ratelimit-limit'),
      'x-ratelimit-remaining': remaining,
      'x-ratelimit-reset': headers?.value('x-ratelimit-reset'),
      'retry-after': headers?.value('retry-after'),
    }..removeWhere((_, value) => value == null);
    return ZhDictionaryException(
      stage: stage,
      kind: kind,
      statusCode: statusCode,
      diagnostic: [
        'stage=${stage.name}',
        'request=${request.method} ${request.uri}',
        'status=${statusCode ?? 'none'}',
        'type=${error.type.name}',
        'headers=${jsonEncode(selectedHeaders)}',
        if (body.isNotEmpty) 'body=$body',
        'message=${error.message}',
        'stack=$stack',
      ].join('\n'),
    );
  }

  static String _boundedBody(Object? data) {
    if (data == null) return '';
    final value = data is String ? data : jsonEncode(data);
    return value.length <= 2048 ? value : '${value.substring(0, 2048)}…';
  }
}

extension on File {
  Future<void> deleteIfExists() async {
    if (await exists()) await delete();
  }
}
