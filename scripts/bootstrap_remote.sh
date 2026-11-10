#!/usr/bin/env bash
set -euo pipefail
project_dir=/home/wzh/my_code/todo_list
flutter_dir=/home/wzh/open_source/flutter
mkdir -p "$project_dir/.toolchain" "$project_dir/.build_cache" "$project_dir/logs"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
export PUB_HOSTED_URL=https://pub.dev
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_CACHE="$project_dir/.toolchain/pub_cache"
export GRADLE_USER_HOME="$project_dir/.toolchain/gradle"
export ANDROID_HOME="$project_dir/.toolchain/android_sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [ ! -d "$flutter_dir/.git" ]; then
  git clone --depth 1 --branch stable --single-branch https://github.com/flutter/flutter.git "$flutter_dir"
fi
if [ ! -x "$project_dir/.toolchain/jdk/bin/java" ]; then
  python3 - "$project_dir" <<'PY'
import hashlib, json, pathlib, subprocess, sys, urllib.request
root = pathlib.Path(sys.argv[1])
url = "https://corretto.aws/downloads/latest/amazon-corretto-17-x64-linux-jdk.tar.gz"
checksum_url = "https://corretto.aws/downloads/latest_sha256/amazon-corretto-17-x64-linux-jdk.tar.gz"
checksum = urllib.request.urlopen(checksum_url, timeout=60).read().decode().strip().split()[0]
archive = root / ".build_cache" / "jdk17.tar.gz"
subprocess.run(["curl","-fL","--retry","3","-o",str(archive),url],check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
    raise SystemExit("JDK archive checksum mismatch")
target = root / ".toolchain" / "jdk"
target.mkdir(exist_ok=True)
subprocess.run(["tar","-xzf",str(archive),"--strip-components=1","-C",str(target)],check=True)
print("Installed JDK 17 with verified checksum")
PY
fi
export JAVA_HOME="$project_dir/.toolchain/jdk"
export PATH="$flutter_dir/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  python3 - "$project_dir" <<'PY'
import hashlib, pathlib, subprocess, sys, urllib.request, xml.etree.ElementTree as ET, zipfile
root=pathlib.Path(sys.argv[1])
base="https://dl.google.com/android/repository/"
tree=ET.fromstring(urllib.request.urlopen(base+"repository2-1.xml",timeout=60).read())
package=next(node for node in tree if node.attrib.get("path")=="cmdline-tools;latest")
archive=next(node for node in package.findall(".//archive") if node.findtext("host-os")=="linux")
complete=archive.find("complete")
name=complete.findtext("url")
checksum=complete.find("checksum")
download=root/".build_cache"/"android_commandline.zip"
subprocess.run(["curl","-fL","--retry","3","-o",str(download),base+name],check=True)
algorithm=checksum.attrib.get("type","sha1")
actual=hashlib.new(algorithm,download.read_bytes()).hexdigest()
if actual!=checksum.text.strip(): raise SystemExit("Android commandline checksum mismatch")
destination=root/".toolchain"/"android_sdk"/"cmdline-tools"/"latest"
destination.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(download) as bundle:
    for entry in bundle.infolist():
        relative=pathlib.PurePosixPath(entry.filename)
        if relative.parts[0]!="cmdline-tools": continue
        if ".." in relative.parts: raise SystemExit("Unsafe archive path")
        target=destination.joinpath(*relative.parts[1:])
        if entry.is_dir(): target.mkdir(parents=True,exist_ok=True)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(bundle.read(entry))
            target.chmod(0o755 if "bin" in relative.parts else 0o644)
print("Installed Android commandline tools with verified checksum")
PY
fi
cat > "$project_dir/.toolchain/env.sh" <<EOF
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
export PUB_HOSTED_URL=https://pub.dev
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_CACHE="$PUB_CACHE"
export GRADLE_USER_HOME="$GRADLE_USER_HOME"
export JAVA_HOME="$JAVA_HOME"
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$flutter_dir/bin:$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:\$PATH"
EOF
set +o pipefail
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses > "$project_dir/logs/android_licenses.log"
set -o pipefail
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-36" "build-tools;36.0.0"
flutter --version
flutter precache --android --linux
git -C "$flutter_dir" rev-parse HEAD > "$project_dir/.toolchain/flutter_commit.txt"
echo "TOOLCHAIN_READY"
