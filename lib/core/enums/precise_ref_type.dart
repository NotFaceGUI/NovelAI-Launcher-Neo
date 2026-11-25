/// Precise reference type for NovelAI's Character Reference feature.
///
/// The declaration order is persisted by [PreciseRefLibraryEntry.typeIndex],
/// so new values must only be appended. [outfit] is the V5-only Outfit
/// Reference; "prefer same outfit" is stored separately and maps to the
/// official `character_mainoutfit` / `character&style_anyoutfit` variants.
enum PreciseRefType {
  /// Use character appearance only
  character,

  /// Use art style only
  style,

  /// Use both character and style
  characterAndStyle,

  /// Use the outfit from the reference image (V5 only)
  outfit;

  /// Parses an official API type string, including the V5 outfit variants.
  static ({PreciseRefType type, bool preferSameOutfit}) parseApi(
    String? value,
  ) {
    return switch (value?.trim().toLowerCase()) {
      'style' => (type: PreciseRefType.style, preferSameOutfit: false),
      'costume' ||
      'outfit' => (type: PreciseRefType.outfit, preferSameOutfit: false),
      'character_mainoutfit' => (
        type: PreciseRefType.character,
        preferSameOutfit: true,
      ),
      'character&style_anyoutfit' => (
        type: PreciseRefType.characterAndStyle,
        preferSameOutfit: true,
      ),
      'character&style' || 'character_and_style' || 'character and style' => (
        type: PreciseRefType.characterAndStyle,
        preferSameOutfit: false,
      ),
      _ => (type: PreciseRefType.character, preferSameOutfit: false),
    };
  }
}

/// Extension methods for [PreciseRefType]
extension PreciseRefTypeExtension on PreciseRefType {
  /// Whether "Prefer same outfit" can be applied to this base type.
  bool get canPreferSameOutfit =>
      this == PreciseRefType.character ||
      this == PreciseRefType.characterAndStyle;

  /// Returns the API string for the type.
  ///
  /// [preferSameOutfit] is only meaningful for character / character & style
  /// and only on models that support outfit references.
  String toApiString({bool preferSameOutfit = false}) {
    if (preferSameOutfit) {
      if (this == PreciseRefType.character) return 'character_mainoutfit';
      if (this == PreciseRefType.characterAndStyle) {
        return 'character&style_anyoutfit';
      }
    }
    return switch (this) {
      PreciseRefType.character => 'character',
      PreciseRefType.style => 'style',
      PreciseRefType.characterAndStyle => 'character&style',
      PreciseRefType.outfit => 'costume',
    };
  }

  /// Display name key for localization
  /// Use with context.l10n.preciseRef_typeCharacter, etc.
  String get displayNameKey {
    return switch (this) {
      PreciseRefType.character => 'preciseRef_typeCharacter',
      PreciseRefType.style => 'preciseRef_typeStyle',
      PreciseRefType.characterAndStyle => 'preciseRef_typeCharacterAndStyle',
      PreciseRefType.outfit => 'preciseRef_typeOutfit',
    };
  }
}
