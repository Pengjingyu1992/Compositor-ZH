"""Independent readers for public synthetic GIF/EPS fixtures from the Node suite."""
from pathlib import Path
from tempfile import TemporaryDirectory
import shutil
import subprocess
from PIL import Image

directory = Path('playwright-report/codec-fixtures')
with Image.open(directory / 'independent-animation.gif') as animation:
    assert animation.size == (8, 6)
    assert animation.n_frames == 3
    assert animation.info['loop'] == 2
    for i, (color, duration) in enumerate([((255, 0, 0, 255), 50), ((0, 255, 0, 255), 120), ((0, 0, 255, 255), 230)]):
        animation.seek(i)
        assert animation.info['duration'] == duration
        assert animation.convert('RGBA').getpixel((3, 2)) == color
print('Independent Pillow GIF reader: frames, dimensions, timings, repeats and pixels passed')

interpreter = shutil.which('gs')
if not interpreter:
    raise RuntimeError('Ghostscript is required for the independent EPS check')
with TemporaryDirectory(prefix='comp-eps-independent-') as temp:
    output = Path(temp) / 'decoded.png'
    subprocess.run([interpreter, '-dSAFER', '-dBATCH', '-dNOPAUSE', '-dQUIET', '-dEPSCrop', '-r72', '-sDEVICE=png16m', f'-sOutputFile={output}', str(directory / 'independent-raster.eps')], check=True)
    with Image.open(output) as image:
        assert image.size == (3, 1)
        rgb=image.convert('RGB')
        assert [rgb.getpixel((x, 0)) for x in range(3)] == [(255, 0, 0), (127, 127, 255), (255, 255, 255)]
print('Independent Ghostscript EPS reader: dimensions, RGB samples and alpha matte passed')
