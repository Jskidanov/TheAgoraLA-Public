#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$(mktemp -t agora-natural-narration)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library Sources/AppLinks.swift Sources/NaturalNarrationService.swift Tests/NaturalNarrationRegression.swift -o "$binary"
"$binary"
