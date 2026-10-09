import '../../core/database/datasources/danbooru_tag_data_source.dart';
import '../../core/utils/app_logger.dart';
import '../datasources/remote/danbooru_api_service.dart';
import '../models/online_gallery/danbooru_post.dart';
import '../models/danbooru/artist_showcase.dart';

/// 画师代表作查询。
///
/// 只做两件事：按 `order:score` 取该画师在 Danbooru 上的最高分作品，以及把
/// 查询结果留在会话缓存里。查不到、请求失败或缺少可用图片时返回 null，
/// 由界面决定不展示任何内容（图片本体交给共享图片缓存，不落在这里）。
class ArtistShowcaseService {
  ArtistShowcaseService(this._api);

  final DanbooruApiService _api;

  /// 会话内结果缓存，含「查不到」的负结果，避免悬浮反复打接口。
  final Map<String, ArtistShowcase?> _results = {};
  final Map<String, Future<ArtistShowcase?>> _inFlight = {};

  /// 单次查询往下扫描的条数：视频等不可显示的作品会被跳过。
  static const int _scanLimit = 8;

  /// 画师分类判定缓存，同样缓存负结果。
  final Map<String, bool> _artistResults = {};
  final Map<String, Future<bool>> _artistInFlight = {};

  /// 该标签在 Danbooru 上是否属于画师分类。
  ///
  /// 用标签接口的分类过滤加精确名字比对判断：不必依赖本地标签库，也能
  /// 识别库里还没有的新画师；查不到或请求失败一律当作不是画师。
  Future<bool> isArtistTag(String tag) {
    final normalized = normalizeTagName(tag);
    if (normalized.isEmpty || !RegExp(r'[a-z0-9]').hasMatch(normalized)) {
      return Future.value(false);
    }
    final cached = _artistResults[normalized];
    if (cached != null) return Future.value(cached);
    final pending = _artistInFlight[normalized];
    if (pending != null) return pending;

    final future = _queryArtist(normalized);
    _artistInFlight[normalized] = future;
    return future.whenComplete(() => _artistInFlight.remove(normalized));
  }

  Future<bool> _queryArtist(String tag) async {
    try {
      final tags = await _api.searchTags(
        tag,
        category: TagCategory.artist.value,
        limit: 10,
      );
      final isArtist = tags.any((candidate) => candidate.name == tag);
      AppLogger.d(
        'Artist tag check for $tag: $isArtist '
            '(${tags.map((candidate) => candidate.name).take(5).join(', ')})',
        'ArtistShowcase',
      );
      _artistResults[tag] = isArtist;
      return isArtist;
    } catch (error) {
      AppLogger.w(
        'Artist tag lookup failed for $tag: $error',
        'ArtistShowcase',
      );
      return false;
    }
  }

  /// 把提示词里的标签写法归一成 Danbooru 标签名。
  ///
  /// 只做机械归一：去掉首尾的包裹符号与标点、空格转下划线并转小写；
  /// 是否真的是画师交给标签库分类判断。`name_(artist)` 这类内层括号属于
  /// 标签本身，必须保留。
  static String normalizeTagName(String raw) {
    var value = raw;
    String previous;
    do {
      previous = value;
      value = value.replaceAll(_leadingNoise, '');
      value = value.replaceAll(_trailingNoise, '');
      // 收尾的孤立右括号来自 `(tag)` 这类包裹写法；有配对左括号时保留。
      if (value.endsWith(')') && !value.contains('(')) {
        value = value.substring(0, value.length - 1);
      }
    } while (value != previous);

    // 提示词里常见的 `artist:name` 前缀与 `1.2::name::` 权重壳都不是标签名。
    value = value.replaceAll(_artistPrefix, '');
    value = value.replaceAll(_weightShell, '');
    value = value.toLowerCase().trim();
    if (value.isEmpty) return '';

    return value.replaceAll(RegExp(r'\s+'), '_');
  }

  static final RegExp _leadingNoise = RegExp(r'''^[\s\[\]{}()<>,.:;|"'`]+''');

  static final RegExp _trailingNoise = RegExp(r'''[\s\[\]{}<>,.:;|"'`]+$''');

  /// `artist:` / `artist=` 前缀。
  static final RegExp _artistPrefix = RegExp(r'^artist\s*[:=]\s*');

  /// 数值权重壳，例如 `1.2::yunsang::`、`-1::yunsang::`。
  static final RegExp _weightShell = RegExp(r'^[+-]?\d*\.?\d*::|::$');

  /// 查询画师代表作；结果（含 null）会在本次会话内缓存。
  Future<ArtistShowcase?> findTopWork(String artistTag) {
    final normalized = normalizeTagName(artistTag);
    if (normalized.isEmpty) return Future.value();

    if (_results.containsKey(normalized)) {
      return Future.value(_results[normalized]);
    }
    final pending = _inFlight[normalized];
    if (pending != null) return pending;

    final future = _query(normalized);
    _inFlight[normalized] = future;
    return future.whenComplete(() => _inFlight.remove(normalized));
  }

  /// 从上往下取第一条能直接显示图片的作品。
  ///
  /// Danbooru 的视频帖（mp4/webm）没有可用的 sample 图，直接渲染会失败，
  /// 因此按分数顺序跳过它们，找到第一张能显示的图。
  /// 从上往下取第一条有可用媒体地址的作品。
  ///
  /// 图片、动图、视频都直接用；只有媒体被隐藏、完全没有地址的作品才会
  /// 被跳过（这种作品交给谁都渲染不了）。
  ArtistShowcase? _firstDisplayable(
    String artistTag,
    List<DanbooruPost> posts,
  ) {
    for (final post in posts) {
      final showcase = ArtistShowcase.fromGalleryItem(artistTag, post);
      if (showcase != null) return showcase;
    }
    return null;
  }

  Future<ArtistShowcase?> _query(String artistTag) async {
    try {
      final posts = await _api.searchPosts(
        tags: artistTag,
        order: 'score',
        limit: _scanLimit,
      );
      var showcase = _firstDisplayable(artistTag, posts);
      if (showcase == null) {
        // 最高分那条的媒体被隐藏时，退回最新作品再找一次。
        final recent = await _api.searchPosts(
          tags: artistTag,
          limit: _scanLimit,
        );
        showcase = _firstDisplayable(artistTag, recent);
      }
      _results[artistTag] = showcase;
      return showcase;
    } catch (error) {
      // 失败不入缓存，下次悬浮可以重试。
      AppLogger.w(
        'Artist showcase lookup failed for $artistTag: $error',
        'ArtistShowcase',
      );
      return null;
    }
  }
}
