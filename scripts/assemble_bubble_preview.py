"""Assemble real Flutter frames; rendering stays in the remote workspace."""
from pathlib import Path
import sys
from PIL import Image, ImageDraw

frames_dir, output_dir = map(Path, sys.argv[1:3])
output_dir.mkdir(parents=True, exist_ok=True)
paths = sorted(frames_dir.glob("frame_*.png"))
assert len(paths) == 120, f"Expected six seconds / 120 frames, got {len(paths)}"
frames = [Image.open(path).convert("RGB") for path in paths]
frames[0].save(output_dir / "bubbles_motion.gif", save_all=True,
               append_images=frames[1:], duration=50, loop=0, optimize=True)
sheet = Image.new("RGB", (390 * 4, 844 + 28), "#faf9f6")
draw = ImageDraw.Draw(sheet)
for column, index in enumerate((0, 30, 60, 90)):
    sheet.paste(frames[index], (390 * column, 28))
    draw.text((390 * column + 12, 6), f"t = {index * .05:.1f} s", fill="#4b3c5b")
sheet.save(output_dir / "motion_contact_sheet.png")
print("Assembled", len(frames), "actual Flutter frames")
