# 叠绘：外观与实时 MCP

适用版本：macOS 1.4.8，build 40.36。

## 新工作区

- 设置 → 外观：跟随系统、亮色或暗色。界面外观不改变图片颜色。
- 左侧工具轨可滚动；抓手、缩放和前景／背景色固定在底部。通过快捷键选工具时，工具轨会滚动到对应位置。
- 工具选项栏位于画布上方，保持紧凑的单行布局；小窗口可横向滚动查看其余参数，应用／取消等结束操作保持独立。标题栏与参数区之间有细分割线。
- 检查器可以收起；窄窗口通过顶部检查器按钮打开浮层。图层和历史分别保留，图层属性可折叠。
- 状态栏分别显示文件是否保存与恢复保护，保存恢复副本不会把文件标为已保存。

## 连接 AI 客户端

实时连接默认关闭。现有独立 CLI 工作流仍可使用。

1. 打开 **叠绘 → 设置 → 连接**，开启“允许 AI 客户端连接”。
2. 输入客户端名称并点击“添加客户端”。展开该客户端，选择读取、编辑、文件、删除与关闭的权限。
3. 点击“复制客户端配置”，粘贴到支持 stdio MCP 的客户端配置中。请使用应用生成的实际路径，不要套用别人的安装路径。
4. 客户端第一次请求文档时，叠绘会询问是否允许访问指定文档。也可以在设置中手动“授权当前文档”。其他标签页不会自动获得授权。
5. 如需保存或导出，在设置中选择 **MCP 写入文件夹**。打开项目仍需通过文件选择器确认。

只有读取权限时，客户端可以获取已授权文档、图层和画布 PNG 预览。编辑权限开放原子批量操作、选择和视图设置。删除、替换蒙版、栅格化、覆盖像素、撤销、重做和关闭，还需要“删除与关闭”权限及本次操作确认。

工具栏的 MCP 菜单可以暂停所有连接和查看活动记录。设置中可暂停或撤销单个客户端。活动记录不保存文档内容、命令参数、路径或凭据；只有仍处于最新历史位置的修改可以直接撤销。

客户端凭据保存在钥匙串，并生成仅当前用户可读的配置文件。复制的客户端配置只包含启动命令和配置文件路径。不要把该私有文件、其内容或客户端配置提交到公开仓库。

## 文件行为

- 保存创建新的 `.comp` 副本；导出创建 PNG；批量导出创建新的输出子目录。
- 输出限于选定的 MCP 文件夹。名称不能携带路径；已有文件、目录和符号链接不能被覆盖。
- 保存副本不改变原文档的保存位置和未保存标记。
- 打开项目先完成加载、校验和文件监视，再加入工作区。失败或授权变化不替换当前文档。
- 无法访问、暂停、撤权、编辑冲突或旧令牌都会返回错误。

## 开发与客户端约定

`compositor-cli mcp` 和 `mcp --standalone` 保持独立文档模式。实时模式使用设置生成的 `mcp --live --config …` 配置，连接失败不会退回独立模式。

实时工具共 17 个，并提供 8 个旧名称别名：

| 类别 | 工具 |
|---|---|
| 读取 | `list_documents`、`get_document`、`render_preview`、`get_capabilities`、`get_operation_result` |
| 编辑 | `execute_commands`、`undo`、`redo`、`set_layer_locks`、`select_layers`、`set_view` |
| 文件与生命周期 | `new_document`、`open_document`、`save_document`、`export_document`、`batch_export_document`、`close_document` |

实时别名使用实时模式的权限与参数契约。旧独立模式的工具、参数和副本保存方式继续保留。

修改前先调用 `get_document`，携带其 `revision`、`changeToken`、`lockRevision` 和运行实例 handle。`changeToken` 在撤销／重做后也会变化，不能只检查历史 revision。`execute_commands` 复用原有 21 种命令，一批成功形成一步历史，失败不提交任何命令。

每次写请求使用 `get_capabilities.operationPrefix + UUID` 作为 `operationID`。超时后用相同参数、相同 ID 重试或查询回执。相同 ID 的不同参数会被拒绝。回执可能过期；`unknown`／`receipt_expired`／`pending_or_expired` 不代表未执行，不能据此换一个 ID 盲目重试。

每个桥接运行实例最多接受 2,048 个操作 ID，保留最多 128 份、合计不超过 16 MiB 的详细回执。关闭后重新开启连接会更换运行实例，旧 handle 和操作 ID 失效；历史回执不持久化。

兼容旧版初始化协议，并支持 2026-07-28 的逐请求元数据、`server/discover`、资源、固定提示模板和 `subscriptions/listen`。资源仅列出已授权文档；通知只发送客户端明确订阅的类型和 URI。协议依据：[MCP 官方规范](https://modelcontextprotocol.io/specification/2026-07-28)。

传输使用应用容器内的 Unix socket，目录 0700、socket 0600；校验同一用户身份，并通过每客户端秘密进行双向挑战认证。不监听 TCP，不执行 shell，不新增网络服务沙箱权限。

## 验证方法

使用已有 Command Line Tools 即可：

```sh
./scripts/build-clt.zsh
./scripts/check-localization.zsh
./scripts/check-live-mcp-clt.zsh
python3 scripts/check-poster-cli.py build/clt/Compositor.app/Contents/MacOS/compositor-cli
python3 scripts/check-live-mcp-wire.py build/live-mcp-checks build/clt/Compositor.app/Contents/MacOS/compositor-cli
./scripts/check-memory-performance-clt.zsh
python3 scripts/record-design-baseline.py build/memory-performance-checks --large --output build/square.json
python3 scripts/record-design-baseline.py build/memory-performance-checks --large --widescreen --rss-limit-mib 3072 --output build/widescreen.json
```

`check-live-mcp-wire.py` 在独立临时沙箱应用中使用合成文档、临时钥匙串凭据和真实外部 stdio CLI。不会给安装版注册客户端，也不读取个人项目。可用 `--schema` 指向官方 2026-07-28 `schema.json` 做结果与通知校验；此可选校验使用 Python `jsonschema`。

性能记录中的 RSS、Metal 分配、缓存计费分开报告。512×512 离屏合成与 GPU 读回计时不是屏幕帧率或输入到光子的延迟。方形压力场景与 3840×2160／7680×4320 场景分开运行。
