#!/usr/bin/env bash
# Point git at the repo's hooks. Run once per clone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x Scripts/hooks/pre-commit
git config core.hooksPath Scripts/hooks
echo "Installed: git hooks now come from Scripts/hooks"
