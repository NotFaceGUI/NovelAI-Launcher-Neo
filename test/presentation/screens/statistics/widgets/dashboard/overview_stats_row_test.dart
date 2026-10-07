import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/daily_trend_statistics.dart';
import 'package:nai_launcher/data/models/gallery/gallery_statistics.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/screens/statistics/widgets/dashboard/activity_heatmap_card.dart';
import 'package:nai_launcher/presentation/screens/statistics/widgets/dashboard/overview_stats_row.dart';

void main() {
  testWidgets(
    'overview stats render insight metrics and settle animated counts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _testApp(
          SizedBox(width: 1100, child: OverviewStatsRow(stats: _stats())),
        ),
      );
      await tester.pumpAndSettle();

      // 六张指标卡:三张基础 + 三张判别维度。
      expect(find.text('120'), findsOneWidget);
      expect(find.text('活跃天数'), findsOneWidget);
      expect(find.text('连续活跃'), findsOneWidget);
      expect(find.text('日均产出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('overview stats stay overflow-free at 320px and 3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(
        SizedBox(width: 320, child: OverviewStatsRow(stats: _stats())),
        textScaler: const TextScaler.linear(3),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('活跃天数'), findsOneWidget);
    expect(find.text('连续活跃'), findsOneWidget);
    expect(find.text('日均产出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activity heatmap renders month labels, real-count summary and best day',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final trends = [
        DailyTrendStatistics(date: today, count: 4),
        DailyTrendStatistics(
          date: today.subtract(const Duration(days: 2)),
          count: 9,
        ),
        DailyTrendStatistics(
          date: today.subtract(const Duration(days: 3)),
          count: 2,
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          SizedBox(width: 1100, child: ActivityHeatmapCard(dailyTrends: trends)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('周共生成'), findsOneWidget);
      expect(find.textContaining('单日最高 9 张'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

GalleryStatistics _stats() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return GalleryStatistics(
    totalImages: 120,
    totalSizeBytes: 5 * 1024 * 1024 * 1024,
    averageFileSizeBytes: 42 * 1024 * 1024,
    favoriteCount: 8,
    dailyTrends: [
      for (var offset = 0; offset < 9; offset++)
        DailyTrendStatistics(
          date: today.subtract(Duration(days: offset)),
          count: offset.isEven ? 4 : 2,
        ),
    ],
    calculatedAt: DateTime.now(),
  );
}

Widget _testApp(
  Widget child, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: textScaler),
      child: appChild!,
    ),
    home: Scaffold(
      body: Align(alignment: Alignment.topCenter, child: child),
    ),
  );
}
