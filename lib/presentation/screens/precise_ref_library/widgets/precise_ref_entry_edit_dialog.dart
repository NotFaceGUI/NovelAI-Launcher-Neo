import 'package:flutter/material.dart';
import 'package:nai_launcher/core/utils/localization_extension.dart';

import '../../../../core/enums/precise_ref_type.dart';
import '../../../../core/extensions/precise_ref_type_extensions.dart';
import '../../../../data/models/precise_ref/precise_ref_library_entry.dart';
import '../../../adaptive/adaptive_presenter.dart';
import '../../../widgets/common/adaptive_dialog_frame.dart';
import '../../../widgets/common/editable_double_field.dart';

/// 编辑对话框返回结果
class PreciseRefEntryEditResult {
  const PreciseRefEntryEditResult({
    required this.name,
    required this.type,
    required this.strength,
    required this.fidelity,
    required this.preferSameOutfit,
  });

  final String name;
  final PreciseRefType type;
  final double strength;
  final double fidelity;
  final bool preferSameOutfit;
}

/// 精准参考库条目编辑对话框
///
/// 编辑名称、类型与默认参数（强度/保真度）。
/// 与精准参考面板一致：数值输入不设上下限，滑条范围 0-1。
class PreciseRefEntryEditDialog extends StatefulWidget {
  const PreciseRefEntryEditDialog({super.key, required this.entry})
    : _presented = false,
      _scrollController = null;

  const PreciseRefEntryEditDialog._presented({
    required this.entry,
    required ScrollController scrollController,
  }) : _presented = true,
       _scrollController = scrollController;

  final PreciseRefLibraryEntry entry;
  final bool _presented;
  final ScrollController? _scrollController;

  static Future<PreciseRefEntryEditResult?> show(
    BuildContext context,
    PreciseRefLibraryEntry entry,
  ) {
    return AdaptivePresenter.showForm<PreciseRefEntryEditResult>(
      context: context,
      titleBuilder: (panelContext) => Text(
        panelContext.l10n.preciseRefLib_editEntry,
        style: Theme.of(panelContext).textTheme.titleLarge,
      ),
      dialogWidth: 440,
      builder: (panelContext, scrollController) =>
          PreciseRefEntryEditDialog._presented(
            entry: entry,
            scrollController: scrollController,
          ),
    );
  }

  @override
  State<PreciseRefEntryEditDialog> createState() =>
      _PreciseRefEntryEditDialogState();
}

class _PreciseRefEntryEditDialogState extends State<PreciseRefEntryEditDialog> {
  late final TextEditingController _nameController;
  late PreciseRefType _type;
  late double _strength;
  late double _fidelity;
  late bool _preferSameOutfit;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.entry.name);
    _type = widget.entry.type;
    _strength = widget.entry.strength;
    _fidelity = widget.entry.fidelity;
    _preferSameOutfit = widget.entry.preferSameOutfit;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      PreciseRefEntryEditResult(
        name: _nameController.text.trim().isEmpty
            ? widget.entry.name
            : _nameController.text.trim(),
        type: _type,
        strength: _strength,
        fidelity: _fidelity,
        preferSameOutfit: _preferSameOutfit,
      ),
    );
  }

  String _typeLabel(BuildContext context, PreciseRefType type) {
    final l10n = context.l10n;
    return type.getDisplayName(
      character: l10n.preciseRef_typeCharacter,
      style: l10n.preciseRef_typeStyle,
      characterAndStyle: l10n.preciseRef_typeCharacterAndStyle,
      outfit: l10n.preciseRef_typeOutfit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    final content = SingleChildScrollView(
      key: const Key('precise-ref-edit-dialog'),
      controller: widget._scrollController,
      padding: const EdgeInsets.all(20),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget._presented) ...[
            Text(
              l10n.preciseRefLib_editEntry,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            key: const Key('precise-ref-edit-name-field'),
            controller: _nameController,
            decoration: InputDecoration(
              labelText: l10n.preciseRefLib_nameLabel,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.preciseRef_referenceType,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
              if (constraints.maxWidth < 360 || textScale > 1.5) {
                return DropdownButtonFormField<PreciseRefType>(
                  key: const Key('precise-ref-edit-type-selector'),
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final type in PreciseRefType.values)
                      DropdownMenuItem(
                        value: type,
                        child: Row(
                          children: [
                            Icon(type.icon, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_typeLabel(context, type))),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _type = value;
                        if (!_type.canPreferSameOutfit) {
                          _preferSameOutfit = false;
                        }
                      });
                    }
                  },
                );
              }
              return SegmentedButton<PreciseRefType>(
                key: const Key('precise-ref-edit-type-selector'),
                segments: [
                  for (final type in PreciseRefType.values)
                    ButtonSegment(
                      value: type,
                      icon: Icon(type.icon, size: 16),
                      label: Text(
                        _typeLabel(context, type),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                selected: {_type},
                onSelectionChanged: (selection) {
                  setState(() {
                    _type = selection.first;
                    if (!_type.canPreferSameOutfit) {
                      _preferSameOutfit = false;
                    }
                  });
                },
              );
            },
          ),
          if (_type.canPreferSameOutfit) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.preciseRef_preferSameOutfit,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Switch(
                  key: const Key('precise-ref-edit-prefer-outfit'),
                  value: _preferSameOutfit,
                  onChanged: (value) =>
                      setState(() => _preferSameOutfit = value),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _buildSliderRow(
            label: l10n.preciseRef_strength,
            value: _strength,
            max: 5,
            fieldKey: const Key('precise-ref-edit-strength-field'),
            onChanged: (value) => setState(() => _strength = value),
          ),
          const SizedBox(height: 8),
          _buildSliderRow(
            label: l10n.preciseRef_fidelity,
            value: _fidelity,
            fieldKey: const Key('precise-ref-edit-fidelity-field'),
            onChanged: (value) => setState(() => _fidelity = value),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.common_cancel),
              ),
              FilledButton(
                key: const Key('precise-ref-edit-confirm'),
                onPressed: _submit,
                child: Text(l10n.common_confirm),
              ),
            ],
          ),
        ],
      ),
    );

    if (widget._presented) {
      return content;
    }

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: AdaptiveDialogFrame(
        maxWidth: 440,
        maxHeight: 680,
        reservedVerticalSpace: 0,
        horizontalMargin: 0,
        child: SafeArea(child: content),
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required double value,
    required Key fieldKey,
    double max = 1.0,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    final effectiveValue = value.clamp(0.0, max).toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final field = EditableDoubleField(
          key: fieldKey,
          value: effectiveValue,
          decimals: 2,
          width: 64,
          onChanged: (next) => onChanged(next.clamp(0.0, max)),
        );
        final slider = Slider(
          value: effectiveValue,
          max: max,
          divisions: (max * 20).round(),
          onChanged: (next) => onChanged(next.clamp(0.0, max)),
        );
        if (constraints.maxWidth < 340 || textScale > 1.5) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(label, style: theme.textTheme.bodySmall),
                  ),
                  field,
                ],
              ),
              slider,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(label, style: theme.textTheme.bodySmall),
            ),
            Expanded(child: slider),
            field,
          ],
        );
      },
    );
  }
}
