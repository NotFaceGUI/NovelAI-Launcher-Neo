/// 用户在设置中配置的提示词权重编辑范围。
///
/// 这是「编辑/滑块」范围，不是解析已有提示词时的硬限制：读取旧提示词仍按
/// [PromptTag] 的绝对范围处理，避免因为收窄设置而丢失已有权重。
class PromptWeightRange {
  const PromptWeightRange({required this.min, required this.max});

  /// 应用支持的数字边界。
  static const double absoluteMin = -10.0;
  static const double absoluteMax = 10.0;

  /// 权重步进，与现有括号/数值权重编辑保持一致。
  static const double step = 0.05;

  static const PromptWeightRange defaults = PromptWeightRange(
    min: absoluteMin,
    max: absoluteMax,
  );

  final double min;
  final double max;

  bool get isDefault => min == absoluteMin && max == absoluteMax;

  bool get isValid => min >= absoluteMin && max <= absoluteMax && min < max;

  double clamp(double value) => value.clamp(min, max);

  /// 按 0.05 对齐并校验；无效输入返回 null。
  static PromptWeightRange? tryCreate(double min, double max) {
    final range = PromptWeightRange(min: _snap(min), max: _snap(max));
    return range.isValid ? range : null;
  }

  static double _snap(double value) => (value * 20).round() / 20;

  /// 设置页与错误提示使用的紧凑数字格式。
  static String format(double value) {
    final text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  bool operator ==(Object other) =>
      other is PromptWeightRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => 'PromptWeightRange(${format(min)}–${format(max)})';
}
