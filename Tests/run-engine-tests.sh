#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/ModuleCache Reports
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -parse-as-library \
  -sdk "$SDK_PATH" -module-cache-path "$PROJECT_DIR/.build/ModuleCache" \
  Sources/ArchiveEngine.swift Tests/EngineIntegrationTests.swift \
  -o .build/engine-integration-tests
.build/engine-integration-tests
