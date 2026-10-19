#!/usr/bin/env bash
# With sim.py on the card's compute list, runs it on the login node (C01), then a renamed copy, python3 -I and -c.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git pull -q
python3 sim.py --steps 1 > ~/.audit/listed 2>&1; note listed $?
note listed_code "$(head -c 8 ~/.audit/listed)"
cp sim.py model.py
python3 model.py --steps 1 > /dev/null 2>&1; note renamed $?
python3 -I sim.py --steps 1 > /dev/null 2>&1; note isolated $?
python3 -c 'import runpy, sys; sys.argv = ["sim.py", "--steps", "1"]; runpy.run_path("sim.py", run_name="__main__")' > /dev/null 2>&1; note runpy $?
