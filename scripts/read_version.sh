#!/usr/bin/env bash
# Source this file: pubspec.yaml is the only release version source.
orbit_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
orbit_full_version=$(sed -n 's/^version: //p' "$orbit_root/src/small_orbit/pubspec.yaml" | tr -d '\r')
if [[ ! "$orbit_full_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\+[0-9]+$ ]]; then
  printf 'Invalid pubspec version: expected name+build\n' >&2
  return 1
fi
ORBIT_VERSION=${orbit_full_version%+*}
ORBIT_BUILD=${orbit_full_version##*+}
