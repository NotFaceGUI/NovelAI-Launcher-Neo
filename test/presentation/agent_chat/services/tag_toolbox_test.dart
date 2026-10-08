import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/core/autocomplete/completion_models.dart';
import 'package:nai_launcher/core/autocomplete/fast_tag_service_provider.dart';
import 'package:nai_launcher/core/autocomplete/tag_catalog_repository.dart';
import 'package:nai_launcher/presentation/agent_chat/services/tag_toolbox.dart';

final _refProvider = Provider<Ref>((ref) => ref);

class _FakeCatalog extends Fake implements TagCatalogRepository {
  final List<String> searchedTokens = [];

  @override
  Future<List<CompletionCandidate>> search(CompletionQuery query) async {
    searchedTokens.add(query.token);
    if (query.token == 'missing_tag') return const [];
    return [
      CompletionCandidate(
        canonicalTag: query.token,
        category: TagCategory.general,
        postCount: 1234,
        matchKind: CompletionMatchKind.englishExact,
        sources: const {CompletionSourceKind.base},
      ),
    ];
  }
}

void main() {
  late _FakeCatalog catalog;
  late ProviderContainer container;

  setUp(() {
    catalog = _FakeCatalog();
    container = ProviderContainer(
      overrides: [tagCatalogRepositoryProvider.overrideWithValue(catalog)],
    );
  });

  tearDown(() => container.dispose());

  AgentTool searchTool() => TagToolbox(
    container.read(_refProvider),
  ).tools().singleWhere((tool) => tool.name == 'search_tags');

  test('several queries are looked up in one call', () async {
    final result = await searchTool().execute('multi', {
      'queries': ['1girl', 'long_hair', 'missing_tag'],
    });

    final payload = _json(result);
    expect(payload['ok'], isTrue);
    expect(catalog.searchedTokens, ['1girl', 'long_hair', 'missing_tag']);
    final results = payload['results'] as List;
    expect(results, hasLength(2));
    expect((results[0] as Map)['query'], '1girl');
    expect((results[0] as Map)['tag'], '1girl');
    expect((results[1] as Map)['query'], 'long_hair');
    expect(payload['unmatched'], ['missing_tag']);
  });

  test('a comma-separated query is split into separate lookups', () async {
    final result = await searchTool().execute('comma', {
      'query': '1girl, long_hair',
    });

    final payload = _json(result);
    expect(catalog.searchedTokens, ['1girl', 'long_hair']);
    expect((payload['results'] as List), hasLength(2));
    expect(payload.containsKey('unmatched'), isFalse);
  });

  test('a single query keeps the original flat result shape', () async {
    final result = await searchTool().execute('single', {'query': '1girl'});

    final payload = _json(result);
    final results = payload['results'] as List;
    expect(results, hasLength(1));
    expect((results.single as Map).containsKey('query'), isFalse);
    expect((results.single as Map)['tag'], '1girl');
    expect((results.single as Map)['post_count'], 1234);
  });

  test('empty and oversized query lists are rejected', () async {
    final empty = await searchTool().execute('empty', const {});
    expect(empty.isError, isTrue);
    expect(_text(empty), contains('required'));

    final oversized = await searchTool().execute('oversized', {
      'queries': [for (var index = 0; index < 13; index++) 'tag$index'],
    });
    expect(oversized.isError, isTrue);
    expect(_text(oversized), contains('at most'));
    expect(catalog.searchedTokens, isEmpty);
  });
}

Map<String, dynamic> _json(AgentToolResult result) =>
    jsonDecode(_text(result)) as Map<String, dynamic>;

String _text(AgentToolResult result) =>
    result.content.whereType<ToolResultTextContent>().single.text;
