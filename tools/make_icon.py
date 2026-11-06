"""Generates assets/ChillMode.ico (multi-size) and assets/ChillMode.png.

Run: python3 tools/make_icon.py   (needs Pillow)
"""
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "assets"
DARK = (11, 107, 84, 255)       # outline
TOP = (61, 220, 132, 255)       # fill gradient top
BOTTOM = (15, 138, 108, 255)    # fill gradient bottom
WHITE = (255, 255, 255, 255)


def render(size: int, detailed: bool) -> Image.Image:
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    stroke = 64 if detailed else 96
    body = (232, 150, 792, 960)          # vertical battery body
    nub = (402, 64, 622, 170)
    d.rounded_rectangle(nub, radius=36, fill=DARK)
    d.rounded_rectangle(body, radius=120, fill=DARK)

    # inner gradient fill (charge level ~ 85%)
    gap = stroke + (22 if detailed else 0)
    inner = (body[0] + gap, body[1] + gap, body[2] - gap, body[3] - gap)
    level_top = inner[1] + int((inner[3] - inner[1]) * (0.12 if detailed else 0.0))
    grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(level_top, inner[3] + 1):
        t = (y - level_top) / max(1, inner[3] - level_top)
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(4))
        gd.line([(inner[0], y), (inner[2], y)], fill=c)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inner[0], level_top, inner[2], inner[3]), radius=70 if detailed else 50, fill=255)
    if detailed:
        # gap between outline and fill is transparent-looking light band
        ImageDraw.Draw(img).rounded_rectangle(
            (body[0] + stroke, body[1] + stroke, body[2] - stroke, body[3] - stroke),
            radius=80, fill=(230, 247, 239, 255))
    img.paste(grad, (0, 0), mask)

    # white pointed leaf (intersection of two circles), tilted, with a vein
    cx, cy = 512, 590
    scale = 1.0 if detailed else 1.15
    R, off = int(258 * scale), int(163 * scale)
    a = Image.new("L", (S, S), 0)
    ImageDraw.Draw(a).ellipse((cx - off - R, cy - R, cx - off + R, cy + R), fill=255)
    b = Image.new("L", (S, S), 0)
    ImageDraw.Draw(b).ellipse((cx + off - R, cy - R, cx + off + R, cy + R), fill=255)
    leaf_mask = ImageChops.multiply(a, b)
    if detailed:
        vein = Image.new("L", (S, S), 0)
        ImageDraw.Draw(vein).line([(cx, cy - 170), (cx, cy + 215)], fill=255, width=22)
        leaf_mask = ImageChops.subtract(leaf_mask, vein)
    leaf_mask = leaf_mask.rotate(-38, center=(cx, cy), resample=Image.BICUBIC)
    white = Image.new("RGBA", (S, S), WHITE)
    img.paste(white, (0, 0), leaf_mask)

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [render(s, detailed=s >= 32) for s in sizes]
    frames[-1].save(OUT / "ChillMode.ico", format="ICO",
                    sizes=[(s, s) for s in sizes], append_images=frames[:-1])
    render(512, True).save(OUT / "ChillMode.png")
    print("wrote", OUT / "ChillMode.ico", OUT / "ChillMode.png")


if __name__ == "__main__":
    main()
