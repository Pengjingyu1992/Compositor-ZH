"""Regenerate independent native-C fixtures on Linux; not required at runtime."""
import ctypes as c
import json
import math
from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "native/portable-color"


class Integer(int):
    pass


def curve(points, x):
    index = max(0, min(len(points) - 2, sum(point[0] <= x for point in points) - 1))
    deltas = [(b[1] - a[1]) / (b[0] - a[0]) for a, b in zip(points, points[1:])]

    def slope(i):
        if i == 0:
            return deltas[0]
        if i == len(points) - 1:
            return deltas[-1]
        return 0 if deltas[i - 1] * deltas[i] <= 0 else 2 / (1 / deltas[i - 1] + 1 / deltas[i])

    a, b = points[index:index + 2]
    h = b[0] - a[0]
    t = min(1, max(0, (x - a[0]) / h))
    return min(1, max(0, (2*t**3 - 3*t*t + 1)*a[1] + (t**3 - 2*t*t + t)*h*slope(index)
                      + (-2*t**3 + 3*t*t)*b[1] + (t**3 - t*t)*h*slope(index + 1)))


with tempfile.TemporaryDirectory(prefix="comp-camera-reference-") as directory:
    library = Path(directory) / "reference.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", str(NATIVE / "AdjustPixels.c"),
                    str(NATIVE / "LensPixels.c"), str(NATIVE / "bridge.c"), "-Wl,--wrap=malloc",
                    "-Wl,--wrap=calloc", "-Wl,--wrap=realloc", "-lm", "-o", str(library)], check=True)
    native = c.CDLL(str(library))
    width, height = 12, 8
    rng = random.Random(20261028)
    source = []
    for index in range(width * height):
        source.extend([rng.randrange(256), rng.randrange(256), rng.randrange(256), [255, 255, 128, 0][index % 4]])
    premultiplied = [math.floor(value * source[index//4*4+3] / 255 + .5) if index % 4 < 3 else value
                     for index, value in enumerate(source)]
    cases = []

    def output(label, settings, calls, preview=None):
        pixels = (c.c_uint8 * len(source))(*premultiplied)
        for name, values in calls:
            function = getattr(native, name)
            arguments = [pixels, width, height, width*4]
            types = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_size_t]
            retained = []
            for value in values:
                if isinstance(value, list):
                    array = (c.c_float * len(value))(*value)
                    retained.append(array)
                    arguments.append(array)
                    types.append(c.c_void_p)
                else:
                    arguments.append(value)
                    types.append(c.c_int if isinstance(value, Integer) else c.c_double)
            function.argtypes = types
            function.restype = None
            function(*arguments)
        cases.append({"label": label, "settings": settings, "preview": preview or {}, "expected": list(pixels)})

    light = {"temperature": 23, "tint": -12, "exposure": .6, "contrast": 17, "highlights": -33,
             "shadows": 26, "whites": -15, "blacks": 9, "vibrance": 32, "saturation": -14}
    warm, magenta = light["temperature"] / 100, light["tint"] / 100
    basic = ("adjust_camera_raw", [1+.35*warm+.15*magenta, 1-.3*magenta, 1-.35*warm+.15*magenta]
             + [light[key] for key in ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation"]] + [Integer(0)])
    output("light-and-color", light, [basic])
    for glow_style in range(3):
        for vignette_style in range(3):
            settings = {"texture": 26, "clarity": -18, "dehaze": 22, "glow": 30,
                        "glowStyle": ["Diffusion", "Bloom", "Halation"][glow_style], "glowRange": 25,
                        "glowSpread": 40, "glowWarmth": -15, "vignetteAmount": -40,
                        "vignetteStyle": ["Highlight Priority", "Color Priority", "Paint Overlay"][vignette_style],
                        "vignetteMidpoint": 35, "vignetteRoundness": -20, "vignetteFeather": 65, "vignetteHighlights": 30}
            effect = ("adjust_camera_raw_effects", [26, -18, 22, 30, Integer(glow_style), 25, 40, -15,
                                                   -40, 35, -20, 65, 30, Integer(vignette_style), 1])
            output("effects-%s-%s" % (glow_style, vignette_style), settings, [effect])
    negative = list(effect[1])
    negative[5:7] = [-30, -45]
    output("negative-glow-range-spread", {**settings, "glowRange": -30, "glowSpread": -45},
           [("adjust_camera_raw_effects", negative)])
    detail = {"sharpenAmount": 65, "sharpenRadius": 20, "sharpenDetail": 45, "sharpenMasking": 30,
              "noiseLuminance": 25, "noiseLuminanceDetail": 60, "noiseLuminanceContrast": 20,
              "noiseColor": 35, "noiseColorDetail": 45, "noiseColorSmoothness": 70}
    output("detail", {"detail": detail}, [("adjust_camera_raw_detail", list(detail.values()) + [1])])
    optics = {"removeChromaticAberration": True, "enableLensProfile": True, "profileDistortion": 30,
              "profileVignetting": 55, "distortion": -20, "purpleAmount": 40, "purpleHueLow": 260,
              "purpleHueHigh": 325, "greenAmount": 35, "greenHueLow": 50, "greenHueHigh": 135,
              "vignetteAmount": 20, "vignetteMidpoint": 60}
    optic_call = ("adjust_camera_raw_optics", [Integer(1), Integer(1), 30, 55, .35 * 10 / 100,
                                            40, 260, 325, 35, 50, 135, 20, 60, 1])
    output("optics", {"optics": optics}, [optic_call])
    for process in range(1, 7):
        calibration = {"shadowTint": 23, "redHue": -15, "redSaturation": 25, "greenHue": 17,
                       "greenSaturation": -30, "blueHue": 10, "blueSaturation": 15, "process": process}
        output("calibration-%s" % process, {"calibration": calibration},
               [("adjust_camera_raw_calibration", list(calibration.values())[:-1] + [Integer(process)])])
    mixer = {"hue": [20, -10, 0, 5, 0, 0, 0, 0], "saturation": [0, 15, 0, 0, -20, 0, 0, 0],
             "luminance": [0, 0, 20, 0, 0, 0, -10, 0],
             "points": [{"hue": 280, "saturation": .5, "luminance": .4, "hueShift": 20,
                         "saturationShift": -30, "luminanceShift": 15, "hueRange": 50,
                         "saturationRange": .6, "luminanceRange": .7}]}
    grading = {"shadows": {"hue": 220, "saturation": 20, "luminance": 5},
               "midtones": {"hue": 60, "saturation": 15, "luminance": -5},
               "highlights": {"hue": 30, "saturation": 10, "luminance": 8},
               "global": {"hue": 120, "saturation": 7, "luminance": 0}, "blending": 65, "balance": -15}
    red = [[0, 0], [.5, .7], [1, 1]]
    identity = [index/255 for index in range(256)]
    red_lut = [curve(red, index/255) for index in range(256)]
    wheels = sum(([grading[key]["hue"]/360, grading[key]["saturation"]/100, grading[key]["luminance"]/100]
                  for key in ["shadows", "midtones", "highlights", "global"]), [])
    color_call = ("adjust_camera_raw_curve_color", [identity, red_lut, identity, identity, 0,
                  [v/100 for key in ["hue", "saturation", "luminance"] for v in mixer[key]], Integer(1),
                  [280/360, .5, .4, .2, -.3, .15, 50/360, .6, .7], wheels, .65, -.15, Integer(-1)])
    settings = {"curve": {"red": [{"x": x, "y": y} for x, y in red]}, "mixer": mixer, "grading": grading}
    output("curve-mixer-point-grading", settings, [color_call])
    output("combined-color-detail-optics", {**light, **settings, "detail": detail, "optics": optics},
           [basic, color_call, optic_call, ("adjust_camera_raw_detail", list(detail.values()) + [1])])
    for clipping in [1, 2]:
        args = list(basic[1])
        args[-1] = Integer(clipping)
        output("clipping-%s" % clipping, light, [("adjust_camera_raw", args)], {"clipping": clipping})
    output("sharpen-mask", {"detail": detail}, [("adjust_camera_raw_sharpen_mask_overlay", [20, 45, 30, 1])], {"sharpenMask": True})
    output("stable-grain", {"grainAmount": 35, "grainSize": 20, "grainRoughness": 65},
           [("adjust_grain", [35, .5+.2*19.5, 65, Integer(0), 0, 0, 1])])
    result = {"reference": "macOS f8b1457 unmodified AdjustPixels.c/LensPixels.c, compiled independently as native C",
              "width": width, "height": height, "source": source, "cases": cases}
    (ROOT / "tests/golden/camera-raw-native.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print("Wrote", len(cases), "native Camera Raw fixtures")
