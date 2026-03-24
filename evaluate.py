#!/usr/bin/env python3
"""
AutoSkill Evaluator — runs test cases against a skill and scores with LLM-as-judge.

This is the "prepare.py" equivalent from autoresearch: fixed evaluation infrastructure
that never changes. The skill prompt (SKILL.md) is the only thing that gets optimized.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta

def load_file(path):
    with open(path) as f:
        return f.read()

def load_json(path):
    with open(path) as f:
        return json.load(f)

def simulate_agent_response(skill_content, test_case):
    """
    Simulate what the agent would do given the skill prompt and user message.

    Uses Claude to generate a response AS IF the agent had the skill loaded,
    then checks whether the agent created a cron.

    Returns: (response_text, tool_calls, raw_output)
    """
    user_msg = test_case["user_message"]

    # Build the simulation prompt
    prompt = f"""You are an AI assistant named Donna. You have the following skill loaded:

<skill>
{skill_content}
</skill>

The current time is {datetime.now().strftime('%Y-%m-%dT%H:%M:%S-04:00')}.

The user sends you this message:
<user_message>
{user_msg}
</user_message>

Respond EXACTLY as you would in a real conversation. If the skill requires you to
run commands before responding, show those commands in <exec> tags. For example:
<exec>openclaw cron create --name "reminder-dentist" --run-at "2026-03-24T08:00:00-04:00" --model sonnet --task "Remind user to call the dentist" --announce --to CHANNEL_ID</exec>

Then write your response to the user.

IMPORTANT: Follow the skill instructions precisely. If your response contains a
commitment to a future action, you MUST create a cron BEFORE responding.
"""

    # Call Claude API via the anthropic CLI or python SDK
    try:
        result = subprocess.run(
            [
                "claude", "-p", prompt,
                "--model", "sonnet",
                "--max-turns", "1",
                "--output-format", "json"
            ],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return None, [], f"CLI error: {result.stderr}"

        try:
            output = json.loads(result.stdout)
            response_text = output.get("result", result.stdout)
        except json.JSONDecodeError:
            response_text = result.stdout

        # Extract exec/tool calls from response
        tool_calls = []
        import re
        exec_blocks = re.findall(r'<exec>(.*?)</exec>', response_text, re.DOTALL)
        for block in exec_blocks:
            tool_calls.append(block.strip())

        # Also check for openclaw cron create outside exec tags
        if "openclaw cron create" in response_text:
            # Find all openclaw cron create commands
            cron_cmds = re.findall(r'openclaw cron create[^\n]*(?:\\\n[^\n]*)*', response_text)
            for cmd in cron_cmds:
                if cmd.strip() not in tool_calls:
                    tool_calls.append(cmd.strip())

        return response_text, tool_calls, None

    except subprocess.TimeoutExpired:
        return None, [], "Timeout"
    except FileNotFoundError:
        return None, [], "claude CLI not found — install with: npm install -g @anthropic-ai/claude-code"

def judge_response(judge_prompt, skill_content, test_case, response_text, tool_calls):
    """
    Use LLM-as-judge to score whether the agent correctly followed the skill.
    EVAL ISOLATION: The judge does NOT see the skill prompt — it judges the output
    without knowing what instructions produced it. This prevents charitable grading.
    Returns: dict with score, reason, etc.
    """
    expected = test_case["expected_behavior"]
    prompt = f"""{judge_prompt}

## Test Case

**User message:** {test_case['user_message']}

**Agent response:**
{response_text}

**Tool calls / commands executed:**
{json.dumps(tool_calls, indent=2) if tool_calls else "None"}

**Expected behavior:** {expected}

Score this test case. Respond with ONLY the JSON object.
"""

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--model", "haiku", "--max-turns", "1", "--output-format", "json"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {"test_id": test_case["id"], "score": "ERROR", "reason": f"Judge error: {result.stderr}"}

        try:
            output = json.loads(result.stdout)
            judge_text = output.get("result", result.stdout)
        except json.JSONDecodeError:
            judge_text = result.stdout

        # Parse the judge's JSON response
        import re
        json_match = re.search(r'\{[^{}]*\}', judge_text, re.DOTALL)
        if json_match:
            return json.loads(json_match.group())

        # Fallback: deterministic scoring based on tool calls
        return deterministic_score(test_case, response_text, tool_calls)

    except Exception as e:
        return deterministic_score(test_case, response_text, tool_calls)

def deterministic_score(test_case, response_text, tool_calls):
    """
    Fallback deterministic scoring when LLM judge fails.
    Checks for cron creation commands in tool calls.
    """
    expected = test_case["expected_behavior"]
    has_cron = any("openclaw cron create" in tc for tc in tool_calls) if tool_calls else False

    if expected == "cron_created":
        if has_cron:
            # Check syntax
            syntax_ok = True
            for tc in tool_calls:
                if "openclaw cron create" in tc:
                    if "--run-at" not in tc and "--schedule" not in tc:
                        syntax_ok = False
                    if "--task" not in tc:
                        syntax_ok = False
            score = "PASS" if syntax_ok else "FAIL"
            reason = "Cron created with correct syntax" if syntax_ok else "Cron created but syntax issues"
        else:
            # Check if the response even contains commitment language
            commitment_words = ["I'll", "I will", "let me", "will do"]
            has_commitment = any(w.lower() in (response_text or "").lower() for w in commitment_words)
            score = "FAIL"
            reason = "Commitment made but no openclaw cron created" if has_commitment else "No openclaw cron created"

        return {
            "test_id": test_case["id"],
            "score": score,
            "reason": reason,
            "cron_created": has_cron,
            "cron_syntax_correct": syntax_ok if has_cron else None,
            "commitment_detected": has_commitment if not has_cron else True
        }
    else:  # no_cron expected
        score = "PASS" if not has_cron else "FAIL"
        reason = "Correctly did not create cron" if not has_cron else "Created cron when none was needed"
        return {
            "test_id": test_case["id"],
            "score": score,
            "reason": reason,
            "cron_created": has_cron,
            "cron_syntax_correct": None,
            "commitment_detected": False
        }

def run_eval(skill_path, test_cases_path, judge_path, output_path, dry_run=False):
    skill_content = load_file(skill_path)
    test_cases = load_json(test_cases_path)
    judge_prompt = load_file(judge_path)

    results = {
        "skill": skill_path,
        "timestamp": datetime.now().isoformat(),
        "skill_hash": hash(skill_content) % (10**8),
        "cases": []
    }

    total = len(test_cases)
    passed = 0

    for i, tc in enumerate(test_cases):
        test_id = tc["id"]
        print(f"\n[{i+1}/{total}] {test_id}: {tc['user_message'][:60]}...")

        if dry_run:
            print(f"  [DRY RUN] Skipping — expected: {tc['expected_behavior']}")
            results["cases"].append({
                "test_id": test_id,
                "score": "SKIP",
                "reason": "dry run"
            })
            continue

        # Step 1: Simulate agent response
        response_text, tool_calls, error = simulate_agent_response(skill_content, tc)
        if error:
            print(f"  ERROR: {error}")
            results["cases"].append({
                "test_id": test_id,
                "score": "ERROR",
                "reason": error
            })
            continue

        # Step 2: Score the response
        # Use deterministic scoring first (faster, more reliable)
        score_result = deterministic_score(tc, response_text, tool_calls)

        # If deterministic is ambiguous, fall back to judge
        if score_result["score"] == "FAIL" and not score_result.get("cron_created") and tc["expected_behavior"] == "cron_created":
            # Double check with judge — maybe the cron was created in a way we didn't parse
            judge_result = judge_response(judge_prompt, skill_content, tc, response_text, tool_calls)
            if judge_result.get("score") == "PASS":
                score_result = judge_result

        results["cases"].append(score_result)

        status = score_result["score"]
        reason = score_result.get("reason", "")
        if status == "PASS":
            passed += 1
            print(f"  PASS: {reason}")
        else:
            print(f"  FAIL: {reason}")

        # Small delay to avoid rate limiting
        time.sleep(0.5)

    # Summary
    scoreable = [c for c in results["cases"] if c["score"] in ("PASS", "FAIL")]
    total_scored = len(scoreable)
    pass_rate = (passed / total_scored * 100) if total_scored > 0 else 0

    results["summary"] = {
        "total": total,
        "scored": total_scored,
        "passed": passed,
        "failed": total_scored - passed,
        "pass_rate": round(pass_rate, 1),
        "errors": total - total_scored
    }

    # Write results
    with open(output_path, 'w') as f:
        json.dump(results, f, indent=2)

    print(f"\nResults written to {output_path}")
    return results

def main():
    parser = argparse.ArgumentParser(description="AutoSkill Evaluator")
    parser.add_argument("--skill", required=True, help="Path to SKILL.md")
    parser.add_argument("--test-cases", required=True, help="Path to test_cases.json")
    parser.add_argument("--judge", required=True, help="Path to judge.md")
    parser.add_argument("--output", required=True, help="Path to write results JSON")
    parser.add_argument("--dry-run", action="store_true", help="List test cases without running")
    args = parser.parse_args()

    run_eval(args.skill, args.test_cases, args.judge, args.output, args.dry_run)

if __name__ == "__main__":
    main()
