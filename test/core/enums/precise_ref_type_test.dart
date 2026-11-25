import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/enums/precise_ref_type.dart';

void main() {
  group('PreciseRefType', () {
    const expectedValues = {
      PreciseRefType.character: ('character', 'preciseRef_typeCharacter'),
      PreciseRefType.style: ('style', 'preciseRef_typeStyle'),
      PreciseRefType.characterAndStyle: (
        'character&style',
        'preciseRef_typeCharacterAndStyle',
      ),
      PreciseRefType.outfit: ('costume', 'preciseRef_typeOutfit'),
    };

    test('should have exactly four values', () {
      expect(PreciseRefType.values, hasLength(4));
    });

    test('all values should be present', () {
      for (final type in expectedValues.keys) {
        expect(PreciseRefType.values, contains(type));
      }
    });

    test('toApiString() should return correct values', () {
      for (final entry in expectedValues.entries) {
        expect(entry.key.toApiString(), equals(entry.value.$1));
      }
    });

    test('toApiString() should emit V5 outfit variants', () {
      expect(
        PreciseRefType.character.toApiString(preferSameOutfit: true),
        'character_mainoutfit',
      );
      expect(
        PreciseRefType.characterAndStyle.toApiString(preferSameOutfit: true),
        'character&style_anyoutfit',
      );
      expect(
        PreciseRefType.outfit.toApiString(preferSameOutfit: true),
        'costume',
      );
      expect(PreciseRefType.style.toApiString(preferSameOutfit: true), 'style');
    });

    test('parseApi() should round-trip all official strings', () {
      final cases = {
        'character': (PreciseRefType.character, false),
        'style': (PreciseRefType.style, false),
        'character&style': (PreciseRefType.characterAndStyle, false),
        'costume': (PreciseRefType.outfit, false),
        'outfit': (PreciseRefType.outfit, false),
        'character_mainoutfit': (PreciseRefType.character, true),
        'character&style_anyoutfit': (PreciseRefType.characterAndStyle, true),
      };
      for (final entry in cases.entries) {
        final parsed = PreciseRefType.parseApi(entry.key);
        expect(parsed.type, entry.value.$1, reason: entry.key);
        expect(parsed.preferSameOutfit, entry.value.$2, reason: entry.key);
      }
      expect(PreciseRefType.parseApi(null).type, PreciseRefType.character);
    });

    test('only character types can prefer the same outfit', () {
      expect(PreciseRefType.character.canPreferSameOutfit, isTrue);
      expect(PreciseRefType.characterAndStyle.canPreferSameOutfit, isTrue);
      expect(PreciseRefType.style.canPreferSameOutfit, isFalse);
      expect(PreciseRefType.outfit.canPreferSameOutfit, isFalse);
    });

    test('displayNameKey should return correct values', () {
      for (final entry in expectedValues.entries) {
        expect(entry.key.displayNameKey, equals(entry.value.$2));
      }
    });

    test('all API strings should be unique', () {
      final apiStrings = <String>[
        for (final type in PreciseRefType.values) type.toApiString(),
        PreciseRefType.character.toApiString(preferSameOutfit: true),
        PreciseRefType.characterAndStyle.toApiString(preferSameOutfit: true),
      ];
      expect(apiStrings.toSet().length, equals(apiStrings.length));
    });

    test('enum values should be distinct', () {
      const values = PreciseRefType.values;
      for (var i = 0; i < values.length; i++) {
        for (var j = i + 1; j < values.length; j++) {
          expect(values[i], isNot(equals(values[j])));
          expect(values[i].hashCode, isNot(equals(values[j].hashCode)));
        }
      }
    });
  });
}
