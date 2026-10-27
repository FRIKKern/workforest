#!/usr/bin/env python3
# Stands in for the claude CLI in test.sh. Answers like `claude -p --output-format json --json-schema` with
# tools/fakeanswer.py. With $WORKFOREST_TEST_CLAUDE_LIMIT set it answers like an account that is out of usage.
# It fails when tools are left on or an API key reaches it.
import json, os, sys
args = sys.argv[1:]
data = sys.stdin.read()
def fail(msg):
    print(json.dumps({"type": "result", "is_error": True, "result": msg, "total_cost_usd": 0.0, "usage": {}}))
    sys.exit(1)
if os.environ.get("WORKFOREST_TEST_CLAUDE_LIMIT"): fail("Claude AI usage limit reached|1793880000")
if "--tools" not in args or args[args.index("--tools") + 1] != "": fail("fixture: tools are not off")
if "ANTHROPIC_API_KEY" in os.environ: fail("fixture: an API key reached claude")
import fakeanswer
so = fakeanswer.answer(data, args[args.index("--json-schema") + 1])
print(json.dumps({"type": "result", "is_error": False, "result": "", "structured_output": so,
                  "total_cost_usd": 0.0, "usage": {"input_tokens": 10, "output_tokens": 5}}))
