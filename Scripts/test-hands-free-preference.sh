#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$(mktemp -t agora-hands-free-preference)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library Sources/Models.swift Tests/HandsFreePreferenceRegression.swift -o "$binary"
"$binary"
