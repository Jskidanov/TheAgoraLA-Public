#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$(mktemp -t agora-ai-consent)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library Sources/Models.swift Tests/AIProcessingConsentRegression.swift -o "$binary"
"$binary"
