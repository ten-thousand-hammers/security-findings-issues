# Reports on the fake gh CLI's stored state, for the test harness.
import json, os, sys

path = os.environ["GH_STATE"]
state = json.load(open(path)) if os.path.exists(path) else {"issues": [], "calls": []}
issues, calls = state["issues"], state["calls"]
what = sys.argv[1]

if what == "states":
    print(" ".join(sorted("%d:%s" % (i["number"], i["state"]) for i in issues)))
elif what == "open-count":
    print(len([i for i in issues if i["state"] == "open"]))
elif what == "edit-calls":
    print(len([c for c in calls if c.startswith("issue edit")]))
elif what == "body":
    n = int(sys.argv[2])
    print(next((i["body"] for i in issues if i["number"] == n), ""))
else:
    sys.exit("unknown query: %s" % what)
