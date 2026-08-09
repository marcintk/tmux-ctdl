#!/usr/bin/env bash
# One-time contributor setup: point git at the repo's own hooks (pre-commit:
# shfmt + shellcheck + tests; pre-push: 100% coverage gate).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git -C "$REPO_DIR" config core.hooksPath .githooks
echo "dev-setup: git hooks enabled (.githooks)"
