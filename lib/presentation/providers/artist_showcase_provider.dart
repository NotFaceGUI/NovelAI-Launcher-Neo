import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/remote/danbooru_api_service.dart';
import '../../data/models/danbooru/artist_showcase.dart';
import '../../data/services/artist_showcase_service.dart';

/// 画师代表作查询服务；结果在服务内部按会话缓存。
final artistShowcaseServiceProvider = Provider<ArtistShowcaseService>(
  (ref) => ArtistShowcaseService(ref.watch(danbooruApiServiceProvider)),
);

/// 该标签在 Danbooru 上是否属于画师分类。
///
/// 分类判定走 Danbooru 标签接口并由服务内部缓存；查不到或请求失败都返回
/// false，宁可少显示，也不要为普通标签查询代表作。
final artistTagProvider = FutureProvider.family<bool, String>(
  (ref, tag) => ref.watch(artistShowcaseServiceProvider).isArtistTag(tag),
);

/// 画师代表作；Danbooru 没有收录时返回 null。
final artistShowcaseProvider = FutureProvider.family<ArtistShowcase?, String>(
  (ref, tag) => ref.watch(artistShowcaseServiceProvider).findTopWork(tag),
);
