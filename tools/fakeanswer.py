# The answers tools/fakeclaude.py and tools/fakecodex.py give, from the review input on stdin.
# Review: worktrees whose folder is named in $WORKFOREST_TEST_STALE are stale, in $WORKFOREST_TEST_UNSURE unsure,
# every other worktree active. Judge (the Eager second pass, recognised by its schema): worktrees named in
# $WORKFOREST_TEST_KEEP are kept with evidence, every other one removed. The judge's input is saved to
# $WORKFOREST_TEST_SENT.judge, and every review batch is appended to $WORKFOREST_TEST_SENT. The summary call after several batches
# answers with a count of the lines it got.
import json, os

def names(var):
    return [n for n in os.environ.get(var, "").split(",") if n]

def answer(data, schema):
    j = json.loads(data)
    if "lines" in j:   # the summary call after several batches
        open(os.environ["WORKFOREST_TEST_SENT"] + ".summary", "w").write(data)
        return {"summary": "Fixture overall summary: %d lines." % len(j["lines"])}
    trees = j["worktrees"]
    if '"decision"' in schema:
        open(os.environ["WORKFOREST_TEST_SENT"] + ".judge", "w").write(data)
        keep = names("WORKFOREST_TEST_KEEP")
        return {"trees": [{"id": t["id"], "decision": "keep" if t["folder"] in keep else "remove", "confidence": 0.9,
                           "evidence": "fixture: the work is parked on purpose" if t["folder"] in keep else "",
                           "reason": "the fixture judge says so"} for t in trees]}
    open(os.environ["WORKFOREST_TEST_SENT"], "a").write(data)   # appended: a review may be several batches
    stale, unsure = names("WORKFOREST_TEST_STALE"), names("WORKFOREST_TEST_UNSURE")
    def verdict(t):
        return "stale" if t["folder"] in stale else "unsure" if t["folder"] in unsure else "active"
    return {"summary": "Fixture summary: %d worktrees." % len(trees),
            "trees": [{"id": t["id"], "verdict": verdict(t), "confidence": 0.5 if verdict(t) == "unsure" else 0.95,
                       "about": "fixture", "reason": "fixture says so", "what": "a fixture branch", "why": "test.sh made it",
                       "state": "as the facts say", "recommendation": "whatever the test wants", "keep_evidence": ""} for t in trees]}
