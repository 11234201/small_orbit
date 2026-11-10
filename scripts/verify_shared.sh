#!/usr/bin/env bash
set -euo pipefail
project_dir=/home/wzh/my_code/todo_list
source "$project_dir/.toolchain/env.sh"
source "$project_dir/scripts/read_version.sh"
export PUB_HOSTED_URL=https://pub.dev
log_dir="$project_dir/logs/$ORBIT_VERSION"
mkdir -p "$log_dir"
cd "$project_dir/src/small_orbit"
flutter analyze > "$log_dir/analyze.log" 2>&1
flutter test --timeout 120s --reporter expanded > "$log_dir/flutter_tests.log" 2>&1
cd android
./gradlew :app:testDebugUnitTest > "$log_dir/android_tests.log" 2>&1
printf 'Shared verification passed. Logs: %s\n' "$log_dir"
