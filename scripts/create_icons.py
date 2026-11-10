"""Render the app's code-defined geometric bubble icon (no downloaded assets)."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1] / "src" / "small_orbit"
image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((20, 20, 1004, 1004), radius=230, fill="#FCFAF7")
draw.ellipse((150, 170, 716, 736), fill="#D8C8F0", outline="#FFFFFF", width=12)
draw.ellipse((545, 510, 900, 865), fill="#F8CFB3", outline="#FFFFFF", width=12)
draw.ellipse((225, 245, 340, 360), fill="#EEE6F8")
draw.line([(290, 477), (380, 565), (565, 360)], fill="#7C6298", width=46, joint="curve")
for suffix, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    target = root / "android/app/src/main/res" / f"mipmap-{suffix}" / "ic_launcher.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), getattr(Image, 'Resampling', Image).LANCZOS).save(target)
image.save(root / "windows/runner/resources/app_icon.ico", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
