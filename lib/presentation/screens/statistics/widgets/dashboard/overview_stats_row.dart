import 'package:flutter/material.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';

import '../../../../../data/models/gallery/gallery_statistics.dart';
import '../../utils/utils.dart';
import '../cards/metric_card.dart';

/// 概览统计区 - 基础指标 + 创作洞察维度（活跃天数 / 连续活跃 / 日均产出）
///
/// 数值首次加载与刷新时滚动到位；总图片卡带近 30 天走势与周环比。
class OverviewStatsRow extends StatelessWidget {
  final GalleryStatistics stats;

  const OverviewStatsRow({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final effectiveWidth =
            constraints.maxWidth / textScale.clamp(1.0, 3.0);
        final useCompact = effectiveWidth < 600;
        final columns = effectiveWidth < 200
            ? 1
            : effectiveWidth < 600
            ? 2
            : 3;

        final cards = _buildCards(context, useCompact);
        final rows = <Widget>[];
        for (var start = 0; start < cards.length; start += columns) {
          final rowCards = cards.skip(start).take(columns).toList();
          rows.add(
            Padding(
              padding: EdgeInsets.only(
                bottom: start + columns < cards.length ? 12 : 0,
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < rowCards.length; index++) ...[
                      if (index > 0) const SizedBox(width: 12),
                      Expanded(child: rowCards[index]),
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }

  List<Widget> _buildCards(BuildContext context, bool useCompact) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final insights = computeActivityInsights(stats.dailyTrends);
    final weekOverWeek = insights.weekOverWeekPercent;
    final favoriteRatio = stats.totalImages > 0
        ? stats.favoriteCount / stats.totalImages * 100
        : 0.0;

    return [
      MetricCard(
        icon: Icons.photo_library_outlined,
        label: l10n.statistics_totalImages,
        value: '${stats.totalImages}',
        iconColor: theme.colorScheme.primary,
        compact: useCompact,
        trend: weekOverWeek == null
            ? null
            : TrendData(
                value: weekOverWeek,
                // 紧凑单行模式下空间有限,只保留图标与百分比。
                label: useCompact ? null : l10n.statistics_weekTrend,
              ),
        sparklineData: insights.recentDailyCounts,
        valueBuilder: (style) =>
            _CountUpNumber(target: stats.totalImages, style: style),
      ),
      MetricCard(
        icon: Icons.storage_outlined,
        label: l10n.statistics_totalSize,
        value: StatisticsFormatter.formatBytes(stats.totalSizeBytes),
        iconColor: theme.colorScheme.secondary,
        compact: useCompact,
      ),
      MetricCard(
        icon: Icons.favorite_outline,
        label: l10n.statistics_favorites,
        value:
            '${stats.favoriteCount} (${favoriteRatio.toStringAsFixed(1)}%)',
        iconColor: Colors.red,
        compact: useCompact,
        valueBuilder: (style) => _CountUpSuffixNumber(
          target: stats.favoriteCount,
          suffix: ' (${favoriteRatio.toStringAsFixed(1)}%)',
          style: style,
        ),
      ),
      MetricCard(
        icon: Icons.event_available_outlined,
        label: l10n.statistics_metricActiveDays,
        value: '${insights.activeDays}',
        iconColor: const Color(0xFF10B981),
        compact: useCompact,
        valueBuilder: (style) =>
            _CountUpNumber(target: insights.activeDays, style: style),
      ),
      MetricCard(
        icon: Icons.local_fire_department_outlined,
        label: l10n.statistics_metricStreak,
        value: '${insights.currentStreak}',
        iconColor: const Color(0xFFF97316),
        compact: useCompact,
        valueBuilder: (style) =>
            _CountUpNumber(target: insights.currentStreak, style: style),
      ),
      MetricCard(
        icon: Icons.speed_outlined,
        label: l10n.statistics_metricDailyAvg,
        value: insights.dailyAverage.toStringAsFixed(1),
        iconColor: const Color(0xFF3B82F6),
        compact: useCompact,
        valueBuilder: (style) => _CountUpNumber(
          target: insights.dailyAverage,
          decimals: 1,
          style: style,
        ),
      ),
    ];
  }
}

/// 数值滚动到位的整数文本；系统减少动态效果时直接呈现终值。
class _CountUpNumber extends StatelessWidget {
  final num target;
  final int decimals;
  final TextStyle style;

  const _CountUpNumber({
    required this.target,
    required this.style,
    this.decimals = 0,
  });

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target.toDouble()),
      duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 900),
      curve: Curves.easeOutExpo,
      builder: (context, value, _) {
        final text = decimals == 0
            ? value.round().toString()
            : value.toStringAsFixed(decimals);
        return Text(text, style: style);
      },
    );
  }
}

/// 整数滚动 + 静态后缀（如收藏占比）。
class _CountUpSuffixNumber extends StatelessWidget {
  final int target;
  final String suffix;
  final TextStyle style;

  const _CountUpSuffixNumber({
    required this.target,
    required this.suffix,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final suffixStyle = style.copyWith(
      fontSize: (style.fontSize ?? 24) * 0.6,
      fontWeight: FontWeight.w600,
      color: style.color?.withValues(alpha: 0.7),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target.toDouble()),
      duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 900),
      curve: Curves.easeOutExpo,
      builder: (context, value, _) {
        return Text.rich(
          TextSpan(
            text: value.round().toString(),
            style: style,
            children: [
              TextSpan(text: suffix, style: suffixStyle),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}
