# AutoSkill — Autonomous Skill Improvement Framework

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).
Same core loop: modify → run → measure → keep/discard.

## Philosophy

A skill is a prompt. Prompts can be optimized the same way hyperparameters can —
by running experiments, measuring outcomes, and keeping what works.

## The Loop

```
LOOP FOREVER:
1. Read the current skill file (SKILL.md) and results.tsv
2. Propose a modification to the skill prompt
3. git commit the change
4. Run the eval suite: `./eval.sh <skill-dir>`
5. Parse the score from eval output
6. If score improved → keep commit, update best score
7. If score equal or worse → git reset --hard to last good commit
8. Log results to results.tsv
9. Repeat
```

## Rules

- **One file modified per experiment**: the SKILL.md being optimized
- **Fixed eval suite**: test cases don't change during a run (like prepare.py)
- **Single metric**: pass rate (% of test cases where the skill produced correct behavior)
- **Target**: 95% pass rate for auto-reminder; configurable per skill
- **Binary decision**: higher pass rate = keep; same or lower = discard
- **Simplicity criterion**: if pass rate is equal, prefer shorter/simpler prompts
- **Never stop**: continue until manually interrupted or target reached

## What the Agent Can Modify

- The SKILL.md file (prompt text, structure, trigger phrases, rules)
- Nothing else. The eval harness and test cases are fixed.

## What the Agent Cannot Modify

- `eval.sh` (the evaluation runner)
- `test_cases.json` (the test scenarios)
- `judge.md` (the scoring rubric)

## Experiment Ideas for auto-reminder

- Add more trigger phrase patterns
- Restructure the execution order
- Add pre-flight checklist before responding
- Add "STOP AND CHECK" gates in the prompt
- Use XML tags to force structured thinking
- Add negative examples (what forgetting looks like)
- Add a self-verification step after drafting response
- Reduce prompt length while maintaining coverage
- Reorder sections by importance
- Add constitutional-style "before every response" rules
