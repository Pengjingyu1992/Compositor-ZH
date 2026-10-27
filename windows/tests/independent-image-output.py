"""Check shared image exports using Pillow and (where installed) Ghostscript."""
from pathlib import Path
import io
import shutil
import subprocess
import tempfile
from PIL import Image, ImageCms

root = Path(__file__).resolve().parents[1] / "playwright-report/codec-fixtures/image-output"
for extension in ("png", "jpeg", "webp", "avif", "tiff"):
    with Image.open(root / f"sample.{extension}") as image:
        image.load()
        assert image.size == (8, 4), (extension, image.size)
        assert image.info.get("icc_profile"), extension
        ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
        if extension == "jpeg":
            assert image.mode == "RGB"
            assert all(abs(a - b) <= 4 for a, b in zip(image.getpixel((0, 0)), (217, 157, 177)))
        else:
            assert "A" in image.mode, (extension, image.mode)
            assert abs(image.getpixel((0, 0))[-1] - 128) <= 1
with Image.open(root / "sample.cmyk.tiff") as image:
    image.load()
    assert image.mode == "CMYK" and image.size == (8, 4)
    profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
    converted = ImageCms.profileToProfile(image, profile, ImageCms.createProfile("sRGB"), outputMode="RGB")
    assert all(abs(a - b) <= 12 for a, b in zip(converted.getpixel((0, 0)), (217, 157, 177)))
print("Independent Pillow: PNG/JPEG/TIFF/WebP/AVIF, alpha, ICC and four-channel CMYK passed")
gs = shutil.which("gs") or shutil.which("gswin64c")
if gs:
    with tempfile.TemporaryDirectory(prefix="comp-pdf-check-") as directory:
        output = Path(directory) / "pdf.png"
        subprocess.run([gs, "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dPDFSTOPONERROR", "-sDEVICE=png16m", "-r144", f"-sOutputFile={output}", str(root / "sample.pdf")], check=True, capture_output=True)
        with Image.open(output) as image:
            assert image.size == (8, 4)
            assert all(abs(a - b) <= 6 for a, b in zip(image.getpixel((4, 2)), (217, 157, 177)))
    print("Independent Ghostscript: PDF ICC image, page dimensions and RGB pixels passed")
else:
    print("PDF raster check not run: Ghostscript is unavailable")
