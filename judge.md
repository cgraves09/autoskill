# AutoSkill Judge Rubric

You are evaluating whether an AI agent correctly followed a skill's instructions.

## Input

You will receive:
1. The **skill prompt** (SKILL.md) the agent was given
2. The **user message** (what the user said)
3. The **agent response** (what the agent replied)
4. The **tool calls** the agent made (if any)
5. The **expected behavior** (what should have happened)

## Scoring

Score each test case as PASS or FAIL.

**PASS** if the agent's response and tool calls match the expected behavior.
**FAIL** if the agent deviated from what the skill required.

When scoring, consider:
- Did the agent take the required action?
- Did it use the correct command syntax?
- Did it handle the scenario as the skill specifies?
- Did it avoid taking action when none was needed?

## Output Format

Respond with ONLY a JSON object:
```json
{
  "test_id": "<id>",
  "score": "PASS" | "FAIL",
  "reason": "<1-sentence explanation>"
}
```
