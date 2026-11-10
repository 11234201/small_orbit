#!/usr/bin/env bash
set -euo pipefail
project_dir=/home/wzh/my_code/todo_list
source "$project_dir/.toolchain/env.sh"
export PUB_HOSTED_URL=https://pub.dev
cd "$project_dir/src/small_orbit"
mkdir -p "$project_dir/.private" "$project_dir/dist" "$project_dir/logs"
chmod 700 "$project_dir/.private"
if [ ! -f "$project_dir/.private/android_release.jks" ]; then
  python3 - "$project_dir" <<'PY'
import os, pathlib, secrets, subprocess, sys
root=pathlib.Path(sys.argv[1])
secret=secrets.token_urlsafe(32)
env=dict(os.environ,ORBIT_KEYPASS=secret)
subprocess.run(['keytool','-genkeypair','-keystore',str(root/'.private/android_release.jks'),
 '-alias','small_orbit','-keyalg','RSA','-keysize','3072','-validity','10000',
 '-dname','CN=Small Orbit Offline, OU=Personal, O=Small Orbit',
 '-storepass:env','ORBIT_KEYPASS','-keypass:env','ORBIT_KEYPASS'],env=env,check=True)
settings=f'storeFile={root}/.private/android_release.jks\nstorePassword={secret}\nkeyAlias=small_orbit\nkeyPassword={secret}\n'
target=root/'.private/key.properties'
target.write_text(settings)
target.chmod(0o600)
(root/'.private/android_release.jks').chmod(0o600)
PY
fi
cp "$project_dir/.private/key.properties" android/key.properties
chmod 600 android/key.properties
flutter build apk --release --target-platform android-arm64,android-arm,android-x64 > "$project_dir/logs/android_build.log" 2>&1
cp build/app/outputs/flutter-apk/app-release.apk "$project_dir/dist/small_orbit-0.1.0-android.apk"
sha256sum "$project_dir/dist/small_orbit-0.1.0-android.apk"
