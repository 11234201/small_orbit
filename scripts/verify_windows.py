"""Check the portable release structure and CRC without launching the app."""
from pathlib import Path
import hashlib
import re
import zipfile

root = Path(__file__).resolve().parent.parent
pubspec = (root / "src/small_orbit/pubspec.yaml").read_text(encoding="utf-8")
match = re.search(r"^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+\d+\s*$", pubspec, re.M)
if match is None:
    raise SystemExit("Invalid pubspec version")
bundle_name = f"small_orbit-{match[1]}-windows-x64"
archive = root / "dist" / f"{bundle_name}.zip"
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None, "ZIP CRC check failed"
    names = {name.replace("\\", "/") for name in bundle.namelist()}
    for required in [
        "small_orbit.exe", "flutter_windows.dll", "msvcp140.dll",
        "vcruntime140.dll", "vcruntime140_1.dll", "data/app.so",
        "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin", "使用说明.md",
    ]:
        assert f"{bundle_name}/{required}" in names, f"Missing {required}"
    for name in names:
        assert not name.endswith((".jks", ".keystore", "key.properties", "tasks.json")), name
print("Windows ZIP verified: CRC, application, engine, AOT, assets, CRT and guide")
print("Bytes:", archive.stat().st_size)
print("SHA256:", hashlib.sha256(archive.read_bytes()).hexdigest())
