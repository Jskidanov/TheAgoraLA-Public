#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="${AGORA_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
xcodebuild -project TheAgoraLAPod.xcodeproj -scheme TheAgoraLA \
  -configuration Debug -destination "$destination" CODE_SIGNING_ALLOWED=NO test
