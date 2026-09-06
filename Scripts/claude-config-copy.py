#  claude-config-copy.py -- an agent configuration for a bench to write into.
#
#  A copy of the real `.claude.json` with `projects` emptied, so a bench that
#  answers a trust question leaves the answer HERE and the user's own file
#  keeps its checksum (ISC-132). Everything else is copied because a config
#  built from nothing is a machine that has never logged in, and a bench
#  against a logged-out agent measures a different screen.

import json
import os
import sys

source, target = sys.argv[1], sys.argv[2]
data = json.load(open(source)) if os.path.exists(source) else {}
data["projects"] = {}
# 0600 from the moment it exists: it carries the account the real file carries.
handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(handle, "w") as out:
    json.dump(data, out)
