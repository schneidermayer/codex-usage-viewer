#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/build/visuals}"
mkdir -p "$PROJECT_ROOT/build/tools" "$OUTPUT_DIR"

xcrun swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macos27.0" \
  "$PROJECT_ROOT/Shared/UsageModels.swift" \
  "$PROJECT_ROOT/Shared/WeeklyUsage.swift" \
  "$PROJECT_ROOT/Shared/CodexUsageViewerStyle.swift" \
  "$PROJECT_ROOT/CodexUsageViewerWidget/CodexUsageViewerWidgetContent.swift" \
  "$PROJECT_ROOT/scripts/render_widgets.swift" \
  -o "$PROJECT_ROOT/build/tools/render_widgets"

"$PROJECT_ROOT/build/tools/render_widgets" "$OUTPUT_DIR"
