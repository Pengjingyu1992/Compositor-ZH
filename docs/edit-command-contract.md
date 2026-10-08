# 编辑命令契约（macOS）

CLI、MCP 和应用内“文件 → 编辑命令”现已共用同一候选文档事务入口。安装与示例见 [macos-poster-batch.md](macos-poster-batch.md)。

## 请求与身份

每次写入携带文档 UUID、预期的 `DocumentHistory.currentRevision`、锁状态 UUID `lockRevision`、操作及参数。图层用 UUID 标识，不用名称或列表下标。异步操作额外持有 `EditOwner` 的编辑实例；文档、修订、实例三者都必须在提交时仍匹配。重试必须重新检查修订，不自动把旧请求套到新文档。

最低限度命令族：文档检查/预览；图层选择/顺序/位置/外观/锁定；像素填充/调整；项目保存与图像导出；历史撤销/重做。外部调用与按钮、菜单、快捷键调用同一编辑函数。

## 结果

- `changed`：实际提交了文档改变，返回新修订。
- `unchanged`：合法但没有改变，不增加历史或未保存标记。
- `rejected`：文档/修订失效、编辑忙、模态占用、目标无效或锁定；不修改文档。
- `failed`：执行失败，提供稳定错误码和可本地化说明；不残留部分结果。

会话锁定可以改变会话状态，但不改变文件修订；`automationState` 返回独立的 `lockRevision`；MCP 编辑请求必须携带 `expectedLockRevision`。锁定变化不产生文档撤销项。

## 事务与许可

文档缺失/忙碌/模态由 `editingRefusal` 判定；目标内容、位置、外观和结构由 `allowsLayerEdit` 及祖先组规则判定。读取、复制和历史恢复与当前层写权限分开。透明度锁保护源像素 alpha；锁定不写入项目。

批量写入先在局部候选文档完成全部计算和校验，再在一个外层历史事务中提交。异步提交重新检查身份与全部目标许可。任一操作失败整批放弃；不能靠逐步调用按钮然后连续撤销实现回滚。交互式预览保留原始值，取消恢复原值。现有 `endEdit` 增加整批锁定校验作为防漏检查，不能代替各操作的预检。

嵌套操作只由外层提交，禁止在内层伪造一个独立成功修订。固定撤销名作为词条键，在显示时本地化，不把数量或名称插入键中。

## 保存

保存针对捕获的文档及修订。写盘完成只能标记捕获的修订已保存，写盘期间发生的新编辑仍为未保存。恢复副本不调用 `markSaved`。输出路径、覆盖意图与格式必须明确；先验证路径和资源预算，失败保留原文件。

## 当前范围

MCP 使用 stdio JSON-RPC，协商版本 2025-11-25 / 2025-06-18 / 2024-11-05；不声称实现 2026 新协议。服务打开自己的内存文档，不遥控正在运行的图形窗口。支持请求取消、最多八个显式项目句柄及 `close_project`。本机文件访问由启动它的用户权限决定，没有网络监听器，也没有任意 shell 命令入口。

命令 `kind`：`addFill` / `editFill` / `addImage` / `addText` / `editText` / `transform` / `opacity` / `blendMode` / `visibility` / `remove` / `invert` / `fillPixels` / `filter` / `effects` / `reorder` / `setMask` / `refineEdges`。已有图层用 `layerID`；未指定时只操作候选文档的活动层，不继承 GUI 多选集合。`addFill` 后它成为活动层，适合在下一条设置外观。命令模型见 `PosterCommand`；填充与文字模型见项目格式文档。初版不提供动作录制，也不导入外部脚本。

`filter` 用 `FilterKind` 的英文固定名称。可选 `amount` 目前用于 Color Halftone（网点大小）、Mosaic（块大小）、Gaussian Blur（半径）、Grain（强度）；`halftone`、`selectiveColor`、`channelMixer`、`lut` 可传本批调色的完整参数。`Color Lookup` 必须提供 LUT，缺失时拒绝而非静默成功。自动抠图通过 `refineEdges.edge.selectSubject` 提供；Camera Raw 不通过此命令开放。`fillPixels` 复用选区/锁定填充路径，当前只接受不透明 RGB 色。

CLI 与 MCP 保存和预览只创建新目标；原文件和已有目标都保留。它们不会把内存文档标记为已保存。CLI `batch` 需携带 `inspect` 的包 SHA256，并在加载、提交前复核源包。GUI 编辑命令还验证文档 UUID 与修订。错误码 `stale` / `stale_locks` / `busy` / `locked` / `invalid` / `unsupported` / `stale_or_locked` / `execution` 可供客户端分类；人类说明可本地化，不能作为程序判据。

## 海报命令补充（40.17）

- `addImage.imageData`：Base64 JPEG/PNG/HEIC/TIFF，解码数据上限 16 MiB，沿用图像导入的 EXIF 方向、sRGB 转换和像素预算；`name` 与 `transform` 可选。无路径读取或脚本执行。
- `editText.text`：完整 `LayerTextStyle`，只修改可编辑文字；可从 `project_state.layers[].text` 读取后修改。沿用文字编辑的 UTF-16、变换、蒙版和撤销语义。
- `visibility.visible`：显式布尔值。`transform` 与 GUI 一样携带已链接蒙版、固定未链接蒙版的位置。
- `setMask.maskData`：Base64 图像按亮度 × alpha 转为灰度覆盖，白色显示、黑色隐藏；坐标覆盖图层自身。删除用 `clearMask: true`，不能同时传数据。
- `refineEdges.edge`：`selectSubject`、`feather`（0–100 原图像素）、`shift`（−100–100 原图像素）、`contrast`（0–100）、`decontaminate`（0–100）、`createsCopy`、`strokes`。每条笔触含 `mode`（`Refine Edge`/`Reveal`/`Hide`）、`diameter`（原图像素）、`strength`（0–1）和 `points`（`[x,y]`，原图左上角为原点）。最多 1,000 笔、100,000 点；与 GUI 使用同一修边核心。
- `filter.halftone`：`size`、`cyan`、`magenta`、`yellow`、`black`、`shape`（`Round`/`Square`/`Line`）、`strength`。
- `filter.channelMixer.coefficients`：12 个百分比，按 R/G/B 输出通道依次输入 R、G、B、常量，每项 −200–200。
- `filter.selectiveColor`：`relative` 与 `adjustments` 对象；键为 `Reds/Yellows/Greens/Cyans/Blues/Magentas/Whites/Neutrals/Blacks`，值为四个 CMYK 百分比（−100–100）。不认识的色域拒绝。
- `filter.lut`：`.cube` 原文 `cube`、`strength`（0–100）和 `space`（`Encoded sRGB`/`Linear sRGB`）。使用现有 LUT 解析、域范围和插值。

所有非可选结构字段都应传齐；可选字段可以省略。单批 JSON/单条 MCP 消息上限 32 MiB。调用 `project_state` 可读取变换、填充、文字、样式及蒙版存在状态。

`batch_export_project` 接受 `handle`、`expectedRevision`、现有目录 `path`、`options` 与可选 `layerIDs`。`options`：`longSides`、`format`（`PNG`/`JPEG`）、`quality`（0–1）、`prefix`、`individualLayers`。分别导出图层时显式传 UUID；整图导出不需要。CLI 等价入口：

```sh
"$CLI" batch-export ./poster.comp ./export-options.json ./exports
```

```json
{"longSides":[0,1080,2048],"format":"PNG","quality":0.9,"prefix":"poster-","individualLayers":false}
```

每次创建新目录；取消或失败清除暂存目录，不覆盖项目或已有输出。GUI 显示文件计数并提供“取消导出”。单个图像编码期间的取消会在该文件处理完成后生效。
