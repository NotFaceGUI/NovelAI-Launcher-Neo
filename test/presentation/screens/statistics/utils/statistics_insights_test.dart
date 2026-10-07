import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/daily_trend_statistics.dart';
import 'package:nai_launcher/presentation/screens/statistics/utils/statistics_insights.dart';

void main() {
  final today = DateTime(2026, 10, 7);

  DailyTrendStatistics trend(int month, int day, int count) =>
      DailyTrendStatistics(date: DateTime(2026, month, day), count: count);

  test('empty trends return empty insights', () {
    final insights = computeActivityInsights(const [], now: today);
    expect(insights.activeDays, 0);
    expect(insights.currentStreak, 0);
    expect(insights.dailyAverage, 0);
    expect(insights.weekOverWeekPercent, isNull);
    expect(insights.recentDailyCounts, isEmpty);
    expect(insights.activeDayRatio, 0);
  });

  test('counts active days, best day and daily average inside window', () {
    final insights = computeActivityInsights(
      [
        trend(10, 3, 1),
        trend(10, 4, 5),
        trend(10, 6, 2),
        trend(10, 7, 3),
      ],
      now: today,
    );

    // 数据最早从 10/3 开始,窗口退化为 5 天。
    expect(insights.windowDays, 5);
    expect(insights.activeDays, 4);
    expect(insights.bestDayCount, 5);
    expect(insights.bestDay, DateTime(2026, 10, 4));
    expect(insights.dailyAverage, closeTo(11 / 5, 0.001));
    expect(insights.recentDailyCounts, [1, 5, 0, 2, 3]);
  });

  test('current streak counts back from today', () {
    final insights = computeActivityInsights(
      [
        trend(10, 4, 5),
        trend(10, 6, 2),
        trend(10, 7, 3),
      ],
      now: today,
    );
    // 10/7 -> 10/6 连续,10/5 缺失中断。
    expect(insights.currentStreak, 2);
  });

  test('current streak starts from yesterday when today has no data', () {
    final insights = computeActivityInsights(
      [
        trend(10, 4, 5),
        trend(10, 5, 1),
        trend(10, 6, 2),
      ],
      now: today,
    );
    // 今天(10/7)未生成,从 10/6 起连续 3 天。
    expect(insights.currentStreak, 3);
  });

  test('current streak is zero when yesterday and today are inactive', () {
    final insights = computeActivityInsights(
      [trend(10, 3, 2)],
      now: today,
    );
    expect(insights.currentStreak, 0);
  });

  test('week over week compares this week against the previous one', () {
    final insights = computeActivityInsights(
      [
        trend(9, 28, 4),
        trend(10, 4, 5),
        trend(10, 6, 2),
        trend(10, 7, 3),
      ],
      now: today,
    );
    // 近 7 天 10,上一周(9/30-10/1 窗口外)仅 9/28 不计入。
    expect(insights.weekCount, 10);
    // 9/28 在 7-14 天前窗口(9/23-9/29)内。
    expect(insights.previousWeekCount, 4);
    expect(insights.weekOverWeekPercent, closeTo((10 - 4) / 4 * 100, 0.001));
  });

  test('week over week is null when previous week has no data', () {
    final insights = computeActivityInsights(
      [trend(10, 7, 3)],
      now: today,
    );
    expect(insights.weekOverWeekPercent, isNull);
  });

  test('window never exceeds the requested span', () {
    final trends = <DailyTrendStatistics>[
      for (var offset = 0; offset < 30; offset++)
        DailyTrendStatistics(
          date: today.subtract(Duration(days: offset)),
          count: offset + 1,
        ),
    ];
    final insights = computeActivityInsights(
      trends,
      now: today,
      windowDays: 30,
    );
    expect(insights.windowDays, 30);
    expect(insights.activeDays, 30);
    expect(insights.recentDailyCounts.length, 30);
    // 序列按日期升序:最早一天生成最多(30),今天最少(1)。
    expect(insights.recentDailyCounts.first, 30);
    expect(insights.recentDailyCounts.last, 1);
  });
}
