"""Independent rational-coordinate raster reference; no Core Image golden claim.

Uses exact Fraction Gaussian elimination and barycentric coordinates. The
synthetic source includes soft alpha and saturated hidden RGB. Keep this file
and the small generated JSON together so fixtures can be reproduced offline.
"""
import json
from fractions import Fraction as F
from pathlib import Path


def cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def inverse_quad(corners):
    rows = []
    for (x, y), (u, v) in zip(corners, ((0, 0), (1, 0), (1, 1), (0, 1))):
        rows += [[x, y, 1, 0, 0, 0, -u*x, -u*y, u], [0, 0, 0, x, y, 1, -v*x, -v*y, v]]
    rows = [[F(v) for v in row] for row in rows]
    for column in range(8):
        pivot = next(i for i in range(column, 8) if rows[i][column])
        rows[column], rows[pivot] = rows[pivot], rows[column]
        amount = rows[column][column]
        rows[column] = [v / amount for v in rows[column]]
        for i in range(8):
            if i != column:
                amount = rows[i][column]
                rows[i] = [v - amount*w for v, w in zip(rows[i], rows[column])]
    return [row[-1] for row in rows]


def quantize(v):
    return max(0, min(255, int(v + F(1, 2))))


width, height = 5, 4
pixels = [[(x*43+y*17) % 256, (y*61+x*11) % 256, 255-x*41, (0, 64, 128, 192, 255)[(x+y*2) % 5]] for y in range(height) for x in range(width)]


def sample(u, v, nearest):
    u, v = u*width, v*height
    if nearest:
        return pixels[min(height-1, int(v))*width+min(width-1, int(u))]
    u, v = u-F(1, 2), v-F(1, 2)
    ix, iy = u.numerator // u.denominator, v.numerator // v.denominator
    fx, fy = u-ix, v-iy
    sums = [F(0)]*4
    for y in range(2):
        for x in range(2):
            p = pixels[max(0, min(height-1, iy+y))*width+max(0, min(width-1, ix+x))]
            weight = (fx if x else 1-fx)*(fy if y else 1-fy)
            sums[3] += p[3]*weight
            for channel in range(3):
                sums[channel] += p[channel]*p[3]*weight
    return [quantize(sums[c]/sums[3]) if sums[3] else 0 for c in range(3)]+[quantize(sums[3])]


cases = []
definitions = [
    ('perspective', [[0, 0], [8, 1], [6, 7], [1, 5]], False, False, True),
    ('perspective-smooth', [[0, 0], [8, 1], [6, 7], [1, 5]], False, False, False),
    ('mirrored', [[7, 0], [0, 1], [2, 6], [6, 5]], False, False, True),
    ('negative-fractional', [[-2.25, -1.5], [4.5, -2], [5, 3.75], [-1, 4]], True, True, False),
    ('folded', [[0, 0], [7, 6], [0, 6], [7, 0]], False, False, True),
    ('folded-flip-x', [[0, 0], [7, 6], [0, 6], [7, 0]], True, False, True),
    ('dented', [[0, 0], [7, 0], [2, 2], [0, 6]], False, True, False),
]
for name, raw, flip_x, flip_y, nearest in definitions:
    corners = [tuple(F(v) for v in p) for p in raw]
    left, top = min(p[0] for p in corners).__floor__(), min(p[1] for p in corners).__floor__()
    right, bottom = max(p[0] for p in corners).__ceil__(), max(p[1] for p in corners).__ceil__()
    signs = [cross(corners[i], corners[(i+1) % 4], corners[(i+2) % 4]) for i in range(4)]
    convex = all(v > 0 for v in signs) or all(v < 0 for v in signs)
    matrix = inverse_quad(corners) if convex else None
    target = [corners[[0, 1, 3, 2][(1-v if flip_y else v)*2+(1-u if flip_x else u)]] for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))]
    output = []
    for y in range(top, bottom):
        for x in range(left, right):
            p, uv = (F(x)+F(1, 2), F(y)+F(1, 2)), []
            if matrix:
                a, b, c, d, e, f, g, h = matrix
                den = g*p[0]+h*p[1]+1
                if den:
                    u, v = (a*p[0]+b*p[1]+c)/den, (d*p[0]+e*p[1]+f)/den
                    if 0 <= u <= 1 and 0 <= v <= 1:
                        uv = [(1-u if flip_x else u, 1-v if flip_y else v)]
            else:
                first = None
                for half, (a, b, c) in enumerate(((target[0], target[1], target[2]), (target[0], target[2], target[3]))):
                    det = cross(a, b, c)
                    if not det:
                        continue
                    u, v = cross(a, p, c)/det, cross(a, b, p)/det
                    if u >= 0 and v >= 0 and u+v <= 1:
                        if half == 0:
                            first = (u, v)
                            uv.append((u+v, v))
                        elif not (first and v == 0):
                            uv.append((u, u+v))
            result = [0, 0, 0, 0]
            for u, v in uv:
                rgba = sample(u, v, nearest)
                a, b = F(rgba[3], 255), F(result[3], 255)
                alpha = a+b*(1-a)
                result = [quantize((rgba[c]*a+result[c]*b*(1-a))/alpha) if alpha else 0 for c in range(3)]+[quantize(alpha*255)]
            output.extend(result)
    cases.append(dict(name=name, corners=raw, flipX=flip_x, flipY=flip_y, sampling='Nearest' if nearest else 'Smooth', origin=[left, top], width=right-left, height=bottom-top, rgba=output))
destination = Path(__file__).resolve().parent.parent / 'golden' / 'distort.json'
destination.write_text(json.dumps(dict(reference='Exact rational-coordinate independent reference; not Core Image output', width=width, height=height, rgba=sum(pixels, []), cases=cases), indent=2)+'\n')
