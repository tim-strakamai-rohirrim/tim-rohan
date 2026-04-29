#!/usr/bin/env bash
# Conductor workspace setup hook.
# Wires gitignored dev files (e.g. .claude) into each new workspace so
# Claude Code picks up custom skills/agents/commands.
#
# Configure in Conductor: Settings → Scripts → Setup Command:
#   bash "$CONDUCTOR_ROOT_PATH/.conductor/setup.sh"
#
# Runs from the workspace root. $CONDUCTOR_ROOT_PATH points to the
# source repo. We fall back to the known path if unset.

set -euo pipefail

SOURCE_REPO="${CONDUCTOR_ROOT_PATH:-/Users/tim/Documents/code/rohan}"
WORKSPACE="${CONDUCTOR_WORKSPACE_PATH:-$PWD}"

link() {
  local rel="$1"
  local src="$SOURCE_REPO/$rel"
  local dst="$WORKSPACE/$rel"

  if [[ ! -e "$src" ]]; then
    echo "skip $rel (missing in source)"
    return
  fi
  if [[ -L "$dst" || -e "$dst" ]]; then
    echo "skip $rel (already present)"
    return
  fi
  ln -s "$src" "$dst"
  echo "linked $rel -> $src"
}

link .claude
