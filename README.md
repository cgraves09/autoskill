# AutoSkill

Autonomous skill prompt optimization, inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

A skill is a prompt. Prompts can be optimized the same way hyperparameters can — by running experiments, measuring outcomes, and keeping what works.

**First result:** Took an auto-reminder skill from **45% → 90% reliability** (100% relative improvement) across 60+ autonomous iterations. See [FINDINGS.md](FINDINGS.md) for the full breakdown.

## How It Works

The same loop as autoresearch, applied to AI agent skill prompts:

```
LOOP:
  1. Evaluate the current skill against test cases
  2. Pick a mutation operator (add_constraint, add_negative_example, etc.)
  3. Claude applies that specific mutation to the skill prompt
  4. Re-evaluate the modified skill
  5. If pass rate improved → git commit, keep it
  6. If not → git revert, discard (but preserve in history for learning)
  7. Log results, track mutation success rates, repeat
```

One file gets modified (SKILL.md). One metric decides (pass rate). Git tracks winners.

## What We Learned

We ran 30+ iterations optimizing an auto-reminder skill (creating cron jobs when the agent makes commitments). Here's what actually works:

### Prompt Design

- **Agents follow explicit requests but miss implicit ones.** "Remind me to X" works. The agent saying "I'll check back" and forgetting to set a reminder — that's the hard problem.
- **A "STOP AND CHECK" gate is the single most effective pattern.** One self-question before every reply ("Does this contain a commitment?") beat every longer, more detailed prompt version.
- **"MUST" beats "should."** Absolute language correlates with compliance. Vague instructions get ignored.
- **Structure > length.** A well-organized 60-line prompt outperforms a verbose 150-line one.

### The Optimization Loop

- **Unstructured rewrites destroy progress.** Letting the optimizer freely rewrite the entire file produces 1-line replacements that nuke working prompts. Named mutation operators that force surgical changes fix this.
- **The same prompt scores differently each run.** Expect 5-10% variance. Use confidence margins or fixed validation sets.
- **Plateau breaking requires structural shifts.** Tweaking wording within the same structure doesn't escape local optima. After 5 stale runs, throw away the structure and rebuild from scratch.
- **Separate the generator and judge.** When Claude writes a response AND judges it, it grades charitably. Judging in isolation (without seeing the prompt) gives honest scores.

### Evaluation

- **Binary yes/no criteria are the foundation.** "Did the agent run the command?" not "Was the output good?"
- **Deterministic checks first, LLM judge second.** Grepping for expected commands is faster and more reliable than asking an LLM.
- **Balance test cases ~70/30.** Too many positive cases → over-triggering. Too many negative → too conservative.

## Getting Started

### For Claude Code Skills

If you have a skill in `~/.claude/skills/` that you want to improve:

1. Clone this repo:
```bash
git clone https://github.com/cgraves09/autoskill.git
cd autoskill
```

2. Tell Claude Code to set up the eval for your skill:
```
I want to optimize my skill with autoskill.

Read the skill at ~/.claude/skills/my-skill/SKILL.md
and the autoskill framework at ~/autoskill/README.md.

Then:
1. Generate test_cases.json with 15-20 test cases covering
   positive, negative, implicit, and edge cases
2. Generate a judge.md scoring rubric specific to this skill
3. Write both files to ~/.claude/skills/my-skill/
4. Run a baseline eval: ./eval.sh ~/.claude/skills/my-skill/
5. If the baseline looks right, start the improvement loop:
   ./improve.sh ~/.claude/skills/my-skill/ 95
```

Claude Code will read your skill, understand what it does, generate the test suite, and run the optimization loop autonomously.

### For OpenClaw Skills

If you're using OpenClaw and have skills in `~/.openclaw-donna/skills/`:

1. Clone this repo:
```bash
git clone https://github.com/cgraves09/autoskill.git
cd autoskill
```

2. Tell Claude Code to set up the eval for your OpenClaw skill:
```
I want to optimize my OpenClaw skill with autoskill.

Read the skill at ~/.openclaw-donna/skills/my-skill/SKILL.md
and the autoskill framework at ~/autoskill/README.md.

Then:
1. Generate test_cases.json with 15-20 test cases covering
   positive, negative, implicit, and edge cases
2. Generate a judge.md scoring rubric — make sure it checks
   for the correct openclaw command syntax (flags, parameters)
3. Write both files to ~/.openclaw-donna/skills/my-skill/
4. Run a baseline eval: ./eval.sh ~/.openclaw-donna/skills/my-skill/
5. If the baseline looks right, start the improvement loop:
   ./improve.sh ~/.openclaw-donna/skills/my-skill/ 95
```

The evaluator already understands `openclaw cron create` syntax and will check for correct flags (`--run-at`, `--task`, `--schedule`, `--announce`, `--to`).

### For Any Other Skill Format

AutoSkill works with any skill that has a prompt file the agent follows. The only requirements:

1. A **skill file** (SKILL.md or similar) — the prompt being optimized
2. A **test_cases.json** — scenarios with expected behaviors
3. A **judge.md** — how to score pass/fail

Tell Claude Code:
```
I want to optimize a skill prompt with autoskill.

Read the skill at /path/to/my-skill.md and the autoskill
framework at ~/autoskill/README.md.

Generate test_cases.json and judge.md for this skill, then
run the eval and improvement loop.
```

### Manual Setup (Without Claude Code)

If you prefer to set things up yourself:

#### 1. Create Test Cases

Place `test_cases.json` alongside the skill's `SKILL.md`:

```json
[
  {
    "id": "short-descriptive-name",
    "category": "positive",
    "user_message": "What the user says to trigger the skill",
    "expected_behavior": "action_taken",
    "notes": "What correct behavior looks like"
  },
  {
    "id": "should-not-trigger",
    "category": "negative",
    "user_message": "A message that should NOT activate the skill",
    "expected_behavior": "no_action",
    "notes": "Skill should stay quiet here"
  }
]
```

#### 2. Create a Judge Rubric (Optional)

Place `judge.md` alongside the test cases. If not provided, the generic rubric is used. Write a custom one when your skill has specific command syntax to verify.

#### 3. Run Baseline

```bash
./eval.sh /path/to/skill            # full eval
./eval.sh /path/to/skill --dry-run  # verify test cases load
```

#### 4. Run the Improvement Loop

```bash
./improve.sh /path/to/skill          # default 95% target
./improve.sh /path/to/skill 90       # custom target
```

Runs autonomously — ~10 min per iteration. Let it run overnight. Aim for 15-25 test cases with ~70% positive, ~30% negative/edge.

## Mutation Operators

The v2 loop uses 6 named mutation strategies, rotated each cycle:

| Operator | What It Does | Effectiveness |
|----------|-------------|---------------|
| `add_constraint` | Add a specific, concrete rule where one is vague or missing | Medium |
| `add_negative_example` | Show what WRONG behavior looks like | Medium |
| `tighten_language` | Change "should" to "MUST", remove ambiguity | High |
| `add_counterexample` | Before/after example of correct vs incorrect | High |
| `restructure` | Reorder sections, move critical rules to top | Low |
| `remove_bloat` | Delete redundant text, merge duplicate sections | Low |

After 5 consecutive discards, a **plateau breaker** triggers — throws away the prompt structure entirely and rewrites from scratch using only the eval criteria and failure history.

## Safety Guards

- **Minimum line count** — any mutation producing fewer than 20 lines is auto-rejected (prevents destructive rewrites)
- **git revert** instead of git reset — failed experiments stay in history so the optimizer can learn from them
- **State on disk** — `state.json` tracks iteration count, consecutive discards, and per-mutation success rates (survives context window limits)
- **Deterministic scoring first** — grep for expected commands before invoking LLM judge

## Project Structure

```
autoskill/
├── eval.sh              # Runs eval against a skill
├── evaluate.py          # Evaluation engine (simulates agent, scores responses)
├── improve.sh           # Autonomous improvement loop (v2 — structured mutations)
├── judge.md             # Generic scoring rubric (fallback)
├── test_cases.json      # Template test cases
├── program.md           # Framework philosophy and rules
├── state.json           # Loop state (iteration, discards, mutation stats)
├── results.tsv          # Experiment log
├── eval_results.json    # Latest eval output
└── examples/
    └── auto-reminder/   # Example: optimizing a cron reminder skill
        ├── test_cases.json
        └── judge.md
```

## The Autoresearch Mapping

| Autoresearch | AutoSkill |
|---|---|
| `train.py` — code being optimized | `SKILL.md` — prompt being optimized |
| `prepare.py` — fixed eval | `evaluate.py` — fixed eval harness |
| `val_bpb` — single metric | Pass rate — single percentage |
| `program.md` — rules | `program.md` — same |
| `results.tsv` — experiment log | `results.tsv` — same |
| 5-min training budget | ~10 min eval budget per iteration |
| Git commit if improved | Git commit if improved |
| Git reset if not | Git revert if not (preserves history) |
| No mutation strategy | 6 named operators + plateau breaker |
| No stuck detection | Auto-escalates after 5 discards |

## Writing Good Test Cases

### Categories

| Category | Purpose | % of Total |
|----------|---------|------------|
| `positive` | Should trigger the skill | ~40% |
| `implicit` | Subtle/indirect triggers | ~20% |
| `edge` | Boundary cases, ambiguous phrasing | ~10% |
| `complex` | Multi-part, buried, conditional | ~10% |
| `negative` | Should NOT trigger | ~20% |

### Test Case Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique identifier |
| `category` | yes | Category for grouping |
| `user_message` | yes | What the user says |
| `expected_behavior` | yes | What should happen |
| `expected_phrases` | no | Keywords expected in response |
| `agent_should_say` | no | Hint for agent response |
| `notes` | no | Human-readable explanation |

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command)
- Python 3.8+
- Git

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — the original pattern
- [uditgoenka/autoresearch](https://github.com/uditgoenka/autoresearch) — universal adaptation with subcommands and guard checks
- [k.balu124's article](https://medium.com/@k.balu124/i-turned-andrej-karpathys-autoresearch-into-a-universal-skill-1cb3d44fc669) — mutation operators, eval isolation, plateau breaking, validation sets
