#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$(mktemp -t agora-prompt-replay)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library Sources/Models.swift Tests/PromptReplayRegression.swift -o "$binary"
"$binary"
