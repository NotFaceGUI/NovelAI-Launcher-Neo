# 漫画分镜编辑器

生成页中央工作区的第三种模式（与「预览」「无限画布」并列）。用户在一张页面上排布分镜格子，为每个格子独立设置提示词、分辨率与生成参数，然后批量生成并把结果合成回页面。

| 主题 | 入口 |
|---|---|
| 模式切换 | `lib/presentation/providers/generation/generation_center_mode_provider.dart` |
| 文档模型 | `lib/data/models/storyboard/`（document / page / panel / background / resolution） |
| 存储 | `lib/data/services/storyboard/storyboard_document_store.dart`（原子写 tmp + rename + `.bak`） |
| 几何与间距约束 | `lib/core/utils/storyboard/storyboard_geometry.dart` |
| 适配几何（合成与分层导出共用） | `lib/core/utils/storyboard/storyboard_fit_geometry.dart` |
| 分辨率解析 | `lib/core/utils/storyboard/storyboard_resolution_resolver.dart` |
| 画布与工具条 | `lib/presentation/screens/generation/storyboard/` |
| 左侧参数面板分组 | `lib/presentation/widgets/storyboard/storyboard_settings_section.dart` |
| 批量生成 | `lib/data/services/storyboard/storyboard_generation_planner.dart` + `lib/presentation/providers/storyboard/storyboard_generation_runner.dart` |
| 导出 | `lib/data/services/storyboard/storyboard_page_exporter.dart` |
| 分层 PSD 导出 | `lib/data/services/storyboard/storyboard_psd_exporter.dart` + `lib/data/services/storyboard/psd/` |
| Agent 工具 | `lib/presentation/agent_chat/services/storyboard_toolbox.dart` |
| 云同步 | `lib/data/cloud_sync/storyboard_cloud_sync_adapter.dart` |

## 文档与坐标约定

- 分镜文档是图库根目录下的 sidecar JSON `.gallery_storyboard.json`，与无限画布同构：整篇读写、原子提交、容错解析（坏文档返回 null 而不是抛异常）。
- **页面坐标就是最终输出像素**。页面尺寸在页面设置里改，导出结果与排版坐标一一对应。
- 每个分镜的 `rect` 同时是版面矩形和多边形的外接矩形；`points` 归一化到 rect 的 0..1，移动/缩放矩形时形状自动跟随。
- 多边形分镜在生成阶段仍按外接矩形请求（NovelAI 只输出矩形），多边形只影响画布裁剪与整页合成。

## 画布视口与窄屏布局

- 画布基准是「整页等比例适应视口」：默认不缩放也不平移，点击、拖动与拉框都只经过这一层换算。
- 触屏可双指缩放（1–8 倍）与双指平移，双击画布复位到适应视口。视口变换只作用于呈现、不写进文档；缩放为 1 时平移恒为零，因此鼠标端行为与旧版一致。任一轴每帧都会把平移钳回页面范围内：页面比视口小的一轴居中，比视口大的一轴不留空白。
- 第二根手指落下即接管整段手势：进行中的分镜拖动、缩放与拉框就地取消，捏合不会顺带写进版面。
- 分镜与页面背景的解码宽度按「屏幕上真正可见的像素」封顶（面板尺寸与视口宽度取小），放大画布不按倍数放大解码内存。
- 窄屏（手机）工具条按内容横向滚动并始终留在视口内，页面信息 chip 让到左下角；Android 上退出分镜同时支持返回键，与工具条退出按钮共用 `StoryboardToolbarActions.leaveEditor()`（先落盘再回预览）。

## 间距语义

页边距与分镜间距是**拖拽约束**而不是布局生成器：分镜移动/缩放不得越过页边距，也不得小于与相邻分镜的间距。单个分镜可以用「分镜设置 → 不受间距钳制」豁免。网格工具生成时使用当时的页面间距。

## 分辨率与计费

- `auto` 模式：按版面矩形面积吸附到 64 网格；版面面积低于免费档的 3/4（`autoQualityFloorArea`）时**放大到免费档满额面积出图**再缩回贴合分镜；接近或超过免费档的版面保持原样，不多花钱；超过单张上限（3,145,728 像素）时按比例收敛。
- **质量下限对所有模式生效**：显式分辨率低于下限（例如旧的 320×512）同样同比例放大到免费档满额——任何入口都不出小图，Opus 下放大不产生 Anlas。放大后若 64 网格吸附把面积顶回免费上限之上，会同比例再收一格，保证放大始终免费。
- `explicit` 模式：用户在左侧改了画幅就固化为显式分辨率（64 网格）。
- 页面设置的「禁止收费」把所有请求（含显式分辨率与整页背景）钳进 Opus 免费档（≤1,048,576 像素、≤28 步），同比例缩小出图后再由适配方式贴合分镜。左栏「画幅大小」显示的就是钳制后的请求尺寸。
- 左侧「生成」按钮在分镜模式下接管：选中分镜 → 生成该分镜；选中背景 → 生成页面背景；未选中 → 打开批量范围对话框。生成前编辑器内容会写回分镜快照。流式预览实时显示在对应分镜格内。

## 生成回填

批量走 `ImageGenerationService.generateSingle()`（与生成页同一套重试、429 退避与取消），结果经 `GenerationResultLifecycleService` 落盘入图库后按 `panelId` 回填到 `panel.images`；页面背景用保留 id `@background` 回填。

生成前 runner 会执行与生成页一致的参数装配：别名解析 → 角色块解析 → **固定词** → **质量标签预设 / UC 预设**（`StoryboardPromptAssembly`，套在每个分镜最终使用的提示词上），并把编辑器当前**角色快照**与 **Vibe 编码**带入 base——分镜自带角色时整体覆盖，没有时回落到编辑器角色。流式预览实时显示在对应分镜格内；DLSS 自动增强按设计不参与分镜批量。

## 导出

工具条「导出」菜单：整页合成（背景 + 全部分镜按 zOrder 合成，页面像素直出）、单个分镜（外接矩形出图，多边形外透明）与分层 PSD。产物经 `ImageSaveUtils.saveBytesToDatedPath` 进入图库当日目录，PSD 传 `extension: 'psd'`。dart:ui 渲染在根 isolate 执行，面板原图逐张解码-绘制-释放。

分层 PSD（仅桌面端，移动端不显示该项）一个分镜页一个文件，画布等于页面像素，图层自下而上为「背景」与每个有图分镜的「NN 遮罩 + NN 原图」：遮罩是按分镜形状填充的不透明白色剪贴基底，原图是未裁剪的整张原图并标记为被剪贴层，移动或缩放即可重新取景，可见结果与整页 PNG 一致。实现分工：`lib/data/services/storyboard/psd/` 是只认识 PSD 结构的纯 Dart 写入器（`psd_packbits` PackBits 编码、`psd_rle_encoder` 像素→RLE 通道、`psd_document` 数据结构、`psd_writer` 按规范排字节），`storyboard_psd_exporter.dart` 负责页面语义与逐层绘制，两者共用 `StoryboardFitGeometry` 的适配数学与 `StoryboardImageSource` 的原图读取。

写入器只支持版本 1、RGB/8-bit、正常混合、RLE；不写 ICC、图层效果、文本层或智能对象。页面边长超过 30000 或预计文件超过 512 MiB 时中止并提示，不静默降级。图层信息段按偶数上报长度，并且必须把补齐字节真的写进文件——RLE 通道数据长度可以是奇数，只改上报长度不写字节会让后面的蒙版段与图像数据段整体错位。图层边界收进画布：越界像素在 Photoshop 里既不可见也无从取回，收边后单层像素量不超过画布，可见结果不变。原图与合并预览取 `rawStraightRgba` 而不是 `rawRgba`（后者是预乘 alpha，PSD 通道保存直通 alpha）。

## Agent 工具

权限域 `storyboard`（`AgentPermissionDomain.storyboard`）。`get_storyboard_state`、`inspect_storyboard_panel` 为读；`update_storyboard_page`、`update_storyboard_background`（整页背景：类型/颜色/图片/提示词/种子/适配）、`add_storyboard_panels`（网格或显式条目，矩形与多边形都可以）、`update_storyboard_panel`（含多边形 `points` 与 `shape`）、`export_storyboard_page` 为写；`remove_storyboard_panel` 为删除；`generate_storyboard_panels` 计费（审批界面展示预估 Anlas，批量后台顺序执行，用状态工具轮询进度）。多边形编辑与画布同一条几何链路：顶点是页面像素，外接框取顶点包围盒；`inspect_storyboard_panel` 回传 `pixel_points` 供直接改写。工具契约由 `business_toolbox_contract_test.dart` 守护。

## 云同步

`storyboard-document` 适配器只同步 sidecar 文档本身（版面、提示词与相对路径引用），图片本体永不同步。归入图库内容组，默认开启；v2 及更早的旧快照可继续解码。恢复时整篇覆盖本地文档，删除墓碑不会清空本地排版。

## 验证

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/test_affected.ps1 -Path "lib/data/models/storyboard,lib/core/utils/storyboard,lib/data/services/storyboard"
flutter test test/data/cloud_sync/storyboard_cloud_sync_adapter_test.dart
flutter test test/presentation/agent_chat/services/business_toolbox_contract_test.dart
```

顶栏与画布回归注意：修改分镜交互后按 AGENTS.md 的热重载约定刷新已启动会话，并在 `700/840/1180/1600` 宽度下检查工具条不溢出；窄屏另跑 `320/390`，确认工具条留在视口内且首尾按钮都能滚动够到、页面信息 chip 不被覆盖。移动端相关的画布手势、窄屏布局与返回键回归见 `test/presentation/screens/generation/storyboard/storyboard_mobile_interaction_test.dart`。
