/// Agent 聊天按需下发的工具包。
///
/// 工具 schema 是每轮请求的固定开销。核心包始终下发，可配置包按设置开关
/// 组合，避免把分镜、参考库、画廊等低频工具常驻在上下文里。
enum AgentToolPack {
  core,
  generation,
  generationActions,
  queue,
  inpaint,
  tagLibrary,
  gallery,
  references,
  storyboard,
  web;

  /// 核心工具始终启用；联网工具跟随现有 Web 开关，不单独暴露设置项。
  bool get isUserConfigurable => switch (this) {
    core || web => false,
    _ => true,
  };

  /// 默认下发的包。标签库属于常用提示词工作流，默认开启；
  /// 画廊、Vibe/精确参考与分镜按需开启。
  bool get defaultEnabled => switch (this) {
    core ||
    generation ||
    generationActions ||
    queue ||
    inpaint ||
    tagLibrary ||
    web => true,
    gallery || references || storyboard => false,
  };

  static AgentToolPack? fromStorageKey(String key) {
    for (final pack in values) {
      if (pack.name == key) return pack;
    }
    return null;
  }
}
