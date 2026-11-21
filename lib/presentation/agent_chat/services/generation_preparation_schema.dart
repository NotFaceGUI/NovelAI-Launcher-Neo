import '../../../core/constants/api_constants.dart';
import '../../../core/constants/model_capabilities.dart';
import '../../../core/utils/nai_resolution_adapter.dart';
import 'generation_tool_limits.dart';

/// One `prompts` entry: either a complete positive prompt string, or an
/// object that also overrides that single image's canvas and sampling.
Map<String, dynamic> promptVariationItemSchema() => {
  'anyOf': [
    {
      'type': 'string',
      'description':
          'Complete positive prompt; shared run parameters apply unchanged.',
    },
    {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'prompt': {
          'type': 'string',
          'minLength': 1,
          'description': 'Complete positive prompt for this one image.',
        },
        'width': {
          'type': 'integer',
          'minimum': 64,
          'maximum': NaiResolutionAdapter.generationMaxSide,
          'description':
              'This image only. Must be a multiple of 64; prefer NAI presets.',
        },
        'height': {
          'type': 'integer',
          'minimum': 64,
          'maximum': NaiResolutionAdapter.generationMaxSide,
          'description':
              'This image only. Must be a multiple of 64; prefer NAI presets.',
        },
        'steps': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 50,
          'description': 'This image only; omit to reuse the shared steps.',
        },
        'sampler': {
          'type': 'string',
          'enum': Samplers.allSamplers,
          'description': 'This image only; omit to reuse the shared sampler.',
        },
        'scale': {
          'type': 'number',
          'minimum': 0,
          'maximum': 10,
          'description': 'This image only; omit to reuse the shared CFG scale.',
        },
        'seed': {
          'type': 'integer',
          'minimum': -1,
          'description':
              'This image only. Omit or -1 to randomize just this image.',
        },
        'character_layout_mode': characterLayoutModeSchema(
          perImage: true,
        ),
        'characters': characterEntriesSchema(perImage: true),
      },
      'required': ['prompt'],
    },
  ],
};

Map<String, dynamic> characterLayoutModeSchema({bool perImage = false}) => {
  'type': 'string',
  'enum': ['ai_choice', 'custom'],
  'default': 'ai_choice',
  'description': perImage
      ? 'This image only. Layout for this entry\'s characters snapshot; omit '
            'to reuse the shared layout.'
      : 'Layout for an explicitly provided characters snapshot. Omit or use '
            'ai_choice by default so NovelAI places every character; '
            'coordinates are forbidden in that mode. Use custom only when the '
            'user explicitly requests manual placement, and then provide every '
            'character position. Coordinates use x left-to-right and y '
            'top-to-bottom, both 0..1.',
};

Map<String, dynamic> characterEntriesSchema({bool perImage = false}) => {
  'type': 'array',
  'description': perImage
      ? 'This image only. Complete ordered character snapshot for this entry; '
            'omit to inherit the shared characters, or use an empty list to '
            'clear them for this image. Positions follow the same rules as the '
            'shared characters field.'
      : 'Complete ordered character snapshot for this call. Omit to inherit '
            'the current character editor state. Characters without positions '
            'use NovelAI AI placement. Only when the user explicitly requests '
            'manual placement may you provide a complete x/y pair or legacy A1-E5 '
            'position for every character; never estimate coordinates '
            'proactively. Single-axis or incomplete custom layouts are rejected. '
            'Legacy grid values map to continuous cell centers.',
  'items': {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'prompt': {
        'type': 'string',
        'minLength': 1,
        'description': 'Non-empty positive prompt for this character.',
      },
      'negative_prompt': {
        'type': 'string',
        'description': 'Independent undesired content for this character.',
      },
      'position': {
        'type': 'string',
        'pattern': r'^[A-Ea-e][1-5]$',
        'description': 'Legacy A1-E5 grid position; do not combine with x/y.',
      },
      'position_x': {
        'type': 'number',
        'minimum': 0,
        'maximum': 1,
        'description': 'Horizontal center: 0 is left, 1 is right.',
      },
      'position_y': {
        'type': 'number',
        'minimum': 0,
        'maximum': 1,
        'description': 'Vertical center: 0 is top, 1 is bottom.',
      },
    },
    'required': ['prompt'],
  },
  'maxItems': ModelCapabilityRegistry.maximumCharacterCount,
};

Map<String, dynamic> generationPreparationProperties({
  required bool includeOperation,
}) => {
  if (includeOperation)
    'operation': {
      'type': 'string',
      'enum': ['generate', 'queue'],
    },
  'prompt': {'type': 'string'},
  'prompts': {
    'type': 'array',
    'items': promptVariationItemSchema(),
    'maxItems': generationToolMaxGenerateCount,
    'description':
        'Multi-prompt mode (generate only): one entry per image, so a single '
        'transaction produces different poses, subjects or canvases in one '
        'run. A string entry uses the shared run parameters; an object entry '
        'may also override width, height, steps, sampler, scale, seed and its '
        'own characters for that image only. Every entry generates exactly one '
        'image; count and the app "images per request" setting do not multiply '
        'it. Mutually exclusive with prompt and count. negative_prompt and '
        'source image stay shared by every entry; characters are shared only '
        'for entries that omit their own list.',
  },
  'negative_prompt': {'type': 'string'},
  'width': {'type': 'integer'},
  'height': {'type': 'integer'},
  'steps': {
    'type': 'integer',
    'minimum': 1,
    'maximum': 50,
    'description': 'Shared sampling steps; entries may override this.',
  },
  'sampler': {
    'type': 'string',
    'enum': Samplers.allSamplers,
    'description': 'Shared sampler; entries may override this.',
  },
  'scale': {
    'type': 'number',
    'minimum': 0,
    'maximum': 10,
    'description': 'Shared CFG scale; entries may override this.',
  },
  'count': {'type': 'integer'},
  'seed': {'type': 'integer'},
  'source_image': {'type': 'string'},
  'mask_image': {'type': 'string'},
  'source_ref': {'type': 'object'},
  'mask_ref': {'type': 'object'},
  'prompt_refs': {
    'type': 'array',
    'items': {'type': 'object'},
    'maxItems': 100,
  },
  'negative_prompt_refs': {
    'type': 'array',
    'items': {'type': 'object'},
    'maxItems': 100,
  },
  'vibe_refs': {
    'type': 'array',
    'items': {'type': 'object'},
    'maxItems': 16,
  },
  'precise_reference_refs': {
    'type': 'array',
    'items': {'type': 'object'},
    'maxItems': 16,
  },
  'character_layout_mode': characterLayoutModeSchema(),
  'characters': characterEntriesSchema(),
  'strength': {'type': 'number'},
  'noise': {'type': 'number'},
  'inpaint_strength': {'type': 'number'},
  'auto_start': {'type': 'boolean'},
};
