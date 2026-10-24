#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
BUILD=$(mktemp -d /tmp/surgeguard-build.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
printf 'let buildVersion = "%s"\n' "$(tr -d '[:space:]' < VERSION)" > "$BUILD/BuildVersion.swift"
xcrun clang -Wall -Wextra -Werror -c native.c -o "$BUILD/native.o"
xcrun swiftc -parse-as-library -O -warnings-as-errors "$BUILD/BuildVersion.swift" GuardSettings.swift SurgeGuard.swift "$BUILD/native.o" -o "$BUILD/surge-guard"
"$BUILD/surge-guard" self-test
install -m 755 "$BUILD/surge-guard" ./surge-guard
echo '已编译并通过自检。'
