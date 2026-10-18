"""Make small PSD/PSB import fixtures independently of the Swift reader."""
import json
import struct
import sys
import zlib
from pathlib import Path


def u16(value):
    return struct.pack('>H', value)


def u32(value):
    return struct.pack('>I', value)


def sized(value, large=False):
    return struct.pack('>Q' if large else '>I', value)


def tag(key, data, large=False):
    return b'8BIM' + key + sized(len(data), large and key in (b'Lr16', b'Layr')) + data + bytes((-len(data)) % 4)


def channel(samples, width, height, depth, compression, large):
    rows = []
    for y in range(height):
        values = samples[y * width:(y + 1) * width]
        if compression == 3:
            limit = (1 << depth) - 1
            values = [values[0]] + [(values[i] - values[i - 1]) & limit for i in range(1, width)]
        row = bytes(values) if depth == 8 else struct.pack('>' + 'H' * width, *values)
        rows.append(row)
    raw = b''.join(rows)
    if compression == 1:
        # A literal-only PackBits row gives a separate implementation of the fixture format.
        packed = [bytes([len(row) - 1]) + row for row in rows]
        raw = b''.join(sized(len(row), False) if large else u16(len(row)) for row in packed) + b''.join(packed)
    elif compression in (2, 3):
        raw = zlib.compress(raw)
    return u16(compression) + raw


def make(depth, compression, large, global_table):
    width, height = 3, 2
    maximum = (1 << depth) - 1
    samples = [0, maximum // 4, maximum // 2, maximum, maximum * 3 // 4, 257 if depth == 16 else 1]
    planes = {0: samples, 1: samples[::-1], 2: [maximum] * 6,
              -1: [maximum, maximum // 2, 0, maximum // 4, maximum, maximum],
              -2: [0, maximum // 2, maximum, maximum, maximum // 4, maximum]}
    channels = {key: channel(value, width, height, depth, compression, large) for key, value in planes.items()}
    mask = struct.pack('>4i', 0, 0, height, width) + bytes([255, 0, 0, 0])
    name = b'Fixture'
    pascal = bytes([len(name)]) + name
    pascal += bytes((-len(pascal)) % 4)
    extra = u32(len(mask)) + mask + u32(0) + pascal
    record = struct.pack('>4iH', 0, 0, height, width, len(channels))
    record += b''.join(struct.pack('>h', key) + sized(len(value), large) for key, value in channels.items())
    record += b'8BIMnorm' + bytes([191, 0, 0, 0]) + u32(len(extra)) + extra
    table = struct.pack('>h', 1) + record + b''.join(channels.values())
    table += bytes(len(table) % 2)
    if global_table:
        section = sized(0, large) + u32(0) + tag(b'Test', b'x', large)
        section += tag(b'Lr16' if depth == 16 else b'Layr', table, large)
    else:
        section = sized(len(table), large) + table + u32(0)
    header = b'8BPS' + u16(2 if large else 1) + bytes(6) + u16(3)
    header += u32(height) + u32(width) + u16(depth) + u16(3)
    # Include a raw merged RGB image for the layerless import path and independent readers.
    merged = b''.join(channel(planes[key], width, height, depth, 0, large)[2:] for key in (0, 1, 2))
    return header + u32(0) + u32(0) + sized(len(section), large) + section + u16(0) + merged, planes


def main():
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    manifest = []
    for depth in (8, 16):
        for compression in range(4):
            for large in (False, True):
                for global_table in (False, True):
                    data, planes = make(depth, compression, large, global_table)
                    name = f'rgb-{depth}-{compression}-{"global" if global_table else "main"}.{"psb" if large else "psd"}'
                    (root / name).write_bytes(data)
                    (root / f'channel-{depth}-{compression}.{"psb" if large else "psd"}.bin').write_bytes(
                        channel(planes[0], 3, 2, depth, compression, large)[2:])
                    converted = {str(key): [int((v + 128) // 257) if depth == 16 else v for v in value] for key, value in planes.items()}
                    manifest.append({'name': name, 'depth': depth, 'planes': converted})
    # Layerless high-depth documents must also ask before converting their merged image.
    data, _ = make(16, 0, False, False)
    section_size = struct.unpack_from('>I', data, 34)[0]
    (root / 'layerless16.psd').write_bytes(data[:34] + u32(0) + data[38 + section_size:])
    (root / 'excess-zip.bin').write_bytes(zlib.compress(bytes(7)))
    (root / 'expected.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Created {len(manifest)} channel/table fixtures and one layerless fixture')


if __name__ == '__main__':
    main()
