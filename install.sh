#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/opensophy-projects/opensophy-cli.git"
INSTALL_DIR="${HOME}/.opensophy"
BIN_TARGET="/usr/local/bin/os"

if command -v git >/dev/null 2>&1; then
  if [ -d "${INSTALL_DIR}/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only
  else
    git clone "$REPO_URL" "$INSTALL_DIR"
  fi
else
  echo "git is required for install.sh" >&2
  exit 1
fi

chmod +x "$INSTALL_DIR/bin/os"
if [ -L "$BIN_TARGET" ] || [ -f "$BIN_TARGET" ]; then
  rm -f "$BIN_TARGET"
fi
ln -s "$INSTALL_DIR/bin/os" "$BIN_TARGET"

echo "Installed: os"
echo "Run: os help"
