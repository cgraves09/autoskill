# Findings: Auto-Reminder Skill Optimization

## The Problem

The auto-reminder skill instructs an AI agent to create cron jobs (`openclaw cron create`) whenever it makes a commitment to do something later — "I'll check back," "I'll remind you," "I'll follow up." In practice, the agent only followed through ~45% of the time.

## Experiment Setup

- **Skill:** `auto-reminder/SKILL.md` — 84 lines of prompt instructing the agent to create crons
- **Test suite:** 20 test cases across 6 categories (positive, implicit, edge, complex, negative)
- **Metric:** Pass rate (% of cases where correct behavior occurred)
- **Target:** 95%
- **Method:** Autonomous loop — modify skill prompt, evaluate, keep if improved, discard if not

## Final Result: 45% → 90%

```
Pass Rate
  95% ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ target
  90% ┃                                    ██ ← v3 iter 15: add_constraint
  85% ┃                                    ░░
  80% ┃                        ██──────────░░ ← v3 iter 12: plateau_break
  75% ┃        ██──────────────░░
  70% ┃    ██──░░ ← v1 iter 2: STOP AND CHECK gate
  65% ┃    ░░
  60% ┃    ░░
  55% ┃    ░░
  50% ┃    ░░
  45% ┃ ██─░░ ← original baseline
      ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Start    v1 plateau     v3 i12    v3 i15
```

**100% relative improvement. 60+ iterations. ~8 hours compute. 3 loop versions.**

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

**Bug:** Once the plateau breaker triggered, it never rotated back to surgical mutations — got stuck in an infinite plateau_break loop. Fixed in v3.

### Phase 3: v3 Loop (Final)

Fixed plateau rotation, added time tracking, max iteration cap (30), output sanitization.

**26 iterations, ~4 hours runtime:**

| Iter | Mutation | Pass Rate | Result |
|------|----------|-----------|--------|
| 1 | baseline | 75% | Starting point |
| 12 | `plateau_break` | **80%** | KEEP — radical rewrite |
| 15 | `add_constraint` | **90%** | KEEP — tightened commitment detection |
| 26 | (rate limited) | — | Loop stopped |

**Mutation effectiveness (v3):**

| Mutation | Kept/Tried | Rate |
|----------|-----------|------|
| `plateau_break` | 1/3 | 33% |
| `add_constraint` | 1/4 | 25% |
| `add_negative_example` | 0/4 | 0% |
| `tighten_language` | 0/4 | 0% |
| `restructure` | 0/4 | 0% |
| `remove_bloat` | 0/4 | 0% |
| `add_counterexample` | 0/3 | 0% |

## What Passed vs Failed (at 90%)

### Always Passed (100%)
- Explicit "remind me to X" requests
- Timed requests ("in 10 minutes", "tomorrow")
- Negative cases (correctly did NOT create crons)
- Multi-commitment messages

### Improved (now passing at 90%)
- Agent self-commits ("I'll check back")
- Buried commitments (praise + request in same message)
- Conditional commitments ("if X happens, let me know")
- Vague timeframes ("soon", "later")

### Still Occasionally Failing
- Subtle "will do" language
- Agent-initiated monitoring ("I'll keep an eye on it")

## Key Insight

The fundamental challenge is that **implicit test cases depend on the agent's own word choice.** We can't control whether Claude says "I'll check back" (triggers cron) or "Let me look at that now" (no future commitment). The theoretical ceiling for this eval approach is ~85-90%, which we effectively reached.

Getting to 95%+ would require either:
1. A post-response hook that scans for commitments (deterministic, not prompt-based)
2. Restructuring the eval to force specific agent responses
3. Making the skill so aggressive it creates crons for borderline cases (risking over-triggering)

## What Actually Moved the Needle

Only **2 out of 60+ mutations** produced lasting improvement:

| Change | Impact | Why It Worked |
|--------|--------|---------------|
| "STOP AND CHECK" gate | +25% (45→70%) | Forces self-reflection before every reply |
| Tightened commitment constraint | +10% (80→90%) | Expanded detection + absolute language ("MUST") |

## What Did NOT Help

| Change | Times Tried | Why It Failed |
|--------|------------|---------------|
| Add negative examples | 4 | Agent already knew what not to do |
| Tighten language alone | 4 | Without structural change, rewording is noise |
| Restructure sections | 4 | Agent reads the whole prompt regardless of order |
| Remove bloat | 4 | Lost critical instructions every time |
| Add counterexamples | 3 | Added length without adding clarity |
