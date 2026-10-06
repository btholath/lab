#!/usr/bin/env bash
# Enable the repo's git hooks. Run once inside the repository (e.g. ~/repos/lab):
#   bash multipass/scripts/install-hooks.sh
set -e
TOP=$(git rev-parse --show-toplevel)
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-hooks"
REL=${HOOKS_DIR#"$TOP"/}
chmod +x "$HOOKS_DIR"/*
git -C "$TOP" config core.hooksPath "$REL"
echo "Hooks enabled for $TOP"
echo "core.hooksPath = $REL"
echo "Test it:  git commit with a fake key should now be blocked."
