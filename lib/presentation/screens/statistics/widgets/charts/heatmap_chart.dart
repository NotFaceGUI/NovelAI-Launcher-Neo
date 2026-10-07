import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/themes/theme_extension.dart';

import '../../../../adaptive/interaction_policy.dart';
import '../../../../widgets/app_branch_visibility.dart';
import '../../utils/chart_colors.dart';

/// 热力图月份起始列标记。
class HeatmapMonthStart {
  /// 列索引（0 为最旧一周）
  final int weekIndex;

  /// 月份（1-12）
  final int month;

  const HeatmapMonthStart({required this.weekIndex, required this.month});
}

/// [generateHeatmapData] 的返回结果：归一化分档、真实计数与日期、布局辅助信息。
class HeatmapResult {
  /// 分档后的值矩阵 [week][dayOfWeek]，取 0 / 0.25 / 0.5 / 0.75 / 1.0
  final List<List<double>> data;

  /// 真实计数矩阵 [week][dayOfWeek]
  final List<List<int>> counts;

  /// 日期矩阵 [week][dayOfWeek]，区间外或未来日期为 null
  final List<List<DateTime?>> dates;

  /// 今日所在格（周索引, 星期索引）
  final (int, int)? todayPosition;

  /// 月份起始列，用于顶部月份标签
  final List<HeatmapMonthStart> monthStarts;

  /// 区间内生成总数
  final int totalInRange;

  const HeatmapResult({
    required this.data,
    required this.counts,
    required this.dates,
    required this.todayPosition,
    required this.monthStarts,
    required this.totalInRange,
  });
}

/// GitHub 风格活动热力图。
///
/// 交互契约：悬停只改变格子描边颜色，不改变几何；入场按列交错淡入，
/// 遵循系统"减少动态效果"设置。
class HeatmapChart extends StatefulWidget {
  /// Data matrix [week][dayOfWeek] with values 0.0 to 1.0
  final List<List<double>> data;

  /// 与 [data] 同形状的真实计数，用于 tooltip 显示准确数量
  final List<List<int>>? cellCounts;

  /// 与 [data] 同形状的单元格日期，用于 tooltip 显示日期
  final List<List<DateTime?>>? cellDates;

  /// 月份起始列（顶部标签）
  final List<HeatmapMonthStart> monthStarts;

  /// Cell size
  final double cellSize;

  /// Cell spacing
  final double cellSpacing;

  /// Show month labels
  final bool showMonthLabels;

  /// Show day labels
  final bool showDayLabels;

  /// Callback when cell is tapped
  final void Function(int week, int day, double value)? onCellTap;

  /// Animation duration
  final Duration animationDuration;

  /// Today's position (weekIndex, dayIndex) for highlighting
  final (int, int)? todayPosition;

  const HeatmapChart({
    super.key,
    required this.data,
    this.cellCounts,
    this.cellDates,
    this.monthStarts = const [],
    this.cellSize = 14,
    this.cellSpacing = 3,
    this.showMonthLabels = true,
    this.showDayLabels = true,
    this.onCellTap,
    this.animationDuration = const Duration(milliseconds: 900),
    this.todayPosition,
  });

  @override
  State<HeatmapChart> createState() => _HeatmapChartState();
}

class _HeatmapChartState extends State<HeatmapChart>
    with SingleTickerProviderStateMixin {
  static const _monthLabelRowHeight = 14.0;
  static const _monthLabelRowGap = 6.0;
  static const _monthGapWidth = 6.0;

  late AnimationController _controller;
  late Animation<double> _animation;
  int? _hoveredWeek;
  int? _hoveredDay;
  bool _reducedMotion = false;
  bool _hasPlayed = false;
  bool _wasVisible = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.animationDuration,
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面由 IndexedStack 保活：重新进入统计分支时重播列交错入场。
    final visible = AppBranchVisibility.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final shouldPlay = !_hasPlayed || (visible && !_wasVisible);
    _hasPlayed = true;
    _wasVisible = visible;
    _reducedMotion = reducedMotion;
    if (reducedMotion) {
      _controller.value = 1;
      return;
    }
    if (shouldPlay) {
      _controller.forward(from: 0);
    } else if (!visible) {
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 每列的入场区间：按列索引交错，整段共用一个 controller。
  Interval _columnInterval(int weekIndex, int totalColumns) {
    final start = totalColumns <= 1
        ? 0.0
        : (weekIndex / totalColumns) * 0.55;
    final end = (start + 0.45).clamp(0.0, 1.0);
    return Interval(start, end, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final naturalCellExtent = widget.cellSize + widget.cellSpacing;
    final minimumInteractiveExtent =
        context.interactionPolicy.minimumControlExtent;
    final needsTouchTarget =
        widget.onCellTap != null && context.interactionPolicy.touchAvailable;
    final cellExtent =
        needsTouchTarget && naturalCellExtent < minimumInteractiveExtent
        ? minimumInteractiveExtent
        : naturalCellExtent;
    final shades = ChartColors.heatmapShades(colorScheme);
    final showMonthLabels =
        widget.showMonthLabels && widget.monthStarts.isNotEmpty;
    final dayLabelsTopPadding = showMonthLabels
        ? _monthLabelRowHeight + _monthLabelRowGap
        : 0.0;

    // Use abbreviated weekday names from l10n
    final dayLabels = [
      l10n.statistics_monday,
      l10n.statistics_tuesday,
      l10n.statistics_wednesday,
      l10n.statistics_thursday,
      l10n.statistics_friday,
      l10n.statistics_saturday,
      l10n.statistics_sunday,
    ];

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showDayLabels)
                  Padding(
                    padding: EdgeInsets.only(top: dayLabelsTopPadding),
                    child: SizedBox(
                      width: 36,
                      child: Column(
                        children: List.generate(7, (dayIndex) {
                          return SizedBox(
                            height: cellExtent,
                            child: Center(
                              child: Text(
                                dayLabels[dayIndex],
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.8),
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showMonthLabels) ...[
                          _buildMonthLabels(
                            theme,
                            colorScheme,
                            cellExtent,
                          ),
                          const SizedBox(height: _monthLabelRowGap),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _buildWeekColumns(
                            theme,
                            colorScheme,
                            l10n,
                            shades,
                            cellExtent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildLegend(theme, l10n, shades),
          ],
        );
      },
    );
  }

  /// 顶部月份标签：与下方网格共用相同列宽与月间隙。
  Widget _buildMonthLabels(
    ThemeData theme,
    ColorScheme colorScheme,
    double cellExtent,
  ) {
    final locale = AppLocalizations.of(context)!.localeName;
    String monthName(int month) =>
        DateFormat.MMM(locale).format(DateTime(2022, month, 1));
    final startByWeek = {
      for (final start in widget.monthStarts) start.weekIndex: start.month,
    };

    Widget labelCell(int weekIndex) {
      final month = startByWeek[weekIndex];
      return SizedBox(
        width: cellExtent,
        height: _monthLabelRowHeight,
        child: month == null
            ? null
            : OverflowBox(
                maxWidth: cellExtent * 2.4,
                alignment: Alignment.centerLeft,
                child: Text(
                  monthName(month),
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
      );
    }

    final cells = <Widget>[];
    for (var week = 0; week < widget.data.length; week++) {
      final isNewMonth = startByWeek.containsKey(week) && week > 0;
      if (isNewMonth) {
        cells.add(const SizedBox(width: _monthGapWidth));
      }
      cells.add(labelCell(week));
    }
    return Row(children: cells);
  }

  List<Widget> _buildWeekColumns(
    ThemeData theme,
    ColorScheme colorScheme,
    AppLocalizations l10n,
    List<Color> shades,
    double cellExtent,
  ) {
    final monthStartWeeks = {
      for (final start in widget.monthStarts) start.weekIndex,
    };
    final columns = <Widget>[];
    for (var weekIndex = 0; weekIndex < widget.data.length; weekIndex++) {
      final isNewMonth = monthStartWeeks.contains(weekIndex) && weekIndex > 0;
      if (isNewMonth) {
        columns.add(const SizedBox(width: _monthGapWidth));
      }
      columns.add(
        _buildWeekColumn(
          weekIndex,
          theme,
          colorScheme,
          l10n,
          shades,
          cellExtent,
        ),
      );
    }
    return columns;
  }

  Widget _buildWeekColumn(
    int weekIndex,
    ThemeData theme,
    ColorScheme colorScheme,
    AppLocalizations l10n,
    List<Color> shades,
    double cellExtent,
  ) {
    final interval = _columnInterval(weekIndex, widget.data.length);
    final columnOpacity = _animation.drive(
      Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: interval)),
    );
    final columnOffset = _animation.drive(
      Tween<double>(begin: 6, end: 0).chain(CurveTween(curve: interval)),
    );

    return FadeTransition(
      opacity: columnOpacity,
      child: AnimatedBuilder(
        animation: columnOffset,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, columnOffset.value), child: child),
        child: Column(
          children: List.generate(7, (dayIndex) {
            final value = dayIndex < widget.data[weekIndex].length
                ? widget.data[weekIndex][dayIndex]
                : 0.0;
            final count = widget.cellCounts != null &&
                    dayIndex < widget.cellCounts![weekIndex].length
                ? widget.cellCounts![weekIndex][dayIndex]
                : null;
            final date = widget.cellDates != null &&
                    dayIndex < widget.cellDates![weekIndex].length
                ? widget.cellDates![weekIndex][dayIndex]
                : null;
            final isHovered =
                _hoveredWeek == weekIndex && _hoveredDay == dayIndex;
            final isToday =
                widget.todayPosition != null &&
                widget.todayPosition!.$1 == weekIndex &&
                widget.todayPosition!.$2 == dayIndex;

            return MouseRegion(
              onEnter: (_) => setState(() {
                _hoveredWeek = weekIndex;
                _hoveredDay = dayIndex;
              }),
              onExit: (_) => setState(() {
                _hoveredWeek = null;
                _hoveredDay = null;
              }),
              cursor: widget.onCellTap != null
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              child: Tooltip(
                message: _cellTooltip(l10n, value, count, date),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                textStyle: theme.textTheme.bodySmall,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onCellTap != null
                      ? () => widget.onCellTap!(
                          weekIndex,
                          dayIndex,
                          value,
                        )
                      : null,
                  child: SizedBox.square(
                    dimension: cellExtent,
                    child: Center(
                      child: AnimatedContainer(
                        duration: _reducedMotion
                            ? Duration.zero
                            : theme.appTheme.fastDuration,
                        curve: theme.appTheme.standardCurve,
                        width: widget.cellSize,
                        height: widget.cellSize,
                        decoration: BoxDecoration(
                          color: value > 0
                              ? ChartColors.heatmapShade(shades, value)
                              : shades.first,
                          borderRadius: BorderRadius.circular(
                            isToday ? 4 : 3,
                          ),
                          border: Border.all(
                            color: isToday
                                ? colorScheme.primary
                                : isHovered
                                ? colorScheme.primary.withValues(alpha: 0.6)
                                : colorScheme.outlineVariant.withValues(
                                    alpha: 0.3,
                                  ),
                            width: isToday ? 2 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  String _cellTooltip(
    AppLocalizations l10n,
    double value,
    int? count,
    DateTime? date,
  ) {
    if (date != null && count != null) {
      final dateText = _formatCellDate(date);
      if (count > 0) {
        return l10n.statistics_heatmapCellLabel(dateText, count);
      }
      return l10n.statistics_heatmapCellEmpty(dateText);
    }
    if (value > 0) {
      return l10n.statistics_heatmapActivities((value * 100).toInt());
    }
    return l10n.statistics_heatmapNoActivity;
  }

  String _formatCellDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sameYear = date.year == today.year;
    if (sameYear) return '${date.month}/${date.day}';
    return '${date.year}/${date.month}/${date.day}';
  }

  Widget _buildLegend(
    ThemeData theme,
    AppLocalizations l10n,
    List<Color> shades,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        _buildLegendLabel(theme, l10n.statistics_heatmapLess),
        const SizedBox(width: 4),
        ...List.generate(shades.length, (index) {
          return Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: shades[index],
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
        const SizedBox(width: 4),
        _buildLegendLabel(theme, l10n.statistics_heatmapMore),
      ],
    );
  }

  Widget _buildLegendLabel(ThemeData theme, String text) {
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );
  }
}

/// 从日期-计数映射生成 GitHub 风格热力图数据。
///
/// 网格按"周列为单位、周一为行首"对齐：最后一列是 [endDate]（默认今天）
/// 所在周，未来日期保留空格子。值按非零计数的四分位数分档，
/// 避免极端值把多数格子压成浅色。
HeatmapResult generateHeatmapData(
  Map<DateTime, int> dateCounts, {
  int weeks = 52,
  DateTime? endDate,
}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final resolvedEnd = endDate ?? now;
  final endDateDay = DateTime(
    resolvedEnd.year,
    resolvedEnd.month,
    resolvedEnd.day,
  );
  final lastWeekMonday = endDateDay.subtract(
    Duration(days: endDateDay.weekday - DateTime.monday),
  );

  final nonZeroCounts = dateCounts.values.where((c) => c > 0).toList()
    ..sort();
  double quantile(double q) {
    if (nonZeroCounts.isEmpty) return 0;
    final position = (nonZeroCounts.length - 1) * q;
    final low = position.floor();
    final high = position.ceil();
    final t = position - low;
    return nonZeroCounts[low] * (1 - t) + nonZeroCounts[high] * t;
  }

  final q25 = quantile(0.25);
  final q50 = quantile(0.5);
  final q75 = quantile(0.75);
  double levelFor(int count) {
    if (count <= 0) return 0;
    if (count <= q25) return 0.25;
    if (count <= q50) return 0.5;
    if (count <= q75) return 0.75;
    return 1.0;
  }

  final data = <List<double>>[];
  final counts = <List<int>>[];
  final dates = <List<DateTime?>>[];
  final monthStarts = <HeatmapMonthStart>[];
  (int, int)? todayPosition;
  var totalInRange = 0;
  var previousMonth = -1;

  for (var week = 0; week < weeks; week++) {
    final weekMonday = lastWeekMonday.subtract(
      Duration(days: 7 * (weeks - 1 - week)),
    );
    final weekLevels = <double>[];
    final weekCounts = <int>[];
    final weekDates = <DateTime?>[];
    for (var day = 0; day < 7; day++) {
      final date = weekMonday.add(Duration(days: day));
      final isInRange = !date.isAfter(endDateDay);
      final count = isInRange ? (dateCounts[date] ?? 0) : 0;
      weekLevels.add(levelFor(count));
      weekCounts.add(count);
      weekDates.add(isInRange ? date : null);
      if (isInRange) totalInRange += count;

      if (date.year == today.year &&
          date.month == today.month &&
          date.day == today.day) {
        todayPosition = (week, day);
      }
      if (date.day == 1 && date.month != previousMonth) {
        monthStarts.add(
          HeatmapMonthStart(weekIndex: week, month: date.month),
        );
        previousMonth = date.month;
      }
    }
    data.add(weekLevels);
    counts.add(weekCounts);
    dates.add(weekDates);
  }

  return HeatmapResult(
    data: data,
    counts: counts,
    dates: dates,
    todayPosition: todayPosition,
    monthStarts: monthStarts,
    totalInRange: totalInRange,
  );
}
