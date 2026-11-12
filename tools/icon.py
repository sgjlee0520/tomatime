"""Build the app icon set from store/logo-source.jpeg (tomato art on white) on a white macOS plate.
Usage: python3 tools/icon.py"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..")
SET = os.path.join(ROOT, "Assets.xcassets", "AppIcon.appiconset")

# Cut the tomato out: flood-fill the near-white background from a corner, then make it transparent.
src = Image.open(os.path.join(ROOT, "store", "logo-source.jpeg")).convert("RGB")
marker = (1, 254, 1)  # a colour the artwork never uses
ImageDraw.floodfill(src, (0, 0), marker, thresh=60)
tomato = src.convert("RGBA")
tomato.putdata([(0, 0, 0, 0) if p[:3] == marker else p for p in tomato.getdata()])
tomato = tomato.crop(tomato.getbbox())
tomato = tomato.resize((round(tomato.width * 600 / tomato.height), 600), Image.LANCZOS)

# Standard macOS icon grid: 824 px rounded plate centred on 1024, soft drop shadow.
icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
plate = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(plate).rounded_rectangle((100, 100, 924, 924), radius=185, fill=255)
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 70))
icon.paste(shadow, (0, 12), plate.filter(ImageFilter.GaussianBlur(14)))
fill = Image.linear_gradient("L").resize((1024, 1024)).point(lambda v: 255 - v * 14 // 255)  # white -> #F1F1F1
icon.paste(Image.merge("RGBA", (fill, fill, fill, Image.new("L", (1024, 1024), 255))), (0, 0), plate)
icon.alpha_composite(tomato, ((1024 - tomato.width) // 2, (1024 - tomato.height) // 2))

for px in (16, 32, 64, 128, 256, 512, 1024):
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(SET, f"{px}.png"))
print("icon set written; tomato", tomato.size)

# iPhone / Watch: one 1024 icon each (the system rounds or circles it), white, tomato filling ~78%; plus the
# cut-out tomato the apps and Live Activity draw.
import json
def save_set(folder, name, img, contents):
    os.makedirs(folder, exist_ok=True)
    img.save(os.path.join(folder, name))
    json.dump(contents, open(os.path.join(folder, "Contents.json"), "w"), indent=2)

def square(scale):
    out = Image.new("RGB", (1024, 1024), "white")
    t = tomato.resize((round(tomato.width * scale), round(tomato.height * scale)), Image.LANCZOS)
    out.paste(t, ((1024 - t.width) // 2, (1024 - t.height) // 2), t)
    return out

info = {"author": "xcode", "version": 1}
for target, platform, scale in (("iOS", "ios", 800 / 600), ("Watch", "watchos", 720 / 600)):
    save_set(os.path.join(ROOT, target, "Assets.xcassets", "AppIcon.appiconset"), "icon.png", square(scale),
             {"images": [{"filename": "icon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}], "info": info})
    save_set(os.path.join(ROOT, target, "Assets.xcassets", "Tomato.imageset"), "tomato.png", tomato,
             {"images": [{"filename": "tomato.png", "idiom": "universal"}], "info": info})
    json.dump({"info": info}, open(os.path.join(ROOT, target, "Assets.xcassets", "Contents.json"), "w"))
print("iPhone and Watch icons written")
