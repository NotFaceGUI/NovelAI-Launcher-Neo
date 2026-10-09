import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/cache/online_gallery_image_cache_manager.dart';
import '../../../core/utils/app_logger.dart';
import '../online_gallery/video_player_widget.dart';
import '../../../core/utils/localization_extension.dart';
import '../../../data/models/danbooru/artist_showcase.dart';

/// 画师代表作悬浮卡片：作品展示图 + 画师标签 + 评分。
///
/// 只负责静态呈现；图片走共享在线图片缓存，缺少可用图片线索时展示占位。
class ArtistShowcaseCard extends StatelessWidget {
  const ArtistShowcaseCard({
    super.key,
    required this.showcase,
    this.imageProvider,
    this.loading = false,
    this.onTap,
  });

  /// 正在加载代表作时卡片先出现，用加载动画占位。
  const ArtistShowcaseCard.loading({
    super.key,
    required this.showcase,
    this.imageProvider,
    this.onTap,
  }) : loading = true;

  final ArtistShowcase showcase;

  /// 是否处于加载态（查询代表作或图片下载中）。
  final bool loading;

  /// 点击卡片打开该作品的详情。
  final VoidCallback? onTap;

  /// 测试注入用的图片源；为空时走共享在线图片缓存。
  final ImageProvider? imageProvider;

  static const double cardWidth = 236;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ratio = showcase.width > 0 && showcase.height > 0
        ? (showcase.width / showcase.height).clamp(0.72, 1.5)
        : 1.0;

    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: cardWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: ratio,
                child: loading
                    ? ColoredBox(
                        color: colors.surfaceContainerHighest,
                        child: const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : showcase.isVideo
                    ? VideoPlayerWidget(
                        videoUrl: showcase.imageUrl,
                        muted: true,
                        showControls: false,
                      )
                    : Image(
                        image:
                            imageProvider ??
                            CachedNetworkImageProvider(
                              showcase.imageUrl,
                              cacheManager:
                                  OnlineGalleryImageCacheManager.instance,
                              cacheKey: showcase.imageUrl,
                              headers: onlineGalleryImageHeadersForUrl(
                                showcase.imageUrl,
                              ),
                            ),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        frameBuilder:
                            (context, child, frame, wasSynchronouslyLoaded) {
                              if (wasSynchronouslyLoaded || frame != null)
                                return child;
                              return ColoredBox(
                                color: colors.surfaceContainerHighest,
                                child: const Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              );
                            },
                        errorBuilder: (context, error, stackTrace) {
                          AppLogger.w(
                            'Artist showcase image failed: ${showcase.imageUrl} ($error)',
                            'ArtistShowcase',
                          );
                          return ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: Center(
                              child: Icon(
                                Icons.image_not_supported_outlined,
                                size: 22,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        showcase.artistTag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    if (showcase.score case final score?) ...[
                      const SizedBox(width: 8),
                      Text(
                        context.l10n.artistShowcase_score(score.toString()),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
