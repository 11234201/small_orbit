#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The maintained SSH workspace can reuse its toolchain; a clean CI checkout
# uses Flutter/JDK/Android SDK from PATH instead.
toolchain_env=${ORBIT_TOOLCHAIN_ENV:-"$project_dir/.toolchain/env.sh"}
if [[ -f "$toolchain_env" ]]; then source "$toolchain_env"; fi
source "$project_dir/scripts/read_version.sh"
# Match the source recorded in pubspec.lock even if a machine's toolchain
# defaults to a mirror; --enforce-lockfile must not silently rewrite sources.
export PUB_HOSTED_URL=https://pub.dev
log_dir=${ORBIT_LOG_DIR:-"$project_dir/logs/$ORBIT_VERSION"}
mkdir -p "$log_dir"
log_dir=$(cd "$log_dir" && pwd)
trap 'printf "Verification failed. Logs: %s\n" "$log_dir" >&2' ERR
cd "$project_dir/src/small_orbit"
flutter pub get --enforce-lockfile > "$log_dir/pub_get.log" 2>&1
flutter analyze --no-pub > "$log_dir/analyze.log" 2>&1
flutter test --no-pub --timeout 120s --reporter expanded > "$log_dir/flutter_tests.log" 2>&1
# gradlew, its JAR and local.properties are generated/ignored by the Flutter
# template. Prepare them explicitly so this also works from a clean checkout.
flutter build apk --debug --config-only --no-pub > "$log_dir/android_config.log" 2>&1
cd android
bash ./gradlew --no-daemon --max-workers=2 \
  "-Dorg.gradle.jvmargs=${ORBIT_GRADLE_JVM_ARGS:--Xmx3G -XX:MaxMetaspaceSize=1G -XX:ActiveProcessorCount=4}" \
  :app:testDebugUnitTest > "$log_dir/android_tests.log" 2>&1
printf 'Shared verification passed. Logs: %s\n' "$log_dir"
