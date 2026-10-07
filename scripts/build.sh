#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project CodexUsageViewer.xcodeproj -scheme CodexUsageViewer -configuration Release -derivedDataPath build build "$@"
