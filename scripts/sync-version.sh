#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(node -p "require('$ROOT_DIR/package.json').version")"

cat > "$ROOT_DIR/Sources/BuildInfo.swift" <<EOF
enum BuildInfo {
    static let version = "$VERSION"
}
EOF

echo "Synced Sources/BuildInfo.swift to version $VERSION"
