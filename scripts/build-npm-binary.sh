#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"
./scripts/sync-version.sh

swift build -c release --arch arm64
swift build -c release --arch x86_64

lipo -create \
  .build/arm64-apple-macosx/release/airgrab \
  .build/x86_64-apple-macosx/release/airgrab \
  -output bin/airgrab-bin

chmod +x bin/airgrab-bin

SIZE=$(ls -lh bin/airgrab-bin | awk '{print $5}')
echo "Built bin/airgrab-bin ($SIZE)"
