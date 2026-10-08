import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/agent/agent_types.dart';
import '../../../core/autocomplete/autocomplete_providers.dart';
import '../../../core/autocomplete/completion_models.dart';
import '../../../core/database/services/service_providers.dart';
import '../../../core/services/smart_tag_recommendation_service.dart';
import '../../../core/utils/app_logger.dart';
import 'defined_agent_tool.dart';

AgentToolResult _textResult(String text) {
  return AgentToolResult(
    content: [ToolResultTextContent(text)],
    details: const <String, dynamic>{},
  );
}

AgentToolResult _errorResult(String text) {
  return AgentToolResult(
    content: [ToolResultTextContent(text)],
    details: const <String, dynamic>{},
    isError: true,
  );
}

/// 标签数据工具集：基于内置 tag_catalog.db 与可选下载的中文字典 /
/// 共现数据包，为提示词写作提供标签检索、中文翻译与共现推荐。
///
/// - `search_tags`：统一入口，mode = search（英文模糊搜标签）/ translate
///   （中文→danbooru 标签，需中文字典）/ suggest（共现推荐，需数据包）。
class TagToolbox {
  TagToolbox(this._ref);

  final Ref _ref;

  static final RegExp _chinesePattern = RegExp(r'[\u3400-\u9fff]');

  List<AgentTool> tools() {
    return [
      DefinedAgentTool(
        name: 'search_tags',
        label: 'Search Tags',
        description:
            'Look up danbooru tags in the built-in databases as a '
            'reference. Modes: '
            '"search" (default for English input) fuzzy-matches canonical '
            'tags and aliases in the built-in catalog (always available); '
            '"translate" maps a Chinese (or English) concept to danbooru '
            'tags with Chinese meanings, requires the optional Chinese '
            'dictionary; "suggest" recommends statistically related tags '
            'for one or more existing tags, requires the optional '
            'co-occurrence data pack. Several tags can be checked in one '
            'call: pass them as "queries" (preferred) or as a comma-separated '
            '"query" — in search/translate mode each term is looked up '
            'separately and matches carry their "query"; in suggest mode the '
            'terms are the existing tags to extrapolate from. Requirements: '
            '"query" or "queries" is required; "limit" 1-30 per term '
            '(default 10). Results are '
            'evidence for verifying canonical spellings, aliases and category. '
            'For a named character, use this after researching its identity '
            'and before inspecting gallery tags. Do not guess canonical tags '
            'from model memory. Natural-language prompts remain supported.',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Single search term, or a comma-separated list of terms. '
                  'In suggest mode: the existing tags to extrapolate from.',
            },
            'queries': {
              'type': 'array',
              'items': {'type': 'string', 'maxLength': 200},
              'minItems': 1,
              'maxItems': 12,
              'description':
                  'Preferred way to look up several tags in one call. Each '
                  'term is reported separately, matched or unmatched.',
            },
            'mode': {
              'type': 'string',
              'enum': ['auto', 'search', 'translate', 'suggest'],
              'description':
                  'auto (default) picks translate for Chinese '
                  'input, otherwise search.',
            },
            'limit': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 30,
              'description': 'Max results per term, 1-30. Default 10.',
            },
          },
        },
        executeFn: (_, params) => _searchTags(params),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // search_tags
  // -------------------------------------------------------------------------

  Future<AgentToolResult> _searchTags(Map<String, dynamic> args) async {
    final queries = _collectQueries(args);
    if (queries.isEmpty) {
      return _errorResult('Parameter "query" or "queries" is required.');
    }
    if (queries.length > _maxQueries) {
      return _errorResult(
        'Too many queries: ${queries.length}. Send at most $_maxQueries '
        'terms per call.',
      );
    }
    final mode = (args['mode'] as String?)?.trim() ?? 'auto';
    if (!_modes.contains(mode)) {
      return _errorResult(
        'Unknown mode "$mode". Use auto / search / translate / suggest.',
      );
    }
    final limit = ((args['limit'] as num?)?.toInt() ?? 10).clamp(1, 30);
    // 共现推荐本来就是"给一组已有标签推荐"，多个词合成一次查询。
    if (mode == 'suggest') return _suggest(queries.join(','), limit);

    final multi = queries.length > 1;
    final results = <Map<String, dynamic>>[];
    final unmatched = <String>[];
    var catalogMissed = false;
    var translationMissed = false;
    for (final query in queries) {
      final resolved = mode == 'auto'
          ? (_chinesePattern.hasMatch(query) ? 'translate' : 'search')
          : mode;
      // 单个查询失败（字典或数据包没装）对整批都成立，直接回报而不是逐条重复。
      final List<Map<String, dynamic>> matches;
      try {
        matches = resolved == 'translate'
            ? await _translationMatches(query, limit)
            : await _catalogMatches(query, limit);
      } catch (e) {
        AppLogger.w('search_tags($resolved) failed: $e', 'AgentChat');
        return _errorResult(
          resolved == 'translate'
              ? 'Tag translation failed: $e (the Chinese dictionary may not be '
                    'installed)'
              : 'Tag search failed: $e',
        );
      }
      if (matches.isEmpty) {
        unmatched.add(query);
        if (resolved == 'translate') {
          translationMissed = true;
        } else {
          catalogMissed = true;
        }
        continue;
      }
      for (final match in matches) {
        results.add(multi ? {'query': query, ...match} : match);
      }
    }
    return _textResult(
      jsonEncode({
        'ok': true,
        'results': results,
        if (unmatched.isNotEmpty) 'unmatched': unmatched,
        if (results.isEmpty && translationMissed)
          'note':
              'No translation match. If Chinese input keeps returning nothing, '
              'the Chinese dictionary may not be installed yet (download it in '
              'Settings).',
        if (results.isEmpty && !translationMissed && catalogMissed)
          'note': 'No catalog match for the given term(s).',
      }),
    );
  }

  static const int _maxQueries = 12;
  static const Set<String> _modes = {'auto', 'search', 'translate', 'suggest'};

  /// 一次查多个 tag：`queries` 数组优先，`query` 里的逗号也当分隔符。
  ///
  /// danbooru 标签本身不含逗号，所以拆分不会破坏单个标签名；这样既能一次核对
  /// 一组拼写，也不必为每个词各调一次工具。
  List<String> _collectQueries(Map<String, dynamic> args) {
    final raw = args['queries'];
    final values = <String>[];
    if (raw is List && raw.isNotEmpty) {
      for (final item in raw) {
        if (item is String) values.add(item);
      }
    } else if (args['query'] is String) {
      values.addAll((args['query'] as String).split(','));
    }
    return [
      for (final value in values)
        if (value.trim().isNotEmpty) value.trim(),
    ];
  }

  /// 内置词库模糊搜索（英文标签 + 别名，FTS5）。
  Future<List<Map<String, dynamic>>> _catalogMatches(
    String query,
    int limit,
  ) async {
    final repository = _ref.read(tagCatalogRepositoryProvider);
    final token = query.replaceAll(' ', '_').toLowerCase();
    final candidates = await repository.search(
      CompletionQuery(
        fullText: token,
        cursorPosition: token.length,
        token: token,
        replacementRange: const TextReplacementRange(start: 0, end: 0),
        existingTags: const {},
        limit: limit,
        locale: 'zh',
      ),
    );
    return [
      for (final candidate in candidates)
        {
          'tag': candidate.canonicalTag,
          'category': candidate.category.name,
          'post_count': candidate.postCount,
          if (candidate.aliases.isNotEmpty) 'aliases': candidate.aliases,
          if (candidate.translation != null) 'chinese': candidate.translation,
        },
    ];
  }

  /// 中文（或英文）→ danbooru 标签，依赖可选下载的 ffdkj 中文字典。
  Future<List<Map<String, dynamic>>> _translationMatches(
    String query,
    int limit,
  ) async {
    final dataSource = await _ref.read(translationDataSourceProvider.future);
    final matches = await dataSource.search(query, limit: limit);
    return [
      for (final match in matches)
        {
          'tag': match.tag,
          'chinese': match.translation,
          'category': match.category,
          'post_count': match.count,
        },
    ];
  }

  /// 共现推荐：基于一个或多个已有标签推荐统计上强相关的标签。
  Future<AgentToolResult> _suggest(String query, int limit) async {
    try {
      final service = await _ref.read(
        smartTagRecommendationServiceProvider.future,
      );
      final inputTags = [
        for (final part in query.split(','))
          if (part.trim().isNotEmpty) part.trim().replaceAll(' ', '_'),
      ];
      if (inputTags.isEmpty) {
        return _errorResult('Parameter "query" needs at least one tag.');
      }
      final recommendations = await service.getRecommendations(
        inputTags: inputTags,
        limit: limit,
      );
      if (recommendations.isEmpty) {
        return _textResult(
          jsonEncode({
            'ok': true,
            'results': const <Map<String, dynamic>>[],
            'note':
                'No suggestions. The co-occurrence data pack may not be '
                'installed (download it in Settings).',
          }),
        );
      }
      return _textResult(
        jsonEncode({
          'ok': true,
          'results': [
            for (final recommendation in recommendations)
              {
                'tag': recommendation.tag,
                if (recommendation.translation != null)
                  'chinese': recommendation.translation,
                'score': double.parse(recommendation.score.toStringAsFixed(4)),
                'cooccurrence': recommendation.cooccurrence,
              },
          ],
        }),
      );
    } catch (e) {
      AppLogger.w('search_tags(suggest) failed: $e', 'AgentChat');
      return _errorResult('Tag suggestion failed: $e');
    }
  }
}
