import '../online_gallery/danbooru_post.dart';

/// 画师在 Danbooru 上的代表作摘要。
///
/// 只保留悬浮卡片需要的字段：可下载的展示图、作品页地址与评分。
class ArtistShowcase {
  const ArtistShowcase({
    required this.artistTag,
    required this.postId,
    required this.imageUrl,
    required this.previewUrl,
    required this.postUrl,
    required this.width,
    required this.height,
    this.score,
    this.isVideo = false,
    this.post,
  });

  /// 查询时使用的 Danbooru 画师标签（下划线形式）。
  final String artistTag;

  final int postId;

  /// 展示图（优先 sample）与缩略图，均为可直接下载的地址。
  final String imageUrl;
  final String previewUrl;

  final String postUrl;
  final int width;
  final int height;
  final int? score;

  /// 最高分作品是视频（mp4/webm）时，卡片改用播放器渲染。
  final bool isVideo;

  /// 打开详情用的原始条目；仅会话内使用，不参与序列化。
  final DanbooruPost? post;

  /// 从 Danbooru 作品条目构建代表作；没有可用图片时返回 null。
  static ArtistShowcase? fromGalleryItem(String artistTag, DanbooruPost item) {
    final cover = item.cover;
    final imageUrl = cover.displayUrl.isNotEmpty
        ? cover.displayUrl
        : cover.previewUrl;
    if (imageUrl.isEmpty) return null;

    return ArtistShowcase(
      artistTag: artistTag,
      postId: item.id,
      imageUrl: imageUrl,
      previewUrl: cover.previewUrl.isEmpty ? imageUrl : cover.previewUrl,
      postUrl: item.postUrl,
      width: cover.width,
      height: cover.height,
      score: item.score,
      isVideo: isVideoUrl(imageUrl),
      post: item,
    );
  }

  /// 该地址是否是需要播放器渲染的视频。
  static bool isVideoUrl(String url) {
    final match = RegExp(
      r'\.([a-z0-9]+)(?:$|\?)',
      caseSensitive: false,
    ).firstMatch(url);
    final ext = match?.group(1)?.toLowerCase() ?? '';
    return ext == 'mp4' || ext == 'webm';
  }
}
