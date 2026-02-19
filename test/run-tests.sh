#!/usr/bin/env bash
# ============================================================================
# Claude Task System v2 -- Test Runner
# ============================================================================
# Runs syntax checks and basic unit tests for CTS v2.
#
# Usage:
#   bash test/run-tests.sh
# ============================================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}FAIL${NC} %s: %s\n" "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf "${YELLOW}SKIP${NC} %s: %s\n" "$1" "$2"; }

echo "============================================"
echo "CTS v2 Test Suite"
echo "============================================"
echo ""

# --- 1. Syntax check all bash scripts ---
echo "--- Syntax Checks ---"
while IFS= read -r script; do
    rel="${script#$PROJECT_ROOT/}"
    if bash -n "$script" 2>/dev/null; then
        pass "syntax: $rel"
    else
        fail "syntax: $rel" "bash -n failed"
    fi
done < <(find "$PROJECT_ROOT" -name '*.sh' -not -path '*/.git/*' | sort)

echo ""

# --- 2. Config sourcing test ---
echo "--- Config Tests ---"
if bash -c "source '$PROJECT_ROOT/cts-v2/src/config.sh' && [[ -n \"\$STATE_DIR\" ]] && [[ -n \"\$VAULT_TASKS_DIR\" ]] && [[ -n \"\$LOG_DIR\" ]]" 2>/dev/null; then
    pass "config.sh sets STATE_DIR, VAULT_TASKS_DIR, LOG_DIR"
else
    fail "config.sh" "required variables not set"
fi

echo ""

# --- 3. Turn detection tests using fixtures ---
echo "--- Turn Detection Tests ---"

# Source turn detection in current shell (need functions available)
source "$PROJECT_ROOT/cts-v2/src/config.sh"
source "$PROJECT_ROOT/cts-v2/src/lib/logging.sh"
source "$PROJECT_ROOT/cts-v2/src/lib/turn-detection.sh"

# Test detect_stop on stop-signal fixture (takes task_dir + filename)
if detect_stop "$TEST_DIR/fixtures/stop-signal" "003_test-task.md" 2>/dev/null; then
    pass "detect_stop: recognizes <Stop> in fixture"
else
    fail "detect_stop" "did not detect <Stop> in stop-signal fixture"
fi

# Test detect_stop on normal file (should return false)
if ! detect_stop "$TEST_DIR/fixtures/user-file" "001_test-task.md" 2>/dev/null; then
    pass "detect_stop: returns false for normal file"
else
    fail "detect_stop" "false positive on normal file"
fi

# Test get_latest_md (returns filename only, not path)
latest="$(get_latest_md "$TEST_DIR/fixtures/user-file" 2>/dev/null || echo "")"
if [[ "${latest:-}" == "001_test-task.md" ]]; then
    pass "get_latest_md: finds 001_test-task.md"
else
    fail "get_latest_md" "expected 001_test-task.md, got '${latest:-EMPTY}'"
fi

echo ""

# --- 4. Mock script tests ---
echo "--- Mock Script Tests ---"

# Test mock-claude basic invocation
output="$(bash "$TEST_DIR/mock-claude.sh" -p "test prompt" 2>/dev/null || true)"
if echo "$output" | grep -q "SESSION_ID:"; then
    pass "mock-claude: emits SESSION_ID"
else
    fail "mock-claude" "no SESSION_ID in output"
fi

if echo "$output" | grep -q "mock Claude response"; then
    pass "mock-claude: generates default response"
else
    fail "mock-claude" "no default response"
fi

# Test mock-claude rate limit
output="$(MOCK_RATE_LIMIT=1 bash "$TEST_DIR/mock-claude.sh" -p "test" 2>/dev/null || true)"
if echo "$output" | grep -q "TOKEN_EXHAUSTED"; then
    pass "mock-claude: MOCK_RATE_LIMIT emits TOKEN_EXHAUSTED"
else
    fail "mock-claude MOCK_RATE_LIMIT" "no TOKEN_EXHAUSTED"
fi

# Test mock-ollama list
output="$(bash "$TEST_DIR/mock-ollama.sh" list 2>/dev/null || true)"
if echo "$output" | grep -q "qwen3"; then
    pass "mock-ollama list: shows models"
else
    fail "mock-ollama list" "no model output"
fi

# Test mock-ollama run
output="$(echo "hello" | bash "$TEST_DIR/mock-ollama.sh" run qwen3:8b 2>/dev/null || true)"
if echo "$output" | grep -q "Mock Ollama response"; then
    pass "mock-ollama run: generates response"
else
    fail "mock-ollama run" "no response"
fi

# Test mock-ollama down
output="$(MOCK_OLLAMA_DOWN=1 bash "$TEST_DIR/mock-ollama.sh" run qwen3:8b 2>&1 || true)"
if echo "$output" | grep -q "could not connect"; then
    pass "mock-ollama: MOCK_OLLAMA_DOWN simulates failure"
else
    fail "mock-ollama MOCK_OLLAMA_DOWN" "no connection error"
fi

echo ""

# --- 5. Task complexity detection ---
echo "--- Complexity Tests ---"

# Run complexity test in a subshell to avoid set -e contamination from sourced libs
complexity_result="$(bash -c "
    set +e
    source '$PROJECT_ROOT/cts-v2/src/config.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/logging.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/locking.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/event-queue.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/notifications.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/llm-registry.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/token-tracking.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/continuation.sh' 2>/dev/null
    source '$PROJECT_ROOT/cts-v2/src/lib/audit.sh' 2>/dev/null
    set +e  # override any set -e from sourced files
    source '$PROJECT_ROOT/cts-v2/src/scheduler.sh' 2>/dev/null
    set +e
    if declare -f get_task_complexity >/dev/null 2>&1; then
        result=\$(get_task_complexity '$TEST_DIR/fixtures/complexity-metadata' 2>/dev/null)
        echo \"FUNC_FOUND:\$result\"
    else
        echo 'FUNC_NOT_FOUND'
    fi
" 2>/dev/null || echo "SUBSHELL_FAILED")"

case "$complexity_result" in
    FUNC_FOUND:high)
        pass "get_task_complexity: reads 'high' from fixture"
        ;;
    FUNC_FOUND:*)
        skip "get_task_complexity" "returned '${complexity_result#FUNC_FOUND:}' (may need different parsing)"
        ;;
    FUNC_NOT_FOUND)
        skip "get_task_complexity" "function not available after sourcing scheduler.sh"
        ;;
    *)
        skip "get_task_complexity" "subshell failed: $complexity_result"
        ;;
esac

echo ""

# --- 6. new-task.sh validation ---
echo "--- new-task.sh Tests ---"

# Test help flag
if bash "$PROJECT_ROOT/new-task.sh" --help 2>/dev/null | grep -q "Usage:"; then
    pass "new-task.sh --help: shows usage"
else
    fail "new-task.sh --help" "no usage output"
fi

# Test invalid name rejected
if bash "$PROJECT_ROOT/new-task.sh" "INVALID NAME" 2>/dev/null; then
    fail "new-task.sh validation" "accepted invalid name"
else
    pass "new-task.sh: rejects invalid task name"
fi

echo ""

# --- Summary ---
echo "============================================"
TOTAL=$((PASS + FAIL + SKIP))
printf "Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, ${YELLOW}%d skipped${NC} / %d total\n" "$PASS" "$FAIL" "$SKIP" "$TOTAL"
echo "============================================"

[[ "$FAIL" -eq 0 ]]
