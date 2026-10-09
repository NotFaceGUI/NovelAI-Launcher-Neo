import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/data/models/danbooru/artist_showcase.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/prompt/artist_showcase_card.dart';

void main() {
  const showcase = ArtistShowcase(
    artistTag: 'wlop',
    postId: 777,
    imageUrl: 'https://cdn.test/sample.jpg',
    previewUrl: 'https://cdn.test/preview.jpg',
    postUrl: 'https://danbooru.donmai.us/posts/777',
    width: 800,
    height: 1200,
    score: 4321,
  );

  Widget buildCard({required ArtistShowcase data}) {
    return MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: Center(
          child: ArtistShowcaseCard(
            showcase: data,
            // 测试注入本地图片，避免卡片去请求网络。
            imageProvider: MemoryImage(_pngBytes()),
          ),
        ),
      ),
    );
  }

  testWidgets('画师卡片显示画师标签、评分与作品图', (tester) async {
    await tester.pumpWidget(buildCard(data: showcase));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('wlop'), findsOneWidget);
    expect(find.text('评分 4321'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有评分时只显示画师标签', (tester) async {
    await tester.pumpWidget(
      buildCard(
        data: const ArtistShowcase(
          artistTag: 'wlop',
          postId: 777,
          imageUrl: 'https://cdn.test/sample.jpg',
          previewUrl: '',
          postUrl: 'https://danbooru.donmai.us/posts/777',
          width: 0,
          height: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('wlop'), findsOneWidget);
    expect(find.textContaining('评分'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Uint8List _pngBytes() {
  final image = img.Image(width: 2, height: 2);
  img.fill(image, color: img.ColorRgb8(120, 160, 200));
  return Uint8List.fromList(img.encodePng(image));
}
