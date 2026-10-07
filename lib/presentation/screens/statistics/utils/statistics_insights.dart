import '../../../../data/models/gallery/daily_trend_statistics.dart';

/// 从每日趋势推导的仪表盘判别维度。
///
/// 所有字段基于"近 30 天"窗口(数据不足时退化为实际覆盖范围),
/// 周环比对比"近 7 天"与"7-14 天前"两个窗口。
class ActivityInsights {
  /// 窗口内有生成的天数
  final int activeDays;

  /// 窗口覆盖的自然日数量
  final int windowDays;

  /// 当前连续活跃天数(今天未生成则从昨天起算,与常用产品的 current streak 一致)
  final int currentStreak;

  /// 窗口内单日最高生成量
  final int bestDayCount;

  /// 单日最高生成量对应的日期
  final DateTime? bestDay;

  /// 近 30 天日均产出(保留 1 位小数由展示层处理)
  final double dailyAverage;

  /// 近 7 天生成量
  final int weekCount;

  /// 上一个 7 天窗口生成量
  final int previousWeekCount;

  /// 周环比变化(百分比;上周为 0 时返回 null 表示不可比)
  final double? weekOverWeekPercent;

  /// 近 30 天每日生成量,按日期升序,用于 sparkline
  final List<double> recentDailyCounts;

  const ActivityInsights({
    required this.activeDays,
    required this.windowDays,
    required this.currentStreak,
    required this.bestDayCount,
    required this.bestDay,
    required this.dailyAverage,
    required this.weekCount,
    required this.previousWeekCount,
    required this.weekOverWeekPercent,
    required this.recentDailyCounts,
  });

  static const ActivityInsights empty = ActivityInsights(
    activeDays: 0,
    windowDays: 0,
    currentStreak: 0,
    bestDayCount: 0,
    bestDay: null,
    dailyAverage: 0,
    weekCount: 0,
    previousWeekCount: 0,
    weekOverWeekPercent: null,
    recentDailyCounts: [],
  );

  double get activeDayRatio =>
      windowDays > 0 ? (activeDays / windowDays).clamp(0.0, 1.0) : 0.0;
}

/// 计算每日趋势的判别维度。[now] 仅供测试注入。
ActivityInsights computeActivityInsights(
  List<DailyTrendStatistics> dailyTrends, {
  DateTime? now,
  int windowDays = 30,
}) {
  if (dailyTrends.isEmpty) return ActivityInsights.empty;

  final today = now ?? DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final countsByDate = <DateTime, int>{};
  for (final trend in dailyTrends) {
    final date = DateTime(trend.date.year, trend.date.month, trend.date.day);
    countsByDate[date] = (countsByDate[date] ?? 0) + trend.count;
  }

  final earliest = countsByDate.keys.reduce(
    (a, b) => a.isBefore(b) ? a : b,
  );
  final effectiveWindow = todayDate.difference(earliest).inDays + 1;
  final span = effectiveWindow < windowDays ? effectiveWindow : windowDays;

  // 窗口内的活跃天数、最活跃日与每日序列(按日期升序)。
  var activeDays = 0;
  var windowTotal = 0;
  var bestCount = 0;
  DateTime? bestDay;
  final recentCounts = <double>[];
  for (var offset = span - 1; offset >= 0; offset--) {
    final date = todayDate.subtract(Duration(days: offset));
    final count = countsByDate[date] ?? 0;
    if (count > 0) activeDays++;
    windowTotal += count;
    if (count > bestCount) {
      bestCount = count;
      bestDay = date;
    }
    recentCounts.add(count.toDouble());
  }

  // 连续活跃:今天未生成则允许从昨天开始起算。
  var currentStreak = 0;
  var cursor = (countsByDate[todayDate] ?? 0) > 0
      ? todayDate
      : todayDate.subtract(const Duration(days: 1));
  while ((countsByDate[cursor] ?? 0) > 0) {
    currentStreak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }

  // 周环比:近 7 天对比 7-14 天前。
  var weekCount = 0;
  var previousWeekCount = 0;
  for (var offset = 0; offset < 7; offset++) {
    weekCount += countsByDate[todayDate.subtract(Duration(days: offset))] ?? 0;
  }
  for (var offset = 7; offset < 14; offset++) {
    previousWeekCount +=
        countsByDate[todayDate.subtract(Duration(days: offset))] ?? 0;
  }
  final weekOverWeek = previousWeekCount > 0
      ? (weekCount - previousWeekCount) / previousWeekCount * 100
      : null;

  return ActivityInsights(
    activeDays: activeDays,
    windowDays: span,
    currentStreak: currentStreak,
    bestDayCount: bestCount,
    bestDay: bestDay,
    dailyAverage: span > 0 ? windowTotal / span : 0,
    weekCount: weekCount,
    previousWeekCount: previousWeekCount,
    weekOverWeekPercent: weekOverWeek,
    recentDailyCounts: recentCounts,
  );
}
