#!/usr/bin/env python3
"""应用图标生成器。

矢量源是 `scripts/appicon.svg`（设计稿），产物是
`ClaudeIsland/Assets.xcassets/AppIcon.appiconset/` 里的十个 PNG 槽位。形状改动只改
源文件，然后重跑本脚本，不要在 PNG 上手工修图。

每一档都是**按矢量原生光栅化**，不是从大图缩下来的：把源 SVG 的根 `width`/`height`
改成目标像素后再交给 `sips`（macOS 自带的 ImageIO，能直接读 SVG）。同时用 `qlmanage`
不行——它在小尺寸下会回退成通用文件图标（16/32 出来的是灰块），缩图则会糊掉 0.5px
的描边。

平台：需要 macOS 自带的 `sips`，其余只用标准库。

用法：python3 scripts/make-appicon.py [输出目录]
      默认写入 appiconset；给目录时按同样文件名写到别处，便于对照。
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts/appicon.svg"
DEFAULT_OUT = ROOT / "ClaudeIsland/Assets.xcassets/AppIcon.appiconset"

# 像素尺寸与文件名一一对应 Contents.json 里已登记的十个槽位。两个 2x 槽位
# （16x16 的 2x、32x32 的 2x）与相邻的 1x 同尺寸，因此内容相同、文件名不同。
SLOTS = [
    (16, "icon_16x16.png"),
    (32, "icon_32x32 1.png"),
    (32, "icon_32x32.png"),
    (64, "icon_64x64.png"),
    (128, "icon_128x128.png"),
    (256, "icon_256x256 1.png"),
    (256, "icon_256x256.png"),
    (512, "icon_512x512 1.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_1024x1024.png"),
]

SIZE_ATTR = re.compile(r'width="\d+"\s+height="\d+"')


def png_size(path):
    """从 PNG 头里直接读宽高，避免为了校验收敛一个图像库依赖。"""
    with path.open("rb") as f:
        header = f.read(24)
    assert header[:8] == b"\x89PNG\r\n\x1a\n", f"{path} 不是 PNG"
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def render(source_text, size, dest):
    """按目标尺寸光栅化源 SVG。sips 认 SVG 根元素的宽高，因此先把它们改成 size。"""
    scaled, count = SIZE_ATTR.subn(f'width="{size}" height="{size}"', source_text, count=1)
    if count != 1:
        raise SystemExit("源 SVG 缺少 `width=\"…\" height=\"…\"`，无法按目标尺寸渲染")
    with tempfile.TemporaryDirectory() as tmp:
        staged = pathlib.Path(tmp) / "appicon.svg"
        staged.write_text(scaled, encoding="utf-8")
        subprocess.run(
            ["sips", "-s", "format", "png", str(staged), "--out", str(dest)],
            check=True,
            capture_output=True,
        )
    actual = png_size(dest)
    if actual != (size, size):
        raise SystemExit(f"{dest.name} 渲染成了 {actual}，期望 {(size, size)}")


def main():
    out_dir = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUT
    if not SOURCE.exists():
        raise SystemExit(f"缺少矢量源 {SOURCE}")
    out_dir.mkdir(parents=True, exist_ok=True)
    source_text = SOURCE.read_text(encoding="utf-8")

    written = {}
    for size, name in SLOTS:
        dest = out_dir / name
        render(source_text, size, dest)
        written.setdefault(size, []).append(name)

    for size in sorted(written):
        print(f"{size}x{size}: {', '.join(written[size])}")
    print(f"{len(SLOTS)} 个槽位 -> {out_dir}")


if __name__ == "__main__":
    main()