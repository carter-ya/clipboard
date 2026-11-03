#!/usr/bin/env python3
"""Compile the actual bounded GTK preview decoder; no UI or clipboard access."""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# Privately generated 3x2 color JPEG, with no EXIF orientation. Each test adds
# its own minimal EXIF IFD; no external image or product encoder is involved.
JPEG = base64.b64decode('/9j/4AAQSkZJRgABAQAASABIAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAgADAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A534+eCPBcfxf8SQx6Bp6xwzRxootYgFSOJFRVG3hVUAADgAYFeP/APCFeDf+gDYf+AsX/wATX0R8f/8Aksfin/r5H/ota8dr/VnwR/5IvJP+wXD/APpqB/RnCf8AyKsJ/wBe4f8ApKP/2Q==')
COLORS = bytes([255,0,0, 0,255,0, 0,0,255, 255,255,0, 0,255,255, 255,0,255])


def tiff(orientation=None):
    entries = [(256,4,1,3), (257,4,1,2), (258,3,3,0), (259,3,1,1),
               (262,3,1,2), (273,4,1,0), (277,3,1,3), (278,4,1,2), (279,4,1,18)]
    if orientation is not None:
        entries.append((274,3,1,orientation))
    entries.sort()
    after_ifd = 8 + 2 + 12 * len(entries) + 4
    entries = [(tag,kind,count,after_ifd if tag == 258 else after_ifd + 6 if tag == 273 else value)
               for tag,kind,count,value in entries]
    return (b'II*\x00' + struct.pack('<IH', 8, len(entries)) +
            b''.join(struct.pack('<HHII', *entry) for entry in entries) +
            bytes(4) + struct.pack('<HHH',8,8,8) + COLORS)


def jpeg(orientation):
    metadata = (b'Exif\x00\x00II*\x00' + struct.pack('<IH',8,1) +
                struct.pack('<HHIHHI',274,3,1,orientation,0,0))
    return JPEG[:2] + b'\xff\xe1' + struct.pack('>H',len(metadata)+2) + metadata + JPEG[2:]


def bmp(bits=24, v5=False, top_down=False):
    """Independent Windows clipboard bitmap variants, including unused alpha."""
    size, width, height = (124 if v5 else 40), 3, 2
    stride = ((width * bits + 31) // 32) * 4
    header = bytearray(struct.pack('<IiiHHIIiiII', size, width,
        -height if top_down else height, 1, bits, 3 if v5 else 0,
        stride * height, 0, 0, 0, 0) + bytes(size - 40))
    if v5:
        struct.pack_into('<IIIII', header, 40, 0xff0000, 0xff00, 0xff,
                         0xff000000, 0x73524742)
    rows = []
    for row in (range(height) if top_down else reversed(range(height))):
        pixels = b''.join(COLORS[i:i+3][::-1] +
                         (bytes([255 if v5 else 0]) if bits == 32 else b'')
                         for i in range(row * width * 3, (row + 1) * width * 3, 3))
        rows.append(pixels + bytes(stride - len(pixels)))
    data = b''.join(rows)
    return b'BM' + struct.pack('<IHHI', 14 + size + len(data), 0, 0, 14 + size) + header + data


DRIVER = r'''
var checks: [[String: Any]] = []
func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]) }
func pixels(_ image: OpaquePointer) -> [[UInt8]] {
  let width = Int(gdk_pixbuf_get_width(image)), height = Int(gdk_pixbuf_get_height(image))
  guard width * height == 6, let bytes = gdk_pixbuf_get_pixels(image) else { return [] }
  let stride = Int(gdk_pixbuf_get_rowstride(image)), channels = Int(gdk_pixbuf_get_n_channels(image))
  return (0..<height).flatMap { row in (0..<width).map { column in
    let offset = row * stride + column * channels
    return [bytes[offset],bytes[offset+1],bytes[offset+2]]
  }}
}
let maps = [[0,1,2,3,4,5], [2,1,0,5,4,3], [5,4,3,2,1,0], [3,4,5,0,1,2],
            [0,3,1,4,2,5], [3,0,4,1,5,2], [5,2,4,1,3,0], [2,5,1,4,0,3]]
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for kind in ["jpeg","tiff"] {
  let plain = root.appendingPathComponent("plain." + kind)
  guard let reference = gdk_pixbuf_new_from_file(plain.path, nil) else { fatalError("reference_decode_failed") }
  defer { g_object_unref(UnsafeMutableRawPointer(reference)) }
  let originalPixels = pixels(reference)
  precondition(originalPixels.count == 6)
  if kind == "tiff" {
    check("independent_lossless_tiff_reference_colors", originalPixels == [[255,0,0],[0,255,0],[0,0,255],[255,255,0],[0,255,255],[255,0,255]])
  } else {
    check("independent_jpeg_reference_has_six_distinct_colors", Set(originalPixels).count == 6)
  }
  for orientation in 0...8 {
    let path = orientation == 0 ? plain : root.appendingPathComponent("orientation\(orientation)." + kind)
    let input = try Data(contentsOf: path), original = Array(try Data(contentsOf: path))
    let label = kind + "_orientation_\(orientation)"
    let fields = ["decodes","geometry","pixels","peek_geometry","peek_pixels","original_bytes_unchanged"]
    guard let decoded = DesktopPreviewImage.decode(input) else {
      for field in fields { check(label + "_" + field, false) }
      continue
    }
    let expected = maps[max(1,orientation)-1].map { originalPixels[$0] }
    let width: Int32 = orientation >= 5 ? 2 : 3, height: Int32 = orientation >= 5 ? 3 : 2
    check(label + "_decodes", true)
    check(label + "_geometry", gdk_pixbuf_get_width(decoded.pixbuf) == width && gdk_pixbuf_get_height(decoded.pixbuf) == height)
    check(label + "_pixels", pixels(decoded.pixbuf) == expected)
    check(label + "_peek_geometry", gdk_pixbuf_get_width(decoded.peekPixbuf) == width && gdk_pixbuf_get_height(decoded.peekPixbuf) == height)
    check(label + "_peek_pixels", pixels(decoded.peekPixbuf) == expected)
    check(label + "_original_bytes_unchanged", Array(input) == original)
  }
}
check("empty_input_rejected", DesktopPreviewImage.decode(Data()) == nil)
check("truncated_jpeg_rejected", DesktopPreviewImage.decode(Data([255,216,255])) == nil)
check("encoded_input_limit_preserved", DesktopPreviewImage.decode(Data(repeating:0,count:16*1024*1024+1)) == nil)
for name in ["bmp24", "bmp32", "bmpV5", "bmpTopDown"] {
  let input = try Data(contentsOf: root.appendingPathComponent(name + ".bmp"))
  let fields = ["decodes", "geometry", "pixels", "peek_geometry", "peek_pixels", "original_bytes_unchanged"]
  guard let decoded = DesktopPreviewImage.decode(input) else {
    for field in fields { check(name + "_" + field, false) }
    continue
  }
  let expected: [[UInt8]] = [[255,0,0],[0,255,0],[0,0,255],[255,255,0],[0,255,255],[255,0,255]]
  check(name + "_decodes", true)
  check(name + "_geometry", gdk_pixbuf_get_width(decoded.pixbuf) == 3 && gdk_pixbuf_get_height(decoded.pixbuf) == 2)
  check(name + "_pixels", pixels(decoded.pixbuf) == expected)
  check(name + "_peek_geometry", gdk_pixbuf_get_width(decoded.peekPixbuf) == 3 && gdk_pixbuf_get_height(decoded.peekPixbuf) == 2)
  check(name + "_peek_pixels", pixels(decoded.peekPixbuf) == expected)
  check(name + "_original_bytes_unchanged", input == (try Data(contentsOf: root.appendingPathComponent(name + ".bmp"))))
}
let passed = checks.count == 137 && checks.allSatisfy { $0["passed"] as? Bool == true }
let report: [String:Any] = ["passed":passed,"checks":checks,"scope":"Actual GTK preview decode and hover raster: Windows BMP24/BMP32/BMPV5/top-down, absent/all8 JPEG/TIFF EXIF orientations, original data and encoded bounds; no UI/clipboard/ICC claim"]
let output = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
print(String(data:output,encoding:.utf8)!)
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output',type=Path)
    args = parser.parse_args()
    source = (ROOT / 'Desktop/Sources/ClipboardDesktop/DesktopImagePreview.swift').read_text(encoding='utf-8')
    decoder = source[:source.index('struct DesktopImagePreview: GtkWidgetRepresentable')]
    decoder = '\n'.join(line for line in decoder.splitlines()
                        if not line.startswith('import ') or line in ['import Foundation','import CGtk'])
    compiler = shutil.which('swiftc')
    if not compiler: raise RuntimeError('Swift compiler required')
    flags = shlex.split(subprocess.check_output(['pkg-config','--cflags','gdk-pixbuf-2.0'],text=True,timeout=15))
    libs = shlex.split(subprocess.check_output(['pkg-config','--libs','gdk-pixbuf-2.0'],text=True,timeout=15))
    header = next((Path(flag[2:]) / 'gdk-pixbuf/gdk-pixbuf.h' for flag in flags
                   if flag.startswith('-I') and (Path(flag[2:]) / 'gdk-pixbuf/gdk-pixbuf.h').is_file()),None)
    if header is None: raise RuntimeError('Actual GDK Pixbuf headers required')
    with tempfile.TemporaryDirectory(prefix='clipboard-preview-orientation-') as directory:
        folder = Path(directory)
        (folder / 'module.modulemap').write_text('module CGtk [system] { header "' + header.as_posix() + '" export * }\n',encoding='utf-8')
        (folder / 'plain.jpeg').write_bytes(JPEG)
        (folder / 'plain.tiff').write_bytes(tiff())
        for name, data in [('bmp24', bmp()), ('bmp32', bmp(bits=32)),
                           ('bmpV5', bmp(bits=32, v5=True)), ('bmpTopDown', bmp(top_down=True))]:
            (folder / (name + '.bmp')).write_bytes(data)
        for orientation in range(1,9):
            (folder / f'orientation{orientation}.jpeg').write_bytes(jpeg(orientation))
            (folder / f'orientation{orientation}.tiff').write_bytes(tiff(orientation))
        probe = folder / 'main.swift'
        probe.write_text(decoder + '\n' + DRIVER,encoding='utf-8')
        binary = folder / ('preview.exe' if os.name == 'nt' else 'preview')
        command = [compiler,'-module-cache-path',str(folder/'modules'),'-I',str(folder),str(probe),'-o',str(binary)]
        for flag in flags: command.extend(['-Xcc',flag])
        subprocess.run(command+libs,check=True,timeout=90)
        result = subprocess.run([str(binary),str(folder)],capture_output=True,text=True,encoding='utf-8',check=True,timeout=20)
        report = json.loads(result.stdout)
        if args.output:
            args.output.parent.mkdir(parents=True,exist_ok=True)
            args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        failed = [check['name'] for check in report['checks'] if check['passed'] is not True]
        print(json.dumps({'passed':report['passed'],'checks':len(report['checks']),'failed':failed}))
        if report['passed'] is not True or len(report['checks']) != 137 or failed: raise SystemExit(1)


if __name__ == '__main__': main()
