#!/bin/sh
# Build Artifacts/Tailcat.xcframework from the Go sources in go/.
#
# gomobile compiles the tailcatmobile package (which wraps the shared bridge
# package) into a per-platform framework and generates the Swift bindings.
# The checked-in xcframework is the normal build input; rerun this only when
# the Go sources or the tailcat dependency change — a dependency-maintenance
# operation, like HerdrSSH's build-native.sh, not part of app or CI builds.
#
# Requires: go, and gomobile+gobind on PATH (go install
# golang.org/x/mobile/cmd/gomobile@latest && gomobile init). Run from anywhere;
# it cds to its own package.

set -eu

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GO_DIR="$PKG_DIR/go"
OUT="$PKG_DIR/Artifacts/Tailcat.xcframework"

GOPATH_BIN="$(go env GOPATH)/bin"
case ":$PATH:" in
  *":$GOPATH_BIN:"*) ;;
  *) PATH="$PATH:$GOPATH_BIN" ;;
esac

command -v gomobile >/dev/null 2>&1 || {
  echo "gomobile not found. Install it with:" >&2
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init" >&2
  exit 1
}

# -trimpath drops local build paths; -ldflags=-s -w strips the symbol and
# debug tables, which dominates the size of a Go static framework.
cd "$GO_DIR"
rm -rf "$OUT"
CGO_ENABLED=1 gomobile bind \
  -target=ios,iossimulator,macos \
  -trimpath \
  -ldflags="-s -w" \
  -o "$OUT" \
  ./tailcatmobile

echo "built $OUT"
find "$OUT" -maxdepth 1 -mindepth 1 -type d
