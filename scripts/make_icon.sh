#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
config_dir="$repo_root/Config"
master_path="$config_dir/AppIcon-1024.png"
output_path="$config_dir/AppIcon.icns"

for tool in xcrun sips iconutil mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' was not found" >&2
        exit 1
    fi
done

mkdir -p "$config_dir"
scratch_dir="$(mktemp -d "$config_dir/.AppIcon-build.XXXXXX")"
iconset_dir="$scratch_dir/AppIcon.iconset"
temporary_icns="$config_dir/.AppIcon.$$.icns"
module_cache_dir="$scratch_dir/ModuleCache"
temporary_dir="$scratch_dir/tmp"
mkdir -p "$iconset_dir" "$module_cache_dir" "$temporary_dir"

cleanup() {
    rm -rf "$scratch_dir"
    rm -f "$temporary_icns"
}
trap cleanup EXIT

CLANG_MODULE_CACHE_PATH="$module_cache_dir" \
SWIFT_MODULECACHE_PATH="$module_cache_dir" \
TMPDIR="$temporary_dir" \
xcrun swift - "$master_path" <<'SWIFT'
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("error: expected output PNG path\n", stderr)
    exit(1)
}

let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("error: could not allocate icon bitmap\n", stderr)
    exit(1)
}

bitmap.size = NSSize(width: pixels, height: pixels)
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("error: could not create icon drawing context\n", stderr)
    exit(1)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: red / 255,
        green: green / 255,
        blue: blue / 255,
        alpha: alpha
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

let tileRect = NSRect(x: 62, y: 62, width: 900, height: 900)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 202, yRadius: 202)

let shadow = NSShadow()
shadow.shadowColor = color(0, 0, 0, 0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(22, 26, 30).setFill()
tile.fill()

NSGraphicsContext.saveGraphicsState()
tile.addClip()

color(35, 40, 45).setFill()
NSRect(x: 62, y: 512, width: 450, height: 450).fill()
color(29, 35, 40).setFill()
NSRect(x: 512, y: 512, width: 450, height: 450).fill()
color(25, 30, 35).setFill()
NSRect(x: 62, y: 62, width: 450, height: 450).fill()
color(31, 37, 42).setFill()
NSRect(x: 512, y: 62, width: 450, height: 450).fill()

let dividers = NSBezierPath()
dividers.move(to: NSPoint(x: 512, y: 62))
dividers.line(to: NSPoint(x: 512, y: 962))
dividers.move(to: NSPoint(x: 62, y: 512))
dividers.line(to: NSPoint(x: 962, y: 512))
dividers.lineWidth = 3
color(103, 113, 120, 0.46).setStroke()
dividers.stroke()

let highlight = NSBezierPath()
highlight.move(to: NSPoint(x: 235, y: 944))
highlight.curve(
    to: NSPoint(x: 789, y: 944),
    controlPoint1: NSPoint(x: 360, y: 969),
    controlPoint2: NSPoint(x: 664, y: 969)
)
highlight.lineWidth = 3
color(255, 255, 255, 0.10).setStroke()
highlight.stroke()

NSGraphicsContext.restoreGraphicsState()

let rippleCenter = NSPoint(x: 723, y: 708)
let rippleColor = color(183, 201, 197)
for (radius, width, alpha) in [(142.0, 8.0, 0.22), (92.0, 9.0, 0.38), (45.0, 11.0, 0.68)] {
    let ringRect = NSRect(
        x: rippleCenter.x - radius,
        y: rippleCenter.y - radius,
        width: radius * 2,
        height: radius * 2
    )
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = width
    rippleColor.withAlphaComponent(alpha).setStroke()
    ring.stroke()
}

rippleColor.setFill()
NSBezierPath(
    ovalIn: NSRect(x: rippleCenter.x - 13, y: rippleCenter.y - 13, width: 26, height: 26)
).fill()

tile.lineWidth = 3
color(255, 255, 255, 0.13).setStroke()
tile.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("error: could not encode icon PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fputs("error: could not write icon PNG: \(error)\n", stderr)
    exit(1)
}
SWIFT

make_representation() {
    local size="$1"
    local name="$2"
    sips -z "$size" "$size" "$master_path" --out "$iconset_dir/$name" >/dev/null
}

make_representation 16 icon_16x16.png
make_representation 32 icon_16x16@2x.png
make_representation 32 icon_32x32.png
make_representation 64 icon_32x32@2x.png
make_representation 128 icon_128x128.png
make_representation 256 icon_128x128@2x.png
make_representation 256 icon_256x256.png
make_representation 512 icon_256x256@2x.png
make_representation 512 icon_512x512.png
make_representation 1024 icon_512x512@2x.png

iconutil -c icns "$iconset_dir" -o "$temporary_icns"
mv "$temporary_icns" "$output_path"

echo "Created $master_path"
echo "Created $output_path"
