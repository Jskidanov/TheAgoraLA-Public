#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$(mktemp -t agora-regression)"
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library Sources/Models.swift Sources/MockEpisodeProvider.swift Sources/EpisodeStore.swift Tests/StorageAndTimingRegression.swift -o "$binary"
"$binary"
