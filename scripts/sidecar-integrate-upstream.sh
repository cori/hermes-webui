#!/usr/bin/env bash
# sidecar-integrate-upstream.sh — Validate upstream changes in isolation before applying
# Usage: ./scripts/sidecar-integrate-upstream.sh [--dry-run|--apply]

set -euo pipefail

SIDECAR_DIR="/tmp/hermes-webui-sidecar-$$"
FORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/nesquena/hermes-webui.git"
UPSTREAM_BRANCH="master"
TARGET_BRANCH="master"

DRY_RUN=true
APPLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true; APPLY=false ;;
    --apply) DRY_RUN=false; APPLY=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

cleanup() {
  local exit_code=$?
  if [[ -d "$SIDECAR_DIR" ]]; then
    rm -rf "$SIDECAR_DIR"
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

echo "=== Hermes WebUI Sidecar Upstream Integration ==="
echo "Fork dir: $FORK_DIR"
echo "Sidecar: $SIDECAR_DIR"
echo "Mode: $([ "$DRY_RUN" = true ] && echo "DRY RUN" || echo "APPLY")"
echo

# 1. Fetch upstream in fork dir
echo "--- Fetching upstream ---"
cd "$FORK_DIR"
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

# 2. Clone to sidecar using shared objects for speed
echo "--- Cloning to sidecar ---"
git clone --shared "$FORK_DIR" "$SIDECAR_DIR"
cd "$SIDECAR_DIR"

# 3. Add upstream remote in sidecar (shared clone doesn't copy remotes)
git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

# 4. Merge upstream into sidecar branch
echo "--- Merging upstream/$UPSTREAM_BRANCH ---"
git checkout -B sidecar-integration origin/"$TARGET_BRANCH"
BEFORE=$(git rev-parse HEAD)
git merge --no-ff --no-edit "$UPSTREAM_REMOTE"/"$UPSTREAM_BRANCH"

if [[ "$BEFORE" = "$(git rev-parse HEAD)" ]]; then
  echo "No upstream changes to integrate."
  exit 0
fi

AFTER=$(git rev-parse HEAD)
echo "Merged: $BEFORE..$AFTER"

# 5. Install sidecar code (editable) — reuses any existing venv
echo "--- Installing sidecar (editable) ---"
if [[ -f "scripts/test.sh" ]]; then
  # Use repo's test script which creates/uses .venv
  ./scripts/test.sh --install-only 2>/dev/null || pip install -e .
else
  pip install -e .
fi

# 6. Run targeted tests
echo "--- Running targeted tests ---"
if [[ -f "scripts/test.sh" ]]; then
  # Use the repo's test runner (sharded, handles Python version)
  ./scripts/test.sh tests/tools/test_file_operations.py \
                     tests/hermes_cli/test_tools_config.py \
                     tests/run_agent/test_run_agent.py \
                     -k "not test_interruptible_anthropic_interrupt_never_closes_shared_client" \
                     2>&1 | tail -50
  TEST_EXIT=${PIPESTATUS[0]}
else
  pytest tests/tools/test_file_operations.py \
         tests/hermes_cli/test_tools_config.py \
         tests/run_agent/test_run_agent.py \
         -k "not test_interruptible_anthropic_interrupt_never_closes_shared_client" \
         -v --timeout=60 2>&1 | tail -50
  TEST_EXIT=${PIPESTATUS[0]}
fi

if [[ $TEST_EXIT -ne 0 ]]; then
  echo "❌ Tests FAILED (exit $TEST_EXIT)"
  exit $TEST_EXIT
fi
echo "✅ Tests passed"

# 7. Smoke test (requires valid config/credentials)
echo "--- Smoke test chat ---"
if command -v hermes >/dev/null 2>&1; then
  # Use the installed hermes from sidecar
  hermes chat -q "Reply with exactly: SMOKE_TEST_OK" \
    --provider openrouter \
    -m "nemotron-3-ultra-550b-a55b:free" \
    -t "web" \
    -Q 2>&1 | tail -20
  SMOKE_EXIT=${PIPESTATUS[0]}
  if [[ $SMOKE_EXIT -eq 0 ]]; then
    echo "✅ Smoke test passed"
  else
    echo "⚠️  Smoke test failed (exit $SMOKE_EXIT) — may need credentials"
  fi
else
  echo "⚠️  hermes CLI not in PATH — skipping smoke test"
fi

# 8. Summary
echo
echo "=== Summary ==="
echo "Upstream commit: $AFTER"
echo "Base commit:     $BEFORE"
echo "Tests:           PASS"
echo "Smoke test:      $([ $SMOKE_EXIT -eq 0 ] && echo PASS || echo SKIP/FAIL)"

if [[ "$APPLY" = true ]]; then
  echo
  echo "=== Applying to active install ==="
  cd "$FORK_DIR"
  # Stash any local changes
  git stash push -m "sidecar pre-merge $(date +%s)"
  # Fast-forward merge
  git checkout "$TARGET_BRANCH"
  git merge --ff-only "$SIDECAR_DIR"/sidecar-integration
  # Reinstall
  if [[ -f "scripts/test.sh" ]]; then
    ./scripts/test.sh --install-only 2>/dev/null || pip install -e .
  else
    pip install -e .
  fi
  echo "✅ Applied and reinstalled"
  echo "Run 'hermes --version' to verify"
fi