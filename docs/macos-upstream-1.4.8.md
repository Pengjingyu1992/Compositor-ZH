# 1.4.8 更新使用说明 / Update guide

This macOS update adapts Compositor 1.4.6–1.4.8 and the custom-crop, WebP and CMYK contributions by [Lens-lzy](https://github.com/Lens-lzy). Exact source revisions are recorded in [UPSTREAM.md](../UPSTREAM.md).

## 新功能 / Features

| 功能 | 操作 / How to use |
| --- | --- |
| 命令搜索 / Command search | 显示 → 搜索命令，默认 ⌘F；输入中文名称，方向键选择、Return 执行、Esc 关闭。 / View → Search Commands, ⌘F; type a command or tool name, choose with arrows, run with Return, close with Esc. |
| 重复上次滤镜 / Last filter | 滤镜 → 重复上次滤镜，默认 ⌥⌘F，使用上次成功应用时的参数。⌃⌘F 保留给 macOS 全屏。 / Filter → Last Filter, ⌥⌘F, repeats the last successfully applied settings; ⌃⌘F remains the system fullscreen shortcut. |
| 画布全屏 / Canvas-only view | 显示 → 切换画布全屏，默认 F；再次按 F 退出。Esc 先取消当前画布操作，空闲时退出全屏。输入框保留正常文字输入。 / View → Toggle Fullscreen, F; F returns. Esc cancels the current canvas operation first, then leaves fullscreen when idle. Text fields retain normal typing. |
| 导航器 / Navigator | 显示 → 导航器；缩放到 300% 及以上时出现，点击或拖动缩略图移动视图。 / Enable View → Navigator; at 300% or above, click or drag the minimap to move the view. |
| 自定义裁剪 / Custom crop | 裁剪工具 → 比例 → 自定义；输入正数宽:高，例如 9:20、2.5:1。 / Crop → Ratio → Custom; enter a positive width:height ratio. |
| 新建画布 / New canvas | 宽高下方可切换像素、英寸、厘米、毫米，72/300 DPI，以及透明、白色、黑色背景。宽高互换按钮保留。 / Cycle units, 72/300 DPI and transparent/white/black backgrounds below the dimensions. Dimension swapping remains available. |
| WebP | 支持打开、导入及拖放静态 WebP，包括透明图片；未新增 WebP 导出或动画编辑。 / Open, import or drop static WebP images, including transparency. WebP export and animation editing are not included. |
| 扫描线 / Scanlines | 滤镜 → 扫描线；独立于抖动滤镜，包含粗细、点状、位移、平滑、阈值、色彩分离与黑场。 / Filter → Scanlines, separate from Dither, with thickness, dots, displacement, smoothness, threshold, color split and black level. |

可在编辑 → 键盘快捷键中修改应用快捷键；提示会跟随设置更新。 / App shortcuts can be changed in Edit → Keyboard Shortcuts; hints follow the saved assignments.

## 导出 / Export

文件 → 导出为（默认 ⇧⌥⌘W）提供 PNG、JPEG、单页 PDF 和 CMYK TIFF。可调整输出宽高、比例并预览，原文档尺寸保持不变。JPEG 可选质量和透明区域的背景色；PDF 页面尺寸由输出像素和文档 DPI 决定。现有 PSD 导出及多尺寸批量导出保留。

File → Export As (⇧⌥⌘W) offers PNG, JPEG, single-page PDF and CMYK TIFF. Resize and preview the output without resizing the document. JPEG provides quality and a transparency matte; PDF page size follows output pixels and document DPI. Existing PSD and multi-size batch export remain available.

## CMYK 印刷预览 / CMYK print preview

1. 显示 → 印刷设置，选择印刷服务商提供的 **CMYK 输出 ICC**（`.icc` 或 `.icm`）。RGB 或无效配置文件会被拒绝。 / View → Print Setup; choose the print provider's **CMYK output ICC**. RGB and invalid profiles are rejected.
2. 选择相对比色或感知渲染意图，以及透明区域的背景色。 / Choose relative colorimetric or perceptual conversion and the transparency matte.
3. 开启 CMYK 印刷预览；配置文件包含色域数据时，可开启色域警告。灰色警告只显示，不会导出。 / Enable CMYK Print Preview; Gamut Warning is available when the profile supplies gamut data. Gray warning marks are never exported.
4. 文件 → 导出为 → CMYK TIFF。输出为四墨色通道、无透明通道的 TIFF，嵌入所选 ICC 和文档 DPI。对比 sRGB 仅切换预览，不改变输出。 / Export As → CMYK TIFF writes four ink channels without alpha, with the selected ICC and document DPI embedded. Compare sRGB changes only the preview.

**范围：**文档继续采用 sRGB，印刷设置仅在本次会话内有效，不写入 `.comp`，项目格式保持 v13。预览不模拟纸白或黑墨，不包含 CMYK 通道编辑、分色、叠印预览或 PDF/X。预览使用可见区域的 CPU 合成，大画布和高分辨率屏幕可能变慢；关闭预览后恢复正常 GPU 路径。需要印刷服务商确认实际印刷条件。

**Scope:** Documents remain sRGB. Print settings are session-only and do not change `.comp` v13. The proof does not simulate paper white or black ink, and does not add CMYK channel editing, separations, overprint preview or PDF/X. Proofing uses CPU compositing of the visible viewport and can be slower on large/high-DPI views; disabling it restores the normal GPU path. Confirm production conditions with the print provider.

## 修复 / Fixes

- Camera Raw 阴影/高光保持色调顺序；彩色降噪改善透明边缘，RAW 导入采用高精度渲染与抖动量化。 / Camera Raw shadows/highlights preserve tone order; chroma noise reduction handles alpha edges, and RAW import uses high-precision rendering with dithered quantization.
- 颜色叠加、内发光和内阴影正确处理半透明像素，保留叠绘已有叠加样式。 / Color Overlay, Inner Glow and Inner Shadow handle translucent pixels while retaining this edition's additional styles.
- 窄窗口工具栏可水平滚动；画布选择图层后自动滚动到对应图层；图层重命名保持行高。 / Narrow tool headers scroll horizontally, canvas-selected layers are revealed, and renaming keeps row height stable.
- 保留液化、钢笔、路径、PSD、图层锁、恢复副本、中文与英文切换，以及本仓库的更新入口。 / Existing liquify, pen/paths, PSD, locks, recovery, language settings and this edition's update channel are retained.
