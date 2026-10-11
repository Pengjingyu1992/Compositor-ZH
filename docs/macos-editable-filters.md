# 可编辑滤镜与液化重新编辑 / Editable filters and saved Liquify

macOS 1.4.8（40.20）实现第四批中选定的两项：基础滤镜栈、持久可重编辑液化；40.21 补充实测、透明度一致性修复及恢复检查点改进。智能对象和动作录制继续后延。

## 可编辑滤镜

1. 选择一个普通像素图层，打开 **滤镜 → 可编辑滤镜…**。
2. “添加滤镜”支持高斯模糊、动感模糊、添加杂色、彩色半调、Color Lookup（`.cube` LUT）。LUT 必须先导入有效文件才能启用并应用。
3. 选中步骤修改参数，勾选框启停步骤，上/下箭头调整执行顺序；可以设置不透明度或删除步骤。
4. 点击“刷新预览”查看当前参数，点击“应用”提交。预览过期时有提示，应用始终从源内容重新计算当前步骤。
5. 保存 `.comp` 后可从同一入口继续修改；“之前”显示源图。删除全部步骤并应用可恢复源像素。

步骤从列表顶部向下执行，采用原始像素大小，保持图层原有边界；模糊在边界裁切。图层变换、图层/矢量蒙版、剪贴关系和样式在缓存图像之外继续生效，避免重复应用。首版混合是源与处理结果的正常透明度混合，不提供每个步骤的独立混合模式。

有选区时，添加的滤镜步骤捕获它在图层局部像素中的灰度范围；之后移动或旋转图层，范围随源内容保留。可用“清除滤镜蒙版”让该步骤影响整个图层；不提供步骤蒙版绘制工具。调整图层及已有像素滤镜入口保持原有用途。

首版滤镜栈只直接处理普通像素层，不用于组、文字、形状、填充或调整层。内容锁定禁止修改；透明度锁定时拒绝进入通用滤镜栈，防止模糊等步骤改变 alpha。位置锁定仍允许内容编辑。

## 液化重新编辑

- “滤镜 → 高级液化…”继续新建一次液化，保留现有七种手动工具、基础/高级液化关联与画笔快捷键；平滑、左推保持移除。
- “应用”将原图、位移网格、冻结区域、选区覆盖、透明度保护及画笔参数保存为滤镜步骤。
- **滤镜 → 重新编辑液化…**打开当前图层最后一次已保存液化。重新打开项目后仍可使用。
- 有多次液化时，在“可编辑滤镜”中选择对应步骤，点击“重新编辑液化…”；先应用或取消当前滤镜栈草稿，再打开液化。
- 编辑某一步时，液化工作区显示该步骤之前的结果；后续滤镜在应用时重新计算。重新编辑采用当次保存的选区范围，不将当前选区覆盖到旧步骤上。
- 冻结和重建仍作用于同一位移核心。恢复全部变形后可以应用并保存；重新打开的逐笔历史从本次编辑开始，不保存过去会话的每一笔撤销记录。
- 新液化默认生成副本；重新编辑默认修改现有步骤，也可以生成副本。文字、形状、填充层必须生成像素副本，原有可编辑层保留并隐藏。

基础液化在主画布上仍是像素笔触，不自动将旧笔触还原为高级液化网格。旧版本已经固定成像素的滤镜/液化结果也无法自动恢复原始参数。

## 保存与互通

应用内普通项目保存为 v13；含可编辑滤镜/液化的项目保存为 **v14**；40.22 新增的通道半调配方需要 **v15**。移除全部栈或明确栅格化后，原生保存可回到 v13。当前 macOS 读取 v1–15；Windows 当前桥接只读取 v1–13，不能打开 v14/v15。交换 v14 项目时先保留原项目，再导出 PSD 或普通图像，或在副本上明确栅格化后保存。

源图、处理步骤和显示缓存在同一项目包内原子保存，恢复副本包含同样的编辑资源。源内容不依赖原始照片或 LUT 的磁盘路径，移动整个项目不会失去资源。损坏/缺失资源、未知节点版本、尺寸不一致和超预算明确拒绝，不能只保留预览而静默丢掉步骤。

PNG/JPEG/PDF/TIFF、批量导出和 PSD 使用当前完整结果。PSD 中滤镜栈/液化以像素保留，并显示转换说明；不声称输出 Photoshop 智能滤镜。原生项目继续保留参数。

## 像素编辑与资源限制

像素绘制、普通像素滤镜、基础液化及图像重采样会固定当前结果，移除对应滤镜栈；撤销可以恢复。可以先复制图层，或使用“滤镜 → 栅格化滤镜栈”明确固定。移动、常规缩放/旋转、复制、裁剪、画布尺寸、仅 DPI 修改、蒙版和样式编辑保留栈。

每层最多 32 步；源图和显示缓存共同计入文档图像预算。步骤的选区/位移/LUT 数据在整个文档内最多 256 MiB；编码后的单步最多 192 MiB、文档全部步骤文件最多 384 MiB。运行前检查工作内存估算，超过 1.5 GiB 或本机内存四分之一中的较小值时拒绝。历史保守计入保留的步骤数据及源图，仍遵守已有历史预算。

本次交付记录区分编译、静态审查与实际运行；未执行的 GUI、4K/8K、压感及外部软件互通检查不能记为通过。

## 40.20 交付核查

2026-10-09，本机完成以下构建与静态检查：

| 项目 | 结果 |
| --- | --- |
| CLT 优化构建 | 应用与 CLI 均成功，使用 macOS 26 SDK；没有运行 XCTest |
| 本地化静态检查 | 1,390 个候选键，缺失、未翻译及未解析运行时表达式均为 0；新增 24 个词条，存量词条内容不变 |
| 差异与范围 | `git diff --check` 通过；Windows 目录无改动 |
| 安装包 | ZIP 解压后的签名校验通过；应用/CLI 二进制 SHA-256 与构建产物一致 |
| 本机安装 | 更新到 1.4.8（40.20）；旧版应用和安装包移入可恢复的废纸篓 |
| 尚未执行 | 功能回归、保存重开实测、GUI 操作、4K/8K 压力、压感、CPU/GPU 图像比对及外部 PSD 打开 |

新增实现文件：[`EditableFilters.swift`](../Compositor/Document/EditableFilters.swift)（模型、重算与提交），[`FilterStackSheet.swift`](../Compositor/UI/FilterStackSheet.swift)（参数与步骤界面）。本说明与[修订计划](macos-next-batches.md)为新增文档。同步组会自动纳入上述 Swift 文件；没有加入实验文件或新测试文件。

## English summary

Filter → Editable Filters supports Gaussian Blur, Motion Blur, Add Noise, Color Halftone and `.cube` LUTs on ordinary pixel layers. Reorder, enable/disable, edit opacity and settings, refresh the preview and apply as one undo step. Filters use a fixed source-pixel grid and stay within layer bounds. Captured selections are step masks; layer masks, transforms and styles remain outside the stack.

Advanced Liquify now stores its original source, displacement/freeze grid, captured selection and brush settings. Filter → Edit Saved Liquify reopens the last saved step; select another Liquify step in Editable Filters to edit it. Later steps are recalculated on apply. Basic canvas Liquify remains a raster tool.

Projects with these steps use `.comp` v14, or v15 for the channel-screen halftone added in 40.22; ordinary application saves remain v13. Windows currently rejects v14/v15. Exported PSDs retain rendered pixels with a conversion note. Direct pixel edits and image resampling bake the stack; Undo restores it. Version 40.21 adds regression validation and recovery improvements; Smart Objects, action recording and face controls remain deferred.

Recovery schedules complete committed checkpoints after two seconds idle or a maximum ten-second wait during continuous edits, plus encoding and disk time. Unchanged images are reused; completed edits are captured independently of the next modal gesture. Reopening sources normalizes alpha representation before filtering. PSD merged previews now encode the white matte required for partial transparency. See [recovery details](recovery.md) and the [40.21 verification record](macos-recovery-validation.md).
