#!/bin/sh
# Install pingr to ~/.local/bin. No dependencies beyond Python 3 (macOS stock).
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/pingr"
DST="${HOME}/.local/bin/pingr"
mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
chmod +x "$DST"
"$DST" --selftest
echo "installed to $DST"
case ":$PATH:" in
  *":${HOME}/.local/bin:"*) ;;
  *) echo "NOTE: ~/.local/bin is not on PATH; add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
