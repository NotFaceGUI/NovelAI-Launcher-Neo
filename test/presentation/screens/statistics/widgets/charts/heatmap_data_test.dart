import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/screens/statistics/widgets/charts/heatmap_chart.dart';

void main() {
  test('quantile levels keep extreme days from washing out the grid', () {
    final counts = <DateTime, int>{
      for (var day = 1; day <= 20; day++) DateTime(2026, 9, day): 1,
      DateTime(2026, 9, 21): 100,
    };

    final result = generateHeatmapData(
      counts,
      weeks: 6,
      endDate: DateTime(2026, 9, 30),
    );

    var levelQuarter = 0;
    var levelMax = 0;
    for (final week in result.data) {
      for (final value in week) {
        if (value == 0.25) levelQuarter++;
        if (value == 1.0) levelMax++;
      }
    }
    // 20 个普通日都落在低档,单日峰值独享最高档。
    expect(levelQuarter, 20);
    expect(levelMax, 1);
    expect(result.totalInRange, 120);
  });

  test('grid aligns weeks to Monday and keeps the last column current', () {
    // 2026-09-30 是周三:最后一列的周一应为 09-28。
    final result = generateHeatmapData(
      const {},
      weeks: 6,
      endDate: DateTime(2026, 9, 30),
    );

    expect(result.data.length, 6);
    expect(result.dates.last.first, DateTime(2026, 9, 28));
    // 09-28 至 09-30 在区间内,其余为未来日期。
    expect(result.dates.last[2], DateTime(2026, 9, 30));
    expect(result.dates.last[3], isNull);
    expect(result.counts.last[3], 0);
    expect(result.todayPosition, isNull);
  });

  test('month starts mark columns containing the first day of a month', () {
    final result = generateHeatmapData(
      const {},
      weeks: 6,
      endDate: DateTime(2026, 9, 30),
    );

    // 09-01(周二)落在第二列(周一首日 08-31),10-01 落在最后一列。
    expect(result.monthStarts, hasLength(2));
    expect(result.monthStarts.first.weekIndex, 1);
    expect(result.monthStarts.first.month, 9);
    expect(result.monthStarts.last.weekIndex, 5);
    expect(result.monthStarts.last.month, 10);
  });

  test('today is located when the range covers it', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final result = generateHeatmapData(
      {today: 5, yesterday: 1},
      weeks: 4,
      endDate: today,
    );

    expect(result.todayPosition, isNotNull);
    final (week, day) = result.todayPosition!;
    expect(week, 3);
    expect(result.counts[week][day], 5);
    expect(result.data[week][day], 1.0);
  });
}
