# macOS 40.21：滤镜、液化与恢复验收

日期：2026-10-10。范围为可编辑滤镜/持久液化验证与恢复时效改进。Windows 目录、桥接格式及发行渠道不变。

## 修复与改进

- **保存重开后的滤镜重算差异：**PNG 的直通 alpha 与内存图像的预乘 alpha 会给 Core Image 不同的中间精度。滤镜栈入口统一为 8 位预乘 sRGB，再执行相同参数，避免重新编辑时改变像素。
- **PSD 半透明合成预览变暗：**独立读取器发现合成 RGB 缺少白色衬底编码；修复仅用于合成预览，图层通道继续保存直通颜色。参考 [ag-psd 写入实现](https://github.com/Agamnentzar/ag-psd/blob/master/src/psdWriter.ts)与[读取实现](https://github.com/Agamnentzar/ag-psd/blob/master/src/psdReader.ts)，通过独立读取的显示像素比较验证。
- **恢复目录误拒绝：**路径相同、末尾斜杠不同的目录 URL 不再被当作不同目录。
- **恢复时机：**每次完成编辑捕获不可变快照；空闲 2 秒或连续编辑最长等待 10 秒安排检查点。正在进行的下一笔/模态草稿不阻塞上一份已完成快照，也不会混入未提交状态。
- **恢复资源复用：**仅编码变动图像；未变的 PNG 和相同节点 JSON 通过不可变硬链接复用到完整的新检查点。仍校验旧文件字节，不是操作日志或逐笔草稿恢复。
- **失败与关闭：**容量不足、损坏资源、未知版本和提交失败保留旧副本；正常关闭先补写 pending 编辑。写盘回调与 pending 快照按文档 ID 隔离，避免切换文档时覆盖待写状态。删除副本后会清理资源索引，后续可重新备份。

`.comp` 仍为普通项目 v13、含滤镜/液化的项目 v14；恢复元数据仍为 v1。没有新增公开持久化字段。详细时效、资源与中断语义见[恢复说明](recovery.md)。

## 可重复执行

```sh
scripts/check-editable-recovery-clt.zsh --crash --large --poster --output build/editable-recovery-evidence
scripts/check-editable-recovery-clt.zsh --save-stress
scripts/check-localization.zsh
COMPOSITOR_BUILD_ROOT="$PWD/build/recovery-40.21-final" scripts/build-clt.zsh
```

独立 PSD 检查使用临时工具目录中的 `ag-psd@31.0.2`、`pngjs@7.0.0`，依赖不进入应用安装包：

```sh
node scripts/check-filter-stack-psd.cjs build/editable-recovery-evidence /path/to/temporary/dependencies
node scripts/check-editable-psd.cjs build/editable-recovery-evidence /path/to/temporary/dependencies
```

CLT 检查覆盖五类滤镜、启停/零透明度/蒙版/重排、单步撤销重做、保存重开、冻结/选区/参数保存、早期液化步骤重编辑、DPI/裁剪/画布/重采样、取消/锁定/过期回调、恢复损坏/容量/连续编辑/下一笔进行中/关闭/文档切换/资源复用。强制中断仅针对临时目录中的测试写入子进程，未终止用户应用或修改用户项目。

使用新的输出目录运行包含 `--poster` 的组合检查：海报回归有意拒绝覆盖已经存在的同名项目。常规覆盖保存由 `--save-stress` 单独验证。

## 本机结果

| 检查 | 结果 |
| --- | --- |
| 可编辑滤镜与恢复 | 105 项，0 失败；含强制中断、4K/8K |
| 液化 | 95 项，0 失败；4K Metal、8K CPU，CPU/Metal 像素误差不超过 1 阶 |
| 第一批兼容回归 | 78 项，0 失败 |
| 快捷键 | 900 项，0 失败 |
| 海报功能 | 114 项，0 失败 |
| 路径与 PSD | 57 项，0 失败 |
| 覆盖保存压力 | 同一项目连续覆盖保存并回读 500 次，0 失败 |
| 重复运行 | 不含大图的组合检查另跑 3 轮，每轮 1,337 项，0 失败 |
| 独立 PSD 读取器 | ag-psd 31.0.2；滤镜样例 8 组检查，9,216 像素合成预览和图层通道差异均为 0；既有可编辑文字/矢量/渐变/效果样例检查通过 |
| 本地化 | 1,390 个候选键，缺失/未翻译/未解析均为 0；1,732 条翻译占位符检查通过 |
| 构建与安装 | app 与 CLI 优化编译成功；Documents 输出目录被文件提供器追加 FinderInfo 后，改用干净临时目录打包，ZIP 解压签名及二进制一致性校验通过；已安装 1.4.8（40.21） |
| GUI | 安装版启动、中文界面、原生 v14 样例打开及滤镜菜单入口已确认。菜单子项操作返回“元素失效”，截图接口不可用；后续参数点击/保存重开/液化重编辑 GUI 流程未完成，不计为通过 |

主组合回归共 **1,349 项**，加上覆盖保存压力共 **1,849 项**；重复运行及独立 PSD 检查另计，未将大量像素断言重复算入此数。

最后一轮 4K/8K 合成样例“滤镜处理 + 两次检查点 + 重开”分别约 0.65 秒、2.69 秒。8K 首次新写约 11.15 MB，未变资源的下一次检查点新写 203 字节元数据，仍读取旧资源进行校验。组合检查测得最高 RSS 约 3.22 GiB；样例与实现分支不同，数字仅用于本次回归。

安装包为 `Compositor-ZH-1.4.8-build40.21-macOS-arm64.zip`，SHA-256：`c619f06da02b2edb05c4a5e1dd193aeb89a8ec6e59297ac446fc28538d799f26`。安装版严格签名校验通过。

一次组合运行在原生保存路径出现 Cocoa 516（同名文件已存在）异常，未取得目标 URL；后续干净目录全套重跑、3 轮重复及 500 次同路径覆盖保存均未复现。**根因尚未确认，不能列为已修复。** 回归保存调用已补充错误域、代码及目标样例诊断，便于下次定位。

普通项目继续写 v13、带栈项目写 v14。两个已执行 CLT 回归的旧格式号断言已修正；另外 8 个同类 XCTest 断言也已按此兼容契约调整，但未在本机运行 XCTest。

## 验证边界

独立 CLT 运行与 GUI 实测分别记录，不等同于完整 XCTest。未执行真实压感笔、断电、故障磁盘、网络卷，以及 Photoshop/Photopea 的人工打开。4K/8K 使用合成样例，耗时和峰值不代表所有照片、LUT 或极端图层数量。备份最长等待 10 秒之外还需要编码与写盘，未完成草稿及最后一次未落盘编辑仍可能丢失。

新增文件：`Compositor/IO/RecoveryResources.swift`、`CompositorTests/EditableRecoveryRegressionTests.swift`、`scripts/check-editable-recovery-clt.zsh`、`scripts/check-filter-stack-psd.cjs` 及本文档。Xcode 同步组自动纳入 Swift 文件；CLT 脚本显式选择回归入口。
