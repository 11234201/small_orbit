#!/usr/bin/env bash
set -euo pipefail
project_dir=/home/wzh/my_code/todo_list
source "$project_dir/.toolchain/env.sh"
source "$project_dir/scripts/read_version.sh"
build_tools="$ANDROID_HOME/build-tools/36.0.0"
log_dir="$project_dir/logs/$ORBIT_VERSION"
mkdir -p "$log_dir"
for variant in android android-arm64; do
apk="$project_dir/dist/small_orbit-$ORBIT_VERSION-$variant.apk"
prefix="$log_dir/$variant"
"$build_tools/apksigner" verify --verbose --print-certs "$apk" > "$prefix-signature.log"
"$build_tools/aapt" dump badging "$apk" > "$prefix-manifest.log"
"$build_tools/aapt" dump permissions "$apk" > "$prefix-permissions.log"
"$build_tools/zipalign" -c -P 16 -v 4 "$apk" > "$prefix-alignment.log"
python3 - "$prefix" "$apk" "$ORBIT_VERSION" "$ORBIT_BUILD" "$variant" <<'PY'
import hashlib, pathlib, sys, zipfile
prefix=sys.argv[1]
apk=pathlib.Path(sys.argv[2])
manifest=pathlib.Path(prefix+'-manifest.log').read_text()
permissions=pathlib.Path(prefix+'-permissions.log').read_text()
assert f"versionName='{sys.argv[3]}'" in manifest, 'Unexpected Android version name'
assert f"versionCode='{sys.argv[4]}'" in manifest, 'Unexpected Android version code'
assert "sdkVersion:'26'" in manifest, 'Unexpected minimum Android SDK'
assert "application-debuggable" not in manifest, 'Release APK is debuggable'
assert "android.permission.INTERNET" not in permissions, 'Offline APK requests network permission'
assert "android.permission.POST_NOTIFICATIONS" in permissions
with zipfile.ZipFile(apk) as bundle:
    assert bundle.testzip() is None, 'APK CRC check failed'
    expected={'arm64-v8a'} if sys.argv[5]=='android-arm64' else {'arm64-v8a','armeabi-v7a','x86_64'}
    actual={name.split('/')[1] for name in bundle.namelist() if name.startswith('lib/') and name.endswith('/libflutter.so')}
    assert actual==expected, f'Unexpected ABIs: {actual}'
print(apk.name, 'verified: signature, CRC, SDK, version, ABIs, release mode, no INTERNET, ZIP alignment')
print('Bytes:',apk.stat().st_size)
print('SHA256:',hashlib.sha256(apk.read_bytes()).hexdigest())
PY
done
grep 'Signer #1 certificate SHA-256 digest:' "$log_dir/android-signature.log" > "$log_dir/signature-universal.txt"
grep 'Signer #1 certificate SHA-256 digest:' "$log_dir/android-arm64-signature.log" > "$log_dir/signature-arm64.txt"
cmp "$log_dir/signature-universal.txt" "$log_dir/signature-arm64.txt"
old_apk="$project_dir/dist/small_orbit-0.1.0-android.apk"
if [ -f "$old_apk" ]; then
  "$build_tools/apksigner" verify --print-certs "$old_apk" | grep 'Signer #1 certificate SHA-256 digest:' > "$log_dir/signature-baseline.txt"
  cmp "$log_dir/signature-universal.txt" "$log_dir/signature-baseline.txt"
  printf 'Signing identity matches the 0.1.0 baseline.\n'
fi
