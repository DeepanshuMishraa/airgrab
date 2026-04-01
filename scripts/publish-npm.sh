#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

current_value() {
  node -p "require('$ROOT_DIR/package.json').$1"
}

CURRENT_NAME="$(current_value name)"
CURRENT_VERSION="$(current_value version)"

echo "==> airgrab npm publish"
echo "Current package name: $CURRENT_NAME"
echo "Current version: $CURRENT_VERSION"
echo ""

read -r -p "Package name to publish [${CURRENT_NAME}]: " PACKAGE_NAME
PACKAGE_NAME="${PACKAGE_NAME:-$CURRENT_NAME}"

if [ -z "$PACKAGE_NAME" ]; then
  echo "error: package name cannot be empty"
  exit 1
fi

echo ""
echo "This will publish:"
echo "  name: $PACKAGE_NAME"
echo "  version: $CURRENT_VERSION"
echo "  dist-tag: latest"
echo "  access: public"
echo "  install: npx $PACKAGE_NAME / npm i -g $PACKAGE_NAME"
echo ""

read -r -p "Continue with npm publish? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *)
    echo "Cancelled."
    exit 0
    ;;
esac

if ! npm whoami >/dev/null 2>&1; then
  echo "error: you are not logged in to npm. Run: npm login"
  exit 1
fi

read -r -p "One-time password for npm 2FA (leave blank to skip): " NPM_OTP

PACKAGE_NAME="$PACKAGE_NAME" node -e '
const fs = require("fs");
const path = process.argv[1];
const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
pkg.name = process.env.PACKAGE_NAME;
fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
' "$ROOT_DIR/package.json"

./scripts/sync-version.sh
./scripts/build-npm-binary.sh

PUBLISH_ARGS=(publish --access public --tag latest)
if [ -n "${NPM_OTP:-}" ]; then
  PUBLISH_ARGS+=(--otp "$NPM_OTP")
fi

npm "${PUBLISH_ARGS[@]}"

echo ""
echo "Published successfully."
echo "  package: $PACKAGE_NAME"
echo "  version: $(current_value version)"
echo "  dist-tag: latest"
echo "  try: npx $PACKAGE_NAME --help"
echo "  or:  npm i -g $PACKAGE_NAME"
