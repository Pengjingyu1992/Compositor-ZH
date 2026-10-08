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

命令 `kind`：`addFill` / `editFill` / `addText` / `transform` / `opacity` / `blendMode` / `remove` / `invert` / `fillPixels` / `filter` / `effects` / `reorder`。已有图层用 `layerID`；未指定时操作候选文档的活动层。`addFill` 后它成为活动层，适合在下一条设置外观。命令模型见 `PosterCommand`；填充与文字模型见项目格式文档。初版不提供动作录制，也不导入外部脚本。

`filter` 用 `FilterKind` 的英文固定名称。可选 `amount` 目前用于 Color Halftone（网点大小）、Mosaic（块大小）、Gaussian Blur（半径）、Grain（强度）；其它参数通过图形界面调整。自动抠图和 Camera Raw 不通过此命令开放。`fillPixels` 复用选区/锁定填充路径，当前只接受不透明 RGB 色。

CLI 与 MCP 保存和预览只创建新目标；原文件和已有目标都保留。它们不会把内存文档标记为已保存。CLI `batch` 需携带 `inspect` 的包 SHA256，并在加载、提交前复核源包。GUI 编辑命令还验证文档 UUID 与修订。错误码 `stale` / `stale_locks` / `busy` / `locked` / `invalid` / `unsupported` / `stale_or_locked` / `execution` 可供客户端分类；人类说明可本地化，不能作为程序判据。
