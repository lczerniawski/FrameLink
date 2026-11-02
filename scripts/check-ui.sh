#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 SIMULATOR_UDID" >&2
    echo "List available simulators with: xcrun simctl list devices available" >&2
    exit 2
fi
exec xcodebuild -project FrameLink.xcodeproj -scheme FrameLink \
    -configuration Debug -destination "platform=iOS Simulator,id=$1" \
    -derivedDataPath build/UITests -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO test
