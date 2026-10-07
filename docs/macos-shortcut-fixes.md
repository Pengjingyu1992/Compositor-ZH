# macOS 快捷键修复 / Shortcut fixes

日期 / Date: 2026-10-07。版本 / Version: 1.4.5 (40.11)。

## 修复范围 / Changes

- 中文输入状态产生的 `【】`、`「」`、全角方括号等在快捷键边界归一化；默认及自定义笔刷大小/硬度键共用映射，文本输入保持原字符。
- 画布与图层列表共用工具切换：图层焦点下 Shift-U 可切换形状，Tab 可切换模式，Shift-Tab 保留反向焦点导航。
- 图层焦点下，内容识别填充不可用时 Shift-Delete 不再误删图层。
- 图层列表支持 Command-方向键移动选区像素，Shift 使用 10 像素步长；共用编辑路径、撤销及文档身份检查。
- PSD 导出、PSD 转换、RAW 导入和恢复窗口接入自定义确认/取消键。系统文件选择器保留系统按键；快捷键编辑器自身仍以 Return 保存、Esc 取消。
- 工具提示、状态栏、颜色切换、图层按钮及缩放帮助从实际配置生成按键名称，中文与英文均适用。
- “隐藏其他应用”设置名称与实际命令一致；旧 `Menus:Hide Compositor` 配置迁移到 `Menus:Hide Others`，同时存在时新 ID 优先。
- 禁止分配系统全屏键 Control-Command-F。加载旧配置时仅移除该保留键的覆盖，保留其他有效配置。
- 保留此前已安装的修复：色彩范围等待最新计算后确认，取消或文档替换后拒绝旧结果；默认图层/形状名称使用当前语言，相关测试同步适配。

Chinese punctuation is normalized only at shortcut boundaries. Canvas and layer responders share tool switching and selected-pixel nudging. App-owned dialogs use the configured Apply/Cancel chords; system file panels and the shortcut editor retain their documented system keys. Labels show the actual bindings. The Hide Others identifier is migrated, and the system full-screen chord is reserved. Previously installed Color Range and localized-name repairs are retained. This change does not alter Windows code or the `.comp` format.

## 验证 / Verification

- `scripts/check-shortcuts-clt.zsh`：**862 项检查，0 失败**。使用真实生产代码，覆盖 114 项定义的映射、重绑定、存储、旧键停用、名称迁移、中文标点、响应器差异、像素移动及撤销/重做、旧文档回调拒绝，以及色彩范围异步确认/取消。
- CLT 完整应用编译成功；应用通过严格签名验证。
- 本地化：**1,064** 个候选键，缺失/未译/未解析均为 **0**；**1,382** 项翻译签名检查，**0** 失败。
- 隔离应用原生操作：中文方括号使大小 40→33→40、硬度 100→75→100，画布与图层焦点均有效；图层 Shift-U 切换形状、Shift-Tab 不切换；图层 Command-右键产生“移动像素”撤销步骤；无选区时图层 Shift-Delete 保留原图层。
- 原生改键：画笔改为 Control-Option-Y，工具栏与模式提示立即更新，退出重开后保留；PSD 窗口改用 Control-Option-O 取消、Control-Option-P 确认，旧 Esc/Return 不再触发该窗口操作。进入系统保存面板后 Esc 仍可取消。
- “隐藏其他应用”的中文设置标题已核对；实际隐藏操作未执行。RAW/PSD 转换窗口的真实文件流程未逐一操作，验证范围为接线审查及编译。未在本机运行完整 Xcode/XCTest/UI 测试；CI 另行执行，不将排队或运行中视为通过。

The CLT regression executes 862 checks with zero failures, using production code rather than copied shortcut implementations. It does not replace full Xcode or UI coverage. Native checks used synthetic documents in a separate app identity. Actual RAW and PSD-conversion file workflows were not individually exercised. No user photos or project files were used as test fixtures.

## 审查 / Review

新增源码、注释、文档、测试与构建产物检查未发现个人路径、私人邮箱、API Key 或私钥。新提交采用 GitHub noreply 身份；测试文档、应用备份和本机日志不纳入仓库。未改写既有 Git 历史。

Reviewed the changed source, comments, documentation, tests and build output for private paths, personal email addresses and credentials. Test documents, backups and local logs are excluded from the repository. Existing Git history is retained.
