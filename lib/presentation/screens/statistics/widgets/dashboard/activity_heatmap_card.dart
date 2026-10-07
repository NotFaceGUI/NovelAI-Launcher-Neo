import 'package:flutter/material.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';

import '../../../../../data/models/gallery/daily_trend_statistics.dart';
import '../cards/chart_card.dart';
import '../charts/heatmap_chart.dart';

/// 活动热力图卡片 - GitHub 风格 26 周活动热力图
///
/// 网格按周列对齐（周一为行首），带月份标签与月间隙；
/// 摘要行展示区间总量与单日最高。
class ActivityHeatmapCard extends StatelessWidget {
  static const _heatmapWeeks = 52;
  static const _cellSpacing = 3.0;
  static const _monthGapWidth = 6.0;
  static const _dayLabelWidth = 36.0;

  final List<DailyTrendStatistics> dailyTrends;

  const ActivityHeatmapCard({super.key, required this.dailyTrends});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (dailyTrends.isEmpty) {
      return ChartCard(
        title: l10n.statistics_chartActivityHeatmap,
        titleIcon: Icons.grid_on_outlined,
        child: ChartEmptyState(title: l10n.statistics_noData),
      );
    }

    // 统计每日图片数量
    final dateCounts = <DateTime, int>{};
    for (final trend in dailyTrends) {
      final date = DateTime(trend.date.year, trend.date.month, trend.date.day);
      dateCounts[date] = (dateCounts[date] ?? 0) + trend.count;
    }

    final heatmap = generateHeatmapData(
      dateCounts,
      weeks: _heatmapWeeks,
    );

    return ChartCard(
      title: l10n.statistics_chartActivityHeatmap,
      titleIcon: Icons.grid_on_outlined,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 主图占满整行：可用宽度扣除星期标签与月份间隙后均分给 52 周，
          // 让网格两端对齐卡片内容区；窄屏(1 列布局)退化为横向滚动。
          final monthGaps = heatmap.monthStarts
              .where((start) => start.weekIndex > 0)
              .length;
          final available =
              constraints.maxWidth -
              _dayLabelWidth -
              monthGaps * _monthGapWidth;
          final slotExtent = (available / _heatmapWeeks).clamp(10.0, 26.0);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HeatmapChart(
                data: heatmap.data,
                cellCounts: heatmap.counts,
                cellDates: heatmap.dates,
                monthStarts: heatmap.monthStarts,
                cellSize: slotExtent - _cellSpacing,
                cellSpacing: _cellSpacing,
                todayPosition: heatmap.todayPosition,
              ),
              const SizedBox(height: 14),
              _buildSummary(context, l10n, heatmap),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummary(
    BuildContext context,
    AppLocalizations l10n,
    HeatmapResult heatmap,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 区间内单日最高
    var bestCount = 0;
    DateTime? bestDay;
    for (var week = 0; week < heatmap.counts.length; week++) {
      for (var day = 0; day < heatmap.counts[week].length; day++) {
        final count = heatmap.counts[week][day];
        final date = heatmap.dates[week][day];
        if (count > bestCount && date != null) {
          bestCount = count;
          bestDay = date;
        }
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.statistics_heatmapSummary(
              _heatmapWeeks,
              heatmap.totalInRange,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (bestDay != null && bestCount > 0) ...[
            Text(
              '·',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              l10n.statistics_heatmapBestDay(bestCount),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
