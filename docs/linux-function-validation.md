# Linux 功能验证

测试对象为 Linux x64 版及其共享 Vue/Electron 编辑内核，不包含 macOS 原生程序。使用合成项目与隔离配置目录；本次没有发布发行版。环境为 Debian 13、Node 24.19.0、Electron 44.5.1、Xvfb、软件 WebGL 与临时 GNOME Secret Service。

## 本轮发现和修复

| 问题 | 复现及影响 | 修复与回归 |
|---|---|---|
| 动画停止后选中错误帧 | 播放到第二帧再暂停、按 Esc 或导出，画布为第二帧，属性仍指向第一帧；接着重命名会改错帧 | 所有停止播放入口统一同步活动帧选择，查找嵌套组中的可绘制后代；GUI 检查保存后的所属帧与播放中导出的像素 |
| 滤镜改变选区外的透明像素 | 原透明像素隐藏 RGB 被清零；空选区操作会产生撤销记录、未保存状态，并删除可编辑形状元数据 | 零覆盖像素直接保留；对全部 21 项滤镜检查选区外每个 RGBA 字节，检查空选区保持修订号、重做与形状参数 |
| 新版项目恢复副本不可见 | 恢复列表仅接受版本 1–11，版本 12–16 的副本无法恢复，旧副本清理也失效 | 与项目读取器共用版本上限；验证旧格式、v16 动画恢复及保留最近两个副本，并通过原生菜单恢复实际快照 |
| 动画快捷键截获对话框操作 | PSD 对话框的取消按钮获得焦点后按空格，启动后台动画，无法激活取消 | 对话框打开时限制全局编辑快捷键，保留焦点循环、Escape 和原生按钮键盘操作；忽略输入法组合事件 |
| 播放中导出静默失败 | 帧正在渲染时点击原生 PNG 导出，播放停止但文件未生成 | 等待当前帧渲染任务结束，再检查项目 ID、修订号与渲染状态；GUI 检查导出文件及正确的绿色帧像素 |

五类修复均作用于 Windows/Linux 共享内核或界面。原生 macOS 源码没有修改。本轮还将独立格式样本和完整 GUI JSON 移出 Playwright 会清理的临时目录，避免后续局部测试删除验证证据。批量测试改为等待选区、加载和保存实际完成后发起后续操作，修正测试自身的时序问题；这些问题与上表五项应用 Bug 分开记录。

## 覆盖范围

| 功能组 | 自动化检查 |
|---|---|
| 文件与项目 | 新建、打开、另存、覆盖备份、重开、取消对话框、未知字段和未改动资源保留、坏文件/危险路径/读取预算拒绝 |
| 动画 | 全帧 GIF 导入、播放/暂停、嵌套帧选择、帧新增/复制/删除/排序、时长与重复次数、v16 保存重开、GIF 全帧导出、PNG/EPS 当前帧导出 |
| 图像格式 | PNG/JPEG/PSD 导入、分层与扁平 PSD、PNG/GIF/EPS 导出；GIF disposal 2/3、透明帧、交错、截断、预算与时间限制；EPS 二进制预览、边界框、DPI 和透明背景合成；通用 EPS 经真实 Ghostscript 导入 |
| 选区 | 矩形/椭圆/套索/魔棒、组合、扩缩/羽化/反选、选区填充和清除、选区转蒙版、选区撤销与文件修改状态 |
| 绘画与修整 | 画笔/橡皮擦、硬度/间距/对称、仿制取样、污点修复、模糊/涂抹/推移；零修改笔画、取消和异步修订号检查 |
| 填充 | 油漆桶、线性/径向渐变、透明/反向参数、选区限制和原像素保留 |
| 文字与形状 | 程序化中文/emoji/多行输入、文字选区样式、形状参数、保存重开后可编辑、预览取消、栅格化与撤销 |
| 变换与图层 | 数字位置/尺寸/旋转/翻转、多选变换、对齐/分布、编组/解组/复制/删除/合并、组传导、图层搜索/折叠/排序 |
| 蒙版与外观 | 蒙版创建/启停/反转/链接/应用、独立蒙版变换、剪贴源；24 种混合模式、全部 12 类调整与 6 类效果、禁用效果视觉保持 |
| 滤镜 | 全部 21 项滤镜的像素限制与界面预览/应用；取消/撤销、空选区保留历史与可编辑元数据 |
| 导航与剪贴板 | 抓手、取色、缩放/100%/适合窗口、网格/吸附、参考线保存与撤销、图层/合并复制、剪切/原生图像粘贴与像素保持 |
| 防误操作与恢复 | 内容/位置/外观/透明锁及祖先组继承、撤销/重做、失败批次原子性、异步旧结果拒绝、保存阶段进程中断、恢复快照 |
| Linux 集成 | 独立应用标识和语言设置、拒绝 basic_text 密钥存储、临时真实 Secret Service、Ghostscript 寻址、三种安装包源码/许可证/启动器一致性 |
| AI 助手 | 本地模拟模型服务测试设置、计划预览/应用、锁定和过期计划拒绝、取消和错误响应、敏感字段过滤；真实第三方服务未连接 |

主要测试位于 `windows/tests/`，新增覆盖集中在 `animation-formats.test.mjs`、`effects-filters.test.mjs`、`edit.test.mjs` 和 `smoke/extended-workflows.spec.mjs`。独立验证脚本为 `independent-psd.py`、`independent-image-codecs.py`，分别使用 psd-tools、Pillow 和 Ghostscript，避免只用自身编解码器验证自身输出。

## 验证结果

| 检查 | 结果 |
|---|---|
| 类型检查、源码/本地化审查 | 通过；458 个中英文字段匹配 |
| Node 单元测试 | 158 通过，0 失败、0 跳过 |
| 独立 PSD/GIF/EPS 读取 | psd-tools、Pillow 与真实 Ghostscript 全部通过 |
| 完整 GUI 运行 | 51 项全部执行：50 通过，1 项保存测试在渲染完成前调用菜单而失败 |
| 修正测试等待后的编辑模块复测 | 4/4 通过，覆盖上述唯一失败项；最终 51 个不同界面用例均有通过记录 |
| 解压后的 AppImage AppRun | 8/8 通过，包括暂停、Esc、播放中导出、恢复、编辑保存与 Linux 集成 |

完整运行的原始结果保留在 `windows/playwright-report/smoke-results.json`，复测结果单独保存在 `smoke-recheck-results.json`。未把原始运行的 1 项失败改写为通过；包审查分别记录 `guiChecks` 与 `guiRechecks`，核对复测覆盖原失败用例、运行先后顺序和应用内容哈希。复测期间只修改测试等待/超时设置，应用内容保持一致。Linux 多步骤流程允许 120 秒整体时间，每步断言和工作线程仍有各自的超时，未开启自动重试。

AppImage、Deb 与 tar.gz 已重新构建。最终包内容审查结果见 `linux/release/PACKAGE-REVIEW.json`，交付文件校验值见 `SHA256SUMS.txt`；发行版安装、FUSE 和真实桌面验收仍按下方边界记录。

## 复现

从 `windows/` 运行以下命令；先按 [Linux 安装说明](linux-install.md) 和 [CI](../.github/workflows/linux-verify.yml) 准备 Python、Xvfb、Ghostscript、D-Bus 与桌面密钥环。

```sh
npm ci
node scripts/audit-source.mjs
npm run typecheck
npm test
python tests/independent-psd.py
python tests/independent-image-codecs.py
npm run package:linux
xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' npm run smoke
npm run audit:linux
```

完整版 GUI 必须使用已解锁的 Secret Service，准备方法见 CI；不具备 Chromium 沙箱的容器仅对测试启动设置 `COMPOSITOR_SMOKE_NO_SANDBOX=1`。发行启动器保持沙箱，未自动添加绕过参数。`playwright-report/smoke-results.json` 保存完整 GUI 结果，`linux/release/PACKAGE-REVIEW.json` 记录包审查和测试统计，`SHA256SUMS.txt` 可校验交付文件。需要定向复测时使用独立输出，保留完整报告：

```sh
PLAYWRIGHT_JSON_OUTPUT_NAME=playwright-report/smoke-recheck-results.json \
  xvfb-run -a npx playwright test tests/smoke/editor.spec.mjs \
  --reporter=list,json --output ../linux/test-results/editor-recheck
```

完整 GUI 执行与复测之间必须保持应用构建一致；本轮用 `linux/test-results/full-gui-build.sha256` 验证。新构建的标准 CI 应从干净的输出目录运行完整套件。

## 实际限制

功能组覆盖不代表所有输入和交互组合均无 Bug。尚未验证真实 GNOME/KDE、Wayland/X11 桌面会话、硬件 GPU/画质基准、中文输入法实际组合输入、压感设备、多屏/高 DPI、ARM64、各发行版安装/升级、AppImage 的 FUSE 挂载启动，以及 Photoshop/Photopea 人工打开导出文件。AppImage 启动检查使用解压后的真实 AppRun；文件对话框使用模拟响应。真实 AI 服务与 KWallet 也未连接验证；AI 用本地模拟服务，中文用程序化输入。通用 EPS 依赖系统 Ghostscript，画质算法仍有既有产品限制。Ubuntu 24.04 CI 已配置，本次没有远程执行。
