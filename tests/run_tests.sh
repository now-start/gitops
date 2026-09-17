#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
BATS_DIR="$REPO_ROOT/tests/bats"

PASS=0
FAIL=0

# ── actionlint ───────────────────────────────────────────────────────────────
echo "━━━━ actionlint: workflow YAML validation ━━━━"
if actionlint "$WORKFLOWS_DIR"/*.yaml "$REPO_ROOT"/examples/*.yaml 2>&1; then
  echo "✅ actionlint passed"
  PASS=$((PASS + 1))
else
  echo "❌ actionlint failed"
  FAIL=$((FAIL + 1))
fi

echo ""

# ── bats ─────────────────────────────────────────────────────────────────────
echo "━━━━ bats: shell logic unit tests ━━━━"
for TEST_FILE in "$BATS_DIR"/*.bats; do
  if bats "$TEST_FILE"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

# ── 결과 ─────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test suites passed: $PASS  Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$FAIL" -eq 0 ]
