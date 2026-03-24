#!/usr/bin/env bash
# improve.sh — Autonomous skill improvement loop (v3)
#
# v3 fixes:
# - Plateau breaker fires ONCE then resets counter to rotate mutations again
# - Plateau break prompt fixed to prevent 1-line output
# - Time tracking per iteration and cumulative
# - Max iterations safety (default 50)
# - Better logging: elapsed time, cost awareness
#
# Usage: ./improve.sh <skill-dir> [target_pct] [max_iterations]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${1:?Usage: ./improve.sh <skill-dir> [target_pct] [max_iterations]}"
TARGET="${2:-95}"
MAX_ITERS="${3:-50}"
SKILL_FILE="$SKILL_DIR/SKILL.md"
RESULTS_TSV="$SCRIPT_DIR/results.tsv"
EVAL_RESULTS="$SCRIPT_DIR/eval_results.json"
STATE_FILE="$SCRIPT_DIR/state.json"

# The 6 mutation operators — rotated each cycle
MUTATIONS=("add_constraint" "add_negative_example" "tighten_language" "restructure" "remove_bloat" "add_counterexample")

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: $SKILL_FILE not found"
  exit 1
fi

# Initialize results.tsv
if [ ! -f "$RESULTS_TSV" ]; then
  echo -e "iteration\ttimestamp\tpass_rate\tpassed\ttotal\tstatus\tmutation\tduration_s\tdescription" > "$RESULTS_TSV"
fi

# Initialize git repo in skill dir if needed
cd "$SKILL_DIR"
if [ ! -d .git ]; then
  git init
  git add -A
  git commit -m "baseline: initial skill state"
fi
cd "$SCRIPT_DIR"

# Initialize state
if [ ! -f "$STATE_FILE" ]; then
  echo '{"iteration": 0, "best_rate": 0, "consecutive_discards": 0, "plateau_breaks": 0, "mutation_index": 0, "mutations_tried": {}, "best_commit": "", "total_time_s": 0}' > "$STATE_FILE"
fi

# Read/write state helpers
read_state() {
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
print(s.get('$1', '$2'))
"
}

write_state() {
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['$1'] = $2
json.dump(s, open('$STATE_FILE', 'w'), indent=2)
"
}

START_TIME=$(date +%s)

echo "========================================="
echo "AutoSkill Improvement Loop v3"
echo "========================================="
echo "Skill:       $SKILL_FILE"
echo "Target:      ${TARGET}% pass rate"
echo "Max iters:   $MAX_ITERS"
echo "Mutations:   ${MUTATIONS[*]}"
echo "========================================="

ITERATION=$(read_state "iteration" "0")
BEST_RATE=$(read_state "best_rate" "0")
CONSEC_DISCARDS=$(read_state "consecutive_discards" "0")
MUTATION_INDEX=$(read_state "mutation_index" "0")

while true; do
  ITER_START=$(date +%s)
  ITERATION=$((ITERATION + 1))
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  write_state "iteration" "$ITERATION"

  # Safety: max iterations
  if [ "$ITERATION" -gt "$MAX_ITERS" ]; then
    echo ""
    echo "========================================="
    echo "MAX ITERATIONS ($MAX_ITERS) REACHED"
    echo "Best: ${BEST_RATE}% | Target: ${TARGET}%"
    echo "========================================="
    exit 1
  fi

  echo ""
  echo "========================================="
  echo "Iteration $ITERATION/$MAX_ITERS — $(date '+%H:%M:%S')"
  echo "========================================="

  # ── Re-read state from disk ──
  BEST_RATE=$(read_state "best_rate" "0")
  CONSEC_DISCARDS=$(read_state "consecutive_discards" "0")
  MUTATION_INDEX=$(read_state "mutation_index" "0")

  # ── Run eval ──
  echo "[1/5] Evaluating current skill..."
  bash "$SCRIPT_DIR/eval.sh" "$SKILL_DIR" 2>&1 | tail -5

  if [ ! -f "$EVAL_RESULTS" ]; then
    echo "ERROR: No eval results. Retrying..."
    continue
  fi

  # Parse results
  EVAL_DATA=$(python3 -c "
import json
r = json.load(open('$EVAL_RESULTS'))
s = r['summary']
fails = [c for c in r['cases'] if c['score'] == 'FAIL']
fail_details = []
for f in fails:
    fail_details.append(f'{f[\"test_id\"]}: {f.get(\"reason\", \"unknown\")}')
print(f'{s[\"pass_rate\"]}|{s[\"passed\"]}|{s[\"scored\"]}|' + ';;'.join(fail_details))
")
  CURRENT_RATE=$(echo "$EVAL_DATA" | cut -d'|' -f1)
  PASSED=$(echo "$EVAL_DATA" | cut -d'|' -f2)
  TOTAL=$(echo "$EVAL_DATA" | cut -d'|' -f3)
  FAILING_CASES=$(echo "$EVAL_DATA" | cut -d'|' -f4 | tr ';;' '\n')

  echo "Current: ${CURRENT_RATE}% (${PASSED}/${TOTAL}) | Best: ${BEST_RATE}% | Streak: ${CONSEC_DISCARDS} discards"

  # ── Check target ──
  TARGET_HIT=$(python3 -c "print('yes' if float($CURRENT_RATE) >= float($TARGET) else 'no')")
  if [ "$TARGET_HIT" = "yes" ]; then
    ELAPSED=$(( $(date +%s) - START_TIME ))
    echo ""
    echo "========================================="
    echo "TARGET REACHED: ${CURRENT_RATE}% >= ${TARGET}%"
    echo "Total time: $((ELAPSED / 60))m ${((ELAPSED % 60))}s"
    echo "========================================="
    echo -e "$ITERATION\t$TIMESTAMP\t$CURRENT_RATE\t$PASSED\t$TOTAL\ttarget_reached\t-\t$ELAPSED\tReached ${TARGET}% target" >> "$RESULTS_TSV"
    write_state "best_rate" "$CURRENT_RATE"
    exit 0
  fi

  # Record baseline on first iteration
  if [ "$ITERATION" -eq 1 ]; then
    BEST_RATE=$CURRENT_RATE
    write_state "best_rate" "$CURRENT_RATE"
    cd "$SKILL_DIR"
    BEST_COMMIT=$(git rev-parse --short HEAD)
    cd "$SCRIPT_DIR"
    write_state "best_commit" "\"$BEST_COMMIT\""
    echo -e "$ITERATION\t$TIMESTAMP\t$CURRENT_RATE\t$PASSED\t$TOTAL\tbaseline\t-\t0\tInitial state" >> "$RESULTS_TSV"
  fi

  # ── Pick mutation operator ──
  # Plateau break: fires after 5 consecutive discards, then RESETS counter
  # so we cycle through surgical mutations again before next plateau break
  if [ "$CONSEC_DISCARDS" -ge 5 ] && [ "$(( CONSEC_DISCARDS % 6 ))" -eq 5 ]; then
    MUTATION="plateau_break"
    echo "[2/5] PLATEAU BREAK (after $CONSEC_DISCARDS discards) — radical rewrite"
  else
    # Rotate through mutations using persistent index
    MUTATION_INDEX_MOD=$(( MUTATION_INDEX % ${#MUTATIONS[@]} ))
    MUTATION="${MUTATIONS[$MUTATION_INDEX_MOD]}"
    MUTATION_INDEX=$((MUTATION_INDEX + 1))
    write_state "mutation_index" "$MUTATION_INDEX"
    echo "[2/5] Mutation: $MUTATION (#$MUTATION_INDEX)"
  fi

  # ── Generate improvement ──

  # Read git history for learning
  cd "$SKILL_DIR"
  GIT_HISTORY=$(git log --oneline -10 2>/dev/null || echo "no history")
  cd "$SCRIPT_DIR"

  PREV_RESULTS=$(tail -15 "$RESULTS_TSV" 2>/dev/null || echo "no results yet")

  # Build mutation-specific instructions
  case "$MUTATION" in
    add_constraint)
      MUTATION_INSTRUCTION="ADD A CONSTRAINT: Find a rule that is vague or missing and add a specific, concrete constraint. Example: change 'create a reminder' to 'you MUST run the reminder command with all required flags before sending any reply that contains a commitment'."
      ;;
    add_negative_example)
      MUTATION_INSTRUCTION="ADD A NEGATIVE EXAMPLE: Add a concrete example of what WRONG behavior looks like, so the agent knows what to avoid. Example: 'BAD: Saying I will check on that without creating a cron. GOOD: Creating the cron first, then saying I will check on that.'"
      ;;
    tighten_language)
      MUTATION_INSTRUCTION="TIGHTEN LANGUAGE: Find vague or soft language and make it absolute. Change 'should' to 'MUST'. Change 'consider creating' to 'ALWAYS create'. Change 'you may want to' to 'you MUST'. Make every instruction unambiguous."
      ;;
    restructure)
      MUTATION_INSTRUCTION="RESTRUCTURE: Reorder sections so the most critical rules come first. Move the execution checklist to the very top. Keep all content but change the layout so the agent reads the most important instructions before anything else."
      ;;
    remove_bloat)
      MUTATION_INSTRUCTION="REMOVE BLOAT: Find redundant, repeated, or unnecessary text and remove it. Shorter prompts are followed more reliably. If two sections say the same thing, merge them. If an explanation is obvious, delete it. Target: remove 10-20% of the text while keeping all rules."
      ;;
    add_counterexample)
      MUTATION_INSTRUCTION="ADD A COUNTEREXAMPLE: Add a before/after example showing the exact transformation. Include the user message, the WRONG response (no cron), and the RIGHT response (cron created first). Make it specific to one of the failing test cases."
      ;;
    plateau_break)
      MUTATION_INSTRUCTION="RADICAL REWRITE: The last several attempts all failed. The current prompt structure may be a local optimum.

Write a completely NEW version of this skill prompt. You may use a fundamentally different approach:
- Decision tree format
- Numbered checklist that must be followed in order
- XML-structured gates with explicit checkpoints
- Role-play framing (e.g., 'You are a reminder system that...')
- Any other creative structure

The new prompt MUST:
- Be between 50-120 lines long
- Start with --- (YAML frontmatter)
- Contain all the same command syntax from the original
- Cover the same use cases
- Be a complete, valid SKILL.md file"
      ;;
  esac

  IMPROVE_PROMPT="You are making a SURGICAL edit to an AI skill prompt. You must use the specific mutation strategy described below.

== MUTATION STRATEGY ==
$MUTATION_INSTRUCTION

== CURRENT SKILL PROMPT ==
$(cat "$SKILL_FILE")

== FAILING TEST CASES ==
$FAILING_CASES

== RESULTS HISTORY ==
$PREV_RESULTS

== GIT HISTORY (what was tried before) ==
$GIT_HISTORY

== CRITICAL RULES ==
1. Output ONLY the complete new SKILL.md file content
2. The file MUST start with --- on the very first line (YAML frontmatter delimiter)
3. Do NOT add any text, commentary, or explanation before or after the file content
4. Do NOT wrap the output in markdown code fences or JSON
5. Apply ONLY the mutation strategy described above — do not rewrite everything
6. Keep all command syntax EXACTLY as-is — do not change flag names, command names, or required parameters
7. Preserve all working parts of the current prompt — only change what the mutation targets
8. The output must be between 40 and 150 lines long"

  echo "[3/5] Generating $MUTATION mutation..."
  NEW_SKILL=$(claude -p "$IMPROVE_PROMPT" --model sonnet --max-turns 1 --output-format text 2>/dev/null)

  if [ -z "$NEW_SKILL" ]; then
    echo "ERROR: Empty response from Claude. Skipping."
    echo -e "$ITERATION\t$TIMESTAMP\t-\t-\t-\terror\t$MUTATION\t0\tEmpty response" >> "$RESULTS_TSV"
    continue
  fi

  # Strip any markdown code fences or JSON wrapping that Sonnet might add
  NEW_SKILL=$(echo "$NEW_SKILL" | sed '/^```/d' | sed '/^{/,/^}/d')

  # Ensure it starts with frontmatter
  if ! echo "$NEW_SKILL" | head -1 | grep -q "^---"; then
    # Try to find where --- starts and trim everything before
    NEW_SKILL=$(echo "$NEW_SKILL" | sed -n '/^---/,$p')
  fi

  # Sanity check: must be at least 30 lines
  LINE_COUNT=$(echo "$NEW_SKILL" | wc -l | tr -d ' ')
  if [ "$LINE_COUNT" -lt 30 ]; then
    echo "REJECTED: Output only $LINE_COUNT lines (minimum 30). Skipping."
    echo -e "$ITERATION\t$TIMESTAMP\t-\t-\t-\trejected\t$MUTATION\t0\tToo short ($LINE_COUNT lines)" >> "$RESULTS_TSV"
    # Don't increment discard counter for malformed output — not a real attempt
    continue
  fi

  # ── Apply and evaluate ──
  echo "[4/5] Applying mutation ($LINE_COUNT lines)..."
  echo "$NEW_SKILL" > "$SKILL_FILE"

  cd "$SKILL_DIR"
  git add SKILL.md
  git commit -m "autoskill: iter $ITERATION [$MUTATION] from ${CURRENT_RATE}%" 2>/dev/null || true
  cd "$SCRIPT_DIR"

  echo "[5/5] Re-evaluating..."
  bash "$SCRIPT_DIR/eval.sh" "$SKILL_DIR" 2>&1 | tail -5

  NEW_RATE=$(python3 -c "
import json
r = json.load(open('$EVAL_RESULTS'))
print(r['summary']['pass_rate'])
")

  ITER_ELAPSED=$(( $(date +%s) - ITER_START ))
  TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

  echo "Result: ${NEW_RATE}% (was: ${CURRENT_RATE}%, best: ${BEST_RATE}%) [${ITER_ELAPSED}s]"

  # ── Keep or discard ──
  IMPROVED=$(python3 -c "print('yes' if float($NEW_RATE) > float($BEST_RATE) else 'no')")

  if [ "$IMPROVED" = "yes" ]; then
    echo "KEEP — improved! ($MUTATION worked)"
    BEST_RATE=$NEW_RATE
    write_state "best_rate" "$NEW_RATE"
    write_state "consecutive_discards" "0"
    CONSEC_DISCARDS=0

    cd "$SKILL_DIR"
    BEST_COMMIT=$(git rev-parse --short HEAD)
    cd "$SCRIPT_DIR"
    write_state "best_commit" "\"$BEST_COMMIT\""

    python3 -c "
import json
s = json.load(open('$STATE_FILE'))
mt = s.get('mutations_tried', {})
if '$MUTATION' not in mt:
    mt['$MUTATION'] = {'kept': 0, 'discarded': 0}
mt['$MUTATION']['kept'] += 1
s['mutations_tried'] = mt
json.dump(s, open('$STATE_FILE', 'w'), indent=2)
"
    echo -e "$ITERATION\t$TIMESTAMP\t$NEW_RATE\t$PASSED\t$TOTAL\tkeep\t$MUTATION\t$ITER_ELAPSED\tImproved ${CURRENT_RATE}% > ${NEW_RATE}%" >> "$RESULTS_TSV"
  else
    echo "DISCARD — no improvement ($MUTATION)"
    CONSEC_DISCARDS=$((CONSEC_DISCARDS + 1))
    write_state "consecutive_discards" "$CONSEC_DISCARDS"

    cd "$SKILL_DIR"
    git revert --no-edit HEAD 2>/dev/null || git reset --hard HEAD~1 2>/dev/null || true
    cd "$SCRIPT_DIR"

    python3 -c "
import json
s = json.load(open('$STATE_FILE'))
mt = s.get('mutations_tried', {})
if '$MUTATION' not in mt:
    mt['$MUTATION'] = {'kept': 0, 'discarded': 0}
mt['$MUTATION']['discarded'] += 1
s['mutations_tried'] = mt
json.dump(s, open('$STATE_FILE', 'w'), indent=2)
"
    echo -e "$ITERATION\t$TIMESTAMP\t$NEW_RATE\t$PASSED\t$TOTAL\tdiscard\t$MUTATION\t$ITER_ELAPSED\t${NEW_RATE}% vs best ${BEST_RATE}%" >> "$RESULTS_TSV"
  fi

  # Update total time
  write_state "total_time_s" "$TOTAL_ELAPSED"

  # Report stats
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
mt = s.get('mutations_tried', {})
if mt:
    print('  Mutation stats:')
    for name, stats in sorted(mt.items(), key=lambda x: x[1]['kept'], reverse=True):
        total = stats['kept'] + stats['discarded']
        rate = stats['kept'] / total * 100 if total > 0 else 0
        print(f'    {name}: {stats[\"kept\"]}/{total} kept ({rate:.0f}%)')
"

  echo ""
  echo "Best: ${BEST_RATE}% | Target: ${TARGET}% | Streak: ${CONSEC_DISCARDS} | Time: $((TOTAL_ELAPSED / 60))m"

  sleep 2
done
