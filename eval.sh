#!/usr/bin/env bash
# eval.sh — AutoSkill evaluation harness
# Usage: ./eval.sh <skill-dir> [--dry-run]
#
# Runs test cases against a skill and scores them using LLM-as-judge.
# Inspired by autoresearch: fixed eval, single metric, binary keep/discard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${1:?Usage: ./eval.sh <skill-dir> [--dry-run]}"
DRY_RUN="${2:-}"

# Look for test_cases.json and judge.md in skill dir first, then fall back to autoskill dir
if [ -f "$SKILL_DIR/test_cases.json" ]; then
  TEST_CASES="$SKILL_DIR/test_cases.json"
elif [ -f "$SCRIPT_DIR/test_cases.json" ]; then
  TEST_CASES="$SCRIPT_DIR/test_cases.json"
else
  echo "ERROR: No test_cases.json found in $SKILL_DIR or $SCRIPT_DIR"
  exit 1
fi

if [ -f "$SKILL_DIR/judge.md" ]; then
  JUDGE_PROMPT="$SKILL_DIR/judge.md"
else
  JUDGE_PROMPT="$SCRIPT_DIR/judge.md"
fi

RESULTS_FILE="$SCRIPT_DIR/eval_results.json"
SKILL_FILE="$SKILL_DIR/SKILL.md"

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: $SKILL_FILE not found"
  exit 1
fi

if [ ! -f "$TEST_CASES" ]; then
  echo "ERROR: $TEST_CASES not found"
  exit 1
fi

SKILL_CONTENT=$(cat "$SKILL_FILE")
JUDGE_CONTENT=$(cat "$JUDGE_PROMPT")
NUM_CASES=$(python3 -c "import json; print(len(json.load(open('$TEST_CASES'))))")

echo "========================================="
echo "AutoSkill Eval"
echo "========================================="
echo "Skill:      $SKILL_FILE"
echo "Test cases: $NUM_CASES"
echo "Judge:      $JUDGE_PROMPT"
echo "========================================="

# Run evaluation via Python (handles JSON parsing, API calls, scoring)
python3 "$SCRIPT_DIR/evaluate.py" \
  --skill "$SKILL_FILE" \
  --test-cases "$TEST_CASES" \
  --judge "$JUDGE_PROMPT" \
  --output "$RESULTS_FILE" \
  ${DRY_RUN:+--dry-run}

# Parse final score
if [ -f "$RESULTS_FILE" ]; then
  PASS_RATE=$(python3 -c "
import json
results = json.load(open('$RESULTS_FILE'))
total = len(results['cases'])
passed = sum(1 for c in results['cases'] if c['score'] == 'PASS')
print(f'{passed}/{total} ({100*passed/total:.1f}%)')
")
  echo ""
  echo "========================================="
  echo "PASS RATE: $PASS_RATE"
  echo "========================================="
fi
