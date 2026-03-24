# Findings: Auto-Reminder Skill Optimization

## The Problem

The auto-reminder skill instructs an AI agent to create cron jobs (`openclaw cron create`) whenever it makes a commitment to do something later — "I'll check back," "I'll remind you," "I'll follow up." In practice, the agent only followed through ~45% of the time.

## Experiment Setup

- **Skill:** `auto-reminder/SKILL.md` — 84 lines of prompt instructing the agent to create crons
- **Test suite:** 20 test cases across 6 categories (positive, implicit, edge, complex, negative)
- **Metric:** Pass rate (% of cases where correct behavior occurred)
- **Target:** 95%
- **Method:** Autonomous loop — modify skill prompt, evaluate, keep if improved, discard if not

## Results by Phase

### Phase 1: v1 Loop (Unstructured)

**30+ iterations, ~5 hours runtime**

| Milestone | Pass Rate | What Changed |
|-----------|-----------|--------------|
| Original baseline | 45% (9/20) | Starting skill |
| After iteration 2 | 70% (14/20) | Added "STOP AND CHECK" gate + expanded trigger phrases |
| Best achieved | 75% (15/20) | Variance — same prompt scored 70-80% across runs |
| Plateau | 75% for 22 iterations | Every modification regressed |

**What broke:** The optimizer (Sonnet) kept producing destructive rewrites — replacing the entire 99-line file with 1 line. No mutation strategy meant it had no constraint on how to modify the prompt.

### Phase 2: v2 Loop (Structured Mutations)

Applied learnings from [k.balu124's article](https://medium.com/@k.balu124/i-turned-andrej-karpathys-autoresearch-into-a-universal-skill-1cb3d44fc669) and [uditgoenka/autoresearch](https://github.com/uditgoenka/autoresearch):

- 6 named mutation operators rotated each cycle
- Minimum line count guard (rejects outputs < 20 lines)
- Plateau breaker after 5 consecutive discards
- State persistence to disk
- Eval isolation (judge doesn't see the prompt)

**Baseline improved to 80%** before v2 even started modifying — the iteration 2 skill was scoring higher with fresh evals.

*v2 loop still running as of 2026-03-24*

## What Passed vs Failed

### Always Passed (100%)
- Explicit "remind me to X" requests
- Timed requests ("in 10 minutes", "tomorrow")
- Negative cases (correctly did NOT create crons)
- Multi-commitment messages

### Inconsistently Passed (50-75%)
- Agent self-commits ("I'll check back") — depends on whether Claude decides to use commitment language
- Buried commitments (praise + request in same message)
- Conditional commitments ("if X happens, let me know")

### Frequently Failed (0-25%)
- Vague timeframes ("soon", "later") — agent often didn't create cron
- Subtle "will do" language — not recognized as commitment
- Agent-initiated monitoring ("I'll keep an eye on it")

## Key Insight

The fundamental challenge is that **implicit test cases depend on the agent's own word choice.** We can't control whether Claude says "I'll check back" (triggers cron) or "Let me look at that now" (no future commitment). The test cases with `agent_should_say` hints help, but the simulation doesn't force the agent to use those exact words.

This means the theoretical ceiling for this eval approach may be ~85-90%, not 95%. Getting to 95% would require either:
1. Restructuring the eval to force specific agent responses
2. A fundamentally different approach — e.g., a post-response hook that scans for commitments
3. Making the skill so aggressive that it creates crons even for borderline cases (risking over-triggering)

## What Actually Improved the Prompt

| Change | Impact | Why It Worked |
|--------|--------|---------------|
| "STOP AND CHECK" gate at top | +25% (45→70%) | Forces self-reflection before every reply |
| Expanded trigger phrase list | +5% | Catches more commitment patterns |
| Absolute language ("MUST" not "should") | +5% | Reduces ambiguity in instructions |
| Explicit command syntax section | Prevented syntax errors | Agent stopped using `--at` instead of `--run-at` |

## What Did NOT Help

| Change | Result | Why It Failed |
|--------|--------|---------------|
| Longer, more detailed prompts | Regression | Agent overwhelmed, missed key rules |
| Removing sections for brevity | Regression | Lost critical instructions |
| Restructuring section order | No change | Agent reads the whole prompt regardless |
| Adding more trigger phrases | Diminishing returns | The problem isn't phrase coverage, it's self-awareness |
