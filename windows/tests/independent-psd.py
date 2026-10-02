"""Cloud-only independent PSD reader check; no private project fixtures."""
from psd_tools import PSDImage

psd = PSDImage.open("test-results/independent.psd")
assert psd.size == (64, 48)
assert len(psd) == 2
bottom, top = list(psd)
assert bottom.name == "Coral / 珊瑚"
assert top.name == "Mint / 薄荷"
assert top.bbox == (5, 3, 21, 15)
assert top.opacity in (127, 128)
assert top.blend_mode.value == b"mul "
assert top.has_mask()
assert top.mask.topil().getpixel((0, 0)) == 128
assert top.topil().convert("RGBA").getpixel((0, 0)) == (120, 220, 180, 255)
assert bottom.topil().convert("RGBA").getpixel((0, 0)) == (240, 160, 144, 255)
print("Independent psd-tools reader: layers/order/offsets/opacity/blend/mask/pixels passed")
