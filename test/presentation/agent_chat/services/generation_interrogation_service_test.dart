import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/core/agent/resources/agent_chat_resource_reference.dart';
import 'package:nai_launcher/core/agent/resources/agent_chat_resource_reference_codec.dart';
import 'package:nai_launcher/core/agent/resources/agent_chat_resource_draft_store.dart';
import 'package:nai_launcher/core/agent/validate_tool_arguments.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/storage/secure_storage_service.dart';
import 'package:nai_launcher/data/models/agent/agent_settings.dart';
import 'package:nai_launcher/data/models/precise_ref/precise_ref_library_entry.dart';
import 'package:nai_launcher/data/services/local_onnx_model_service.dart';
import 'package:nai_launcher/data/services/local_onnx_tagger_service.dart';
import 'package:nai_launcher/data/services/precise_ref_library_storage_service.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_resource_resolver.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_chat_draft_controller.dart';
import 'package:nai_launcher/presentation/agent_chat/providers/agent_chat_state.dart';
import 'package:nai_launcher/presentation/agent_chat/services/generation_toolbox.dart';
import 'package:nai_launcher/presentation/agent_settings/providers/agent_settings_provider.dart';
import 'package:nai_launcher/presentation/prompt_assistant/models/prompt_assistant_models.dart';
import 'package:nai_launcher/presentation/prompt_assistant/providers/prompt_assistant_config_provider.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_api_client.dart';
import 'package:nai_launcher/presentation/prompt_assistant/services/prompt_assistant_service.dart';

class _Dio extends Mock implements Dio {}

class _ReferenceStorage extends Mock
    implements PreciseRefLibraryStorageService {}

class _FakeLocalOnnxModelService extends Mock
    implements LocalOnnxModelService {}

class _FakeLocalOnnxTaggerService extends Mock
    implements LocalOnnxTaggerService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(CancelToken());
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      const LocalOnnxModelDescriptor(
        name: 'fallback.onnx',
        path: 'fallback.onnx',
        kind: LocalOnnxModelKind.unknown,
      ),
    );
  });
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  final reference = AgentChatResourceReference(
    kind: AgentChatResourceKind.inpaintDraft,
    source: 'inpaint_draft',
    resourceId: 'image',
  );
  late Directory root;
  late ProviderContainer container;
  late AgentTool tool;
  late List<Map<String, dynamic>> requests;
  late _MemoryStorage storage;
  late _FakeLocalOnnxModelService localModelService;
  late _FakeLocalOnnxTaggerService localTaggerService;
  const localDescriptor = LocalOnnxModelDescriptor(
    name: 'model.onnx',
    path: 'models/model.onnx',
    kind: LocalOnnxModelKind.pixaiTagger,
    labelsPath: 'models/tags.json',
  );

  setUp(() async {
    final temporaryRoot = await Directory('tool/.tmp').create(recursive: true);
    root = await temporaryRoot.createTemp('agent-interrogation-test-');
    final libraryFile = await File(
      '${root.path}/library.png',
    ).writeAsBytes(png);
    final library = _ReferenceStorage();
    when(() => library.getAllEntries()).thenAnswer(
      (_) async => [
        PreciseRefLibraryEntry(
          id: 'library-image',
          name: 'Reference image',
          imagePath: libraryFile.path,
          createdAt: DateTime(2026),
        ),
      ],
    );
    requests = [];
    storage = _MemoryStorage();
    localModelService = _FakeLocalOnnxModelService();
    localTaggerService = _FakeLocalOnnxTaggerService();
    final dio = _Dio();
    when(
      () => dio.post<dynamic>(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((call) async {
      requests.add(
        Map<String, dynamic>.from(call.namedArguments[#data] as Map),
      );
      return Response<dynamic>(
        requestOptions: RequestOptions(path: '/v1/chat/completions'),
        statusCode: 200,
        data: {
          'choices': [
            {
              'message': {'content': '1girl, blue sky'},
            },
          ],
        },
      );
    });
    container = ProviderContainer(
      overrides: [
        preciseRefLibraryStorageServiceProvider.overrideWithValue(library),
        localStorageServiceProvider.overrideWithValue(storage),
        secureStorageServiceProvider.overrideWithValue(_SecureStorage()),
        localOnnxModelServiceProvider.overrideWithValue(localModelService),
        localOnnxTaggerServiceProvider.overrideWithValue(localTaggerService),
        promptAssistantDioProvider.overrideWithValue(dio),
        promptAssistantServiceProvider.overrideWith(
          (ref) => PromptAssistantService(
            ref: ref,
            apiClient: PromptAssistantApiClient(dio: dio),
          ),
        ),
        agentSettingsProvider.overrideWith(
          (ref) => AgentSettingsNotifier(
            ref,
            supportDirectory: root,
            workspaceDirectory: root,
            environment: const {},
          ),
        ),
      ],
    );
    final config = container.read(promptAssistantConfigProvider.notifier);
    await config.upsertProvider(
      const ProviderConfig(
        id: 'vision',
        name: 'Vision',
        baseUrl: 'https://example.invalid/v1',
        allowImageInput: true,
      ),
    );
    await config.upsertModel(
      const ModelConfig(
        providerId: 'vision',
        name: 'vision-model',
        displayName: 'Vision',
        forTask: AssistantTaskType.chat,
      ),
    );
    final settings = container.read(agentSettingsProvider.notifier);
    final ready = Completer<void>();
    final subscription = container.listen(agentSettingsProvider, (_, next) {
      if (next.initialized && !ready.isCompleted) ready.complete();
    }, fireImmediately: true);
    await ready.future;
    subscription.close();
    expect(container.read(agentSettingsProvider).error, isEmpty);
    await settings.setModelReference(
      const AgentModelReference(providerId: 'vision', model: 'vision-model'),
    );
    final ref = container.read(Provider<Ref>((ref) => ref));
    tool = GenerationToolbox(
      ref,
      workspaceDir: root.absolute.path,
      resourceResolver: AgentResourceResolver(
        ref,
        loadInpaintDraftImage: (id, {required mask}) async =>
            id == 'image' ? png : null,
      ),
      readAttachedImage: (index) => index == 1 ? png : null,
    ).tools().firstWhere((tool) => tool.name == 'interrogate_image');
  });
  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });

  test('composer resource_ref reaches interrogation unchanged', () async {
    final draft = AgentChatDraftController(
      resourceStore: AgentChatResourceDraftStore(
        File('${root.path}/draft.json'),
      ),
      localStorage: _MemoryStorage(),
      readState: () => const AgentChatState(),
      writeState: (_) {},
      createResourceResolver: () => throw StateError('No preview needed'),
      isMounted: () => true,
    );
    final envelope = draft.promptEnvelope(
      UserMessage(
        content: [const UserTextContent('Describe this image')],
        timestamp: 1,
      ),
      references: [
        AgentChatResourceReference(
          kind: AgentChatResourceKind.preciseRefLibraryEntry,
          source: 'precise_ref_library',
          resourceId: 'library-image',
        ),
      ],
    );
    final prefix = (envelope.blockContent!.first as UserTextContent).text;
    final payload = jsonDecode(prefix.split('\n')[1]) as Map;
    final entry = (payload['references'] as List).single as Map;
    expect(entry['available'], isTrue);
    final args = <String, dynamic>{'resource_ref': entry['resource_ref']};
    validateToolArguments(
      tool,
      ToolCallContent(id: 'selected', name: tool.name, arguments: args),
    );
    expect((await tool.execute('selected', args)).isError, isFalse);
    expect(requests, hasLength(1));
    for (final invalid in [payload, entry]) {
      expect(
        () => validateToolArguments(
          tool,
          ToolCallContent(
            id: 'invalid',
            name: tool.name,
            arguments: {'resource_ref': invalid},
          ),
        ),
        throwsFormatException,
      );
    }
  });

  test('local interrogation keeps the image on-device', () async {
    storage.values[StorageKeys.agentLocalInterrogateEnabled] = true;
    when(
      () => localModelService.scanTaggerModels(),
    ).thenAnswer((_) async => const [localDescriptor]);
    when(
      () => localTaggerService.tagImage(
        imageBytes: any(named: 'imageBytes'),
        model: any(named: 'model'),
        generalThreshold: any(named: 'generalThreshold'),
        characterThreshold: any(named: 'characterThreshold'),
      ),
    ).thenAnswer(
      (_) async => const OnnxTaggerResult(model: localDescriptor, tags: [
        OnnxTaggerTag(name: '1girl', score: 0.9),
        OnnxTaggerTag(name: 'solo', score: 0.8),
      ]),
    );

    final result = await tool.execute('test', {'attachment_index': 1});

    expect(result.isError, isFalse, reason: result.content.toString());
    expect(
      result.content.whereType<ToolResultTextContent>().single.text,
      '1girl, solo',
    );
    expect(requests, isEmpty);
  });

  test(
    'local interrogation failure never falls back to remote routes',
    () async {
      storage.values[StorageKeys.agentLocalInterrogateEnabled] = true;
      when(
        () => localModelService.scanTaggerModels(),
      ).thenAnswer((_) async => const [localDescriptor]);
      when(
        () => localTaggerService.tagImage(
          imageBytes: any(named: 'imageBytes'),
          model: any(named: 'model'),
          generalThreshold: any(named: 'generalThreshold'),
          characterThreshold: any(named: 'characterThreshold'),
        ),
      ).thenThrow(StateError('onnx failure'));

      final result = await tool.execute('test', {'attachment_index': 1});

      expect(result.isError, isTrue);
      expect(requests, isEmpty);
    },
  );

  test(
    'local interrogation without a model reports an error without requests',
    () async {
      storage.values[StorageKeys.agentLocalInterrogateEnabled] = true;
      when(
        () => localModelService.scanTaggerModels(),
      ).thenAnswer((_) async => const []);

      final result = await tool.execute('test', {'attachment_index': 1});

      expect(result.isError, isTrue);
      expect(requests, isEmpty);
    },
  );

  for (final source in ['attachment', 'resource', 'path']) {
    test(
      '$source reaches the vision adapter with the selected image bytes',
      () async {
        await File('${root.path}/test.png').writeAsBytes(png);
        final args = switch (source) {
          'attachment' => <String, dynamic>{'attachment_index': 1},
          'resource' => <String, dynamic>{
            'resource_ref': AgentChatResourceReferenceCodec.encodeJsonMap(
              reference,
            ),
          },
          _ => <String, dynamic>{'path': 'test.png'},
        };
        final result = await tool.execute('test', args);
        expect(result.isError, isFalse, reason: result.content.toString());
        expect(
          result.content.whereType<ToolResultTextContent>().single.text,
          '1girl, blue sky',
        );
        final messages = requests.single['messages'] as List;
        final user = messages.last as Map;
        final content = user['content'] as List;
        final image = content.cast<Map>().singleWhere(
          (part) => part['type'] == 'image_url',
        );
        expect(
          image['image_url']['url'],
          'data:image/png;base64,${base64Encode(png)}',
        );
      },
    );
  }

  for (final args in <Map<String, dynamic>>[
    {},
    {'attachment_index': 2},
    {'attachment_index': 0},
    {'attachment_index': 1.5},
    {'attachment_index': 1, 'path': 'test.png'},
    {
      'resource_ref': {'kind': 'invalid'},
    },
    {
      'resource_ref': {
        'schemaVersion': 1,
        'references': [
          AgentChatResourceReferenceCodec.encodeJsonMap(reference),
        ],
      },
    },
    {
      'resource_ref': AgentChatResourceReferenceCodec.encodeJsonMap(
        AgentChatResourceReference(
          kind: reference.kind,
          source: reference.source,
          resourceId: 'missing',
        ),
      ),
    },
    {'path': 'missing.png'},
    {'path': '../outside.png'},
  ]) {
    test(
      'invalid or missing image source is rejected before any API request: $args',
      () async {
        final result = await tool.execute('test', args);
        expect(result.isError, isTrue);
        expect(requests, isEmpty);
      },
    );
  }
}

class _MemoryStorage extends LocalStorageService {
  final _values = <String, Object?>{};

  /// Test-visible alias so cases can flip settings directly.
  Map<String, Object?> get values => _values;

  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      _values[key] as T? ?? defaultValue;
  @override
  Future<void> setSetting<T>(String key, T value) async {
    _values[key] = value;
  }
}

class _SecureStorage extends SecureStorageService {
  @override
  Future<String?> getPromptAssistantApiKey(String providerId) async => null;
}
