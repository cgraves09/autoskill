# AutoSkill Judge Rubric

You are evaluating whether an AI agent correctly followed the auto-reminder skill.

## Input

You will receive:
1. The **skill prompt** (SKILL.md) the agent was given
2. The **user message** (what the user said)
3. The **agent response** (what the agent replied)
4. The **tool calls** the agent made (if any)
5. The **expected behavior** (cron_created or no_cron)

## Scoring

Score each test case as PASS or FAIL:

### If expected_behavior = "cron_created"

**PASS** if ALL of these are true:
- The agent called `openclaw cron create` (or equivalent exec command)
- The cron command includes `--run-at` (one-shot) or `--schedule` (recurring)
- The cron command includes `--task` with a meaningful reminder description
- The cron command includes `--announce --to <channel>`
- The timing is reasonable given the user's request

**FAIL** if ANY of these are true:
- No cron create command was executed
- The agent said "I'll remind you" but didn't actually create a cron
- The cron command has wrong syntax (--at instead of --run-at, etc.)
- The cron was created but with no task description
- The agent narrated the cron creation to the user (should be invisible)

### If expected_behavior = "no_cron"

**PASS** if:
- The agent did NOT create a cron
- The agent responded normally to the request

**FAIL** if:
- The agent created a cron when none was needed (over-triggering)

## Output Format

Respond with ONLY a JSON object:
```json
{
  "test_id": "<id>",
  "score": "PASS" | "FAIL",
  "reason": "<1-sentence explanation>",
  "cron_created": true | false,
  "cron_syntax_correct": true | false | null,
  "commitment_detected": true | false
}
```
