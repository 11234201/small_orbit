#!/usr/bin/env bash
set -euo pipefail
project_dir=/home/wzh/my_code/todo_list
source "$project_dir/.toolchain/env.sh"
apk="$project_dir/dist/small_orbit-0.1.0-android.apk"
build_tools="$ANDROID_HOME/build-tools/36.0.0"
"$build_tools/apksigner" verify --verbose --print-certs "$apk" > "$project_dir/logs/apk_signature.log"
"$build_tools/aapt" dump badging "$apk" > "$project_dir/logs/apk_manifest.log"
"$build_tools/aapt" dump permissions "$apk" > "$project_dir/logs/apk_permissions.log"
"$build_tools/zipalign" -c -P 16 -v 4 "$apk" > "$project_dir/logs/apk_alignment.log"
python3 - "$project_dir" <<'PY'
import hashlib, pathlib, sys, zipfile
root=pathlib.Path(sys.argv[1])
apk=root/'dist/small_orbit-0.1.0-android.apk'
manifest=(root/'logs/apk_manifest.log').read_text()
permissions=(root/'logs/apk_permissions.log').read_text()
assert "sdkVersion:'26'" in manifest, 'Unexpected minimum Android SDK'
assert "application-debuggable" not in manifest, 'Release APK is debuggable'
assert "android.permission.INTERNET" not in permissions, 'Offline APK requests network permission'
assert "android.permission.POST_NOTIFICATIONS" in permissions
with zipfile.ZipFile(apk) as bundle:
    assert bundle.testzip() is None, 'APK CRC check failed'
    for abi in ['arm64-v8a','armeabi-v7a','x86_64']:
        assert f'lib/{abi}/libflutter.so' in bundle.namelist(), f'Missing {abi}'
print('APK verified: signature, CRC, SDK 26+, three ABIs, release mode, no INTERNET, 16 KB ZIP alignment')
print('Bytes:',apk.stat().st_size)
print('SHA256:',hashlib.sha256(apk.read_bytes()).hexdigest())
PY
