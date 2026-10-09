import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/datasources/remote/danbooru_api_service.dart';
import 'package:nai_launcher/data/services/artist_showcase_service.dart';

void main() {
  group('ArtistShowcaseService.normalizeTagName', () {
    test('把提示词里的常见写法归一成 Danbooru 标签', () {
      expect(ArtistShowcaseService.normalizeTagName('  Wlop '), 'wlop');
      expect(
        ArtistShowcaseService.normalizeTagName('krenz cushart'),
        'krenz_cushart',
      );
      expect(ArtistShowcaseService.normalizeTagName('{wlop}'), 'wlop');
      expect(ArtistShowcaseService.normalizeTagName('[wlop],'), 'wlop');
      expect(
        ArtistShowcaseService.normalizeTagName('name (artist)'),
        'name_(artist)',
      );
      expect(ArtistShowcaseService.normalizeTagName(' , '), '');
      // 提示词里常见的画师写法：`artist:` 前缀与权重壳都要去掉。
      expect(ArtistShowcaseService.normalizeTagName('artist:wlop'), 'wlop');
      expect(
        ArtistShowcaseService.normalizeTagName('artist: yunsang'),
        'yunsang',
      );
      expect(ArtistShowcaseService.normalizeTagName('artist=wlop'), 'wlop');
      expect(
        ArtistShowcaseService.normalizeTagName('1.2::yunsang::'),
        'yunsang',
      );
      expect(ArtistShowcaseService.normalizeTagName('-1::wlop::'), 'wlop');
      expect(ArtistShowcaseService.normalizeTagName(''), '');
    });
  });

  group('ArtistShowcaseService.findTopWork', () {
    test('按 order:score 取最高分作品并映射代表作', () async {
      final adapter = _PostsAdapter(payload: [_post()]);
      final service = _service(adapter);

      final showcase = await service.findTopWork(' Wlop ');

      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.queryParameters['tags'],
        'wlop order:score',
      );
      // 一次多取几条，好在里面挑出第一张能显示的图。
      expect(adapter.requests.single.queryParameters['limit'], 8);
      expect(showcase, isNotNull);
      expect(showcase!.artistTag, 'wlop');
      expect(showcase.postId, 777);
      expect(showcase.imageUrl, 'https://cdn.test/sample.jpg');
      expect(showcase.previewUrl, 'https://cdn.test/preview.jpg');
      expect(showcase.score, 4321);
      expect(showcase.width, 800);
      expect(showcase.height, 1200);
      expect(showcase.postUrl, contains('/posts/777'));
    });

    test('空结果与失败都返回 null，只有成功结果进入缓存', () async {
      final emptyAdapter = _PostsAdapter(payload: const []);
      final emptyService = _service(emptyAdapter);

      expect(await emptyService.findTopWork('nobody'), isNull);
      expect(await emptyService.findTopWork('nobody'), isNull);
      // 最高分没结果时退回最新作品再试一次，随后按空结果缓存。
      expect(emptyAdapter.requests, hasLength(2));
      expect(
        emptyAdapter.requests.first.queryParameters['tags'],
        'nobody order:score',
      );
      expect(emptyAdapter.requests.last.queryParameters['tags'], 'nobody');

      final failingAdapter = _PostsAdapter(fail: true);
      final failingService = _service(failingAdapter);

      expect(await failingService.findTopWork('wlop'), isNull);
      // 失败不缓存，下一次悬浮仍会重试。
      expect(await failingService.findTopWork('wlop'), isNull);
      expect(failingAdapter.requests, hasLength(2));
    });

    test('最高分是视频时直接返回视频作品', () async {
      final adapter = _PostsAdapter(payload: [_videoPost(900), _post()]);
      final service = _service(adapter);

      final showcase = await service.findTopWork('wlop');

      expect(showcase, isNotNull);
      expect(showcase!.postId, 900);
      expect(showcase.isVideo, isTrue);
      expect(showcase.imageUrl, endsWith('.mp4'));
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.queryParameters['limit'], 8);
    });

    test('file_ext 缺失时按媒体地址后缀识别视频', () async {
      final adapter = _PostsAdapter(payload: [_videoPostWithoutExt(902)]);
      final service = _service(adapter);

      final showcase = await service.findTopWork('wlop');

      expect(showcase, isNotNull);
      expect(showcase!.postId, 902);
      expect(showcase.isVideo, isTrue);
    });

    test('没有任何可用媒体地址的作品会被跳过', () async {
      final adapter = _PostsAdapter(payload: [_postWithoutImages(), _post()]);
      final service = _service(adapter);

      final showcase = await service.findTopWork('wlop');

      expect(showcase, isNotNull);
      expect(showcase!.postId, 777);
    });
    test('缺少可用图片线索时返回 null', () async {
      final adapter = _PostsAdapter(payload: [_postWithoutImages()]);
      final service = _service(adapter);

      expect(await service.findTopWork('wlop'), isNull);
    });

    test('按 Danbooru 标签分类判断画师，并用精确名字比对', () async {
      final adapter = _PostsAdapter(payload: [_post()]);
      final service = _service(adapter);

      expect(await service.isArtistTag(' Wlop '), isTrue);
      expect(adapter.requests.single.path, endsWith('/tags.json'));
      expect(adapter.requests.single.queryParameters['search[category]'], 1);

      // 分类过滤命中的是别的画师标签时不算，避免误判普通标签。
      final otherAdapter = _PostsAdapter(
        payload: [_post()],
        artistTags: const ['krenz_cushart'],
      );
      expect(await _service(otherAdapter).isArtistTag('krenz'), isFalse);

      // 判定结果按会话缓存，重复悬浮不再打接口。
      await service.isArtistTag('wlop');
      expect(
        adapter.requests.where(
          (request) => request.path.endsWith('/tags.json'),
        ),
        hasLength(1),
      );
    });

    test('判定为画师后才查询代表作', () async {
      final adapter = _PostsAdapter(payload: [_post()]);
      final service = _service(adapter);

      expect(await service.isArtistTag('1girl'), isFalse);
      expect(
        adapter.requests.where(
          (request) => request.path.endsWith('/posts.json'),
        ),
        isEmpty,
      );
    });

    test('标签归一化后为空时直接返回，不请求接口', () async {
      final adapter = _PostsAdapter(payload: [_post()]);
      final service = _service(adapter);

      expect(await service.findTopWork('   '), isNull);
      expect(await service.findTopWork(' , '), isNull);
      expect(adapter.requests, isEmpty);
    });
  });
}

ArtistShowcaseService _service(HttpClientAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ArtistShowcaseService(DanbooruApiService(dio));
}

Map<String, dynamic> _post() => {
  'id': 777,
  'image_width': 800,
  'image_height': 1200,
  'preview_file_url': 'https://cdn.test/preview.jpg',
  'large_file_url': 'https://cdn.test/sample.jpg',
  'file_url': 'https://cdn.test/original.jpg',
  'score': 4321,
  'tag_string': 'wlop',
};

/// Danbooru 的视频帖：没有 sample 图，只有 mp4 原片。
Map<String, dynamic> _videoPost(int id) => {
  'id': id,
  'image_width': 1920,
  'image_height': 1080,
  'file_url': 'https://cdn.test/${id}.mp4',
  'file_ext': 'mp4',
  'score': 999,
  'tag_string': 'wlop',
};

/// 没有 file_ext、但媒体地址是 mp4 的视频帖。
Map<String, dynamic> _videoPostWithoutExt(int id) => {
  'id': id,
  'image_width': 1920,
  'image_height': 1080,
  'file_url': 'https://cdn.test/original/$id.mp4',
  'score': 999,
  'tag_string': 'wlop',
};

Map<String, dynamic> _postWithoutImages() => {
  'id': 778,
  'image_width': 800,
  'image_height': 1200,
  'score': 12,
  'tag_string': 'wlop',
};

class _PostsAdapter implements HttpClientAdapter {
  _PostsAdapter({
    this.payload = const [],
    this.artistTags = const ['wlop'],
    this.fail = false,
  });

  final List<Object?> payload;

  /// `/tags.json` 返回的画师标签名（分类过滤后的结果）。
  final List<String> artistTags;
  final bool fail;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (fail) {
      throw DioException(requestOptions: options, message: 'network down');
    }
    final body = options.path.endsWith('/tags.json')
        ? artistTags
              .map(
                (name) => {
                  'name': name,
                  'category': 1,
                  'post_count': 10,
                  'last_updated': 0,
                },
              )
              .toList()
        : payload;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
