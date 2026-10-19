# shellcheck shell=bash
# Sourced by tests/run.sh: the guides of design-v8 section 2. The compute gate (C01) and the PATH shim (S01 to S03)
# refuse with a runnable line 2 and let the benign forms through.
echo "== walls"
WL=${tmp:?}/walls; gate=$here/lib/compute-gate; shim=$here/lib/shim
git init -q --bare -b main "$WL/origin.git"; git clone -q "$WL/origin.git" "$WL/ocean" 2>/dev/null
mkdir -p "$WL/ocean/guard" "$WL/ocean/x" "$WL/ocean/runs/spinup"
printf '#!/bin/bash\n#SBATCH --time=00:10:00\npython3 sim.py\n' > "$WL/ocean/job.sh"
printf '#!/usr/bin/env python3\nprint("ran")\n' > "$WL/ocean/sim.py"; cp "$WL/ocean/sim.py" "$WL/ocean/other.py"
chmod +x "$WL/ocean/job.sh" "$WL/ocean/sim.py"
printf 'account: gom\nmax_walltime_minutes: 120\ncompute: sim.py job.sh\n' > "$WL/ocean/guard/budget.card"
git -C "$WL/ocean" add -A; git -C "$WL/ocean" commit -q -m start; git -C "$WL/ocean" push -q -u origin HEAD:main 2>/dev/null
git -C "$WL/ocean" remote set-head origin main
gated() {  # gated <command>: runs it in bash in the project with the compute gate on, as the sandbox sets it
  (cd "$WL/ocean" && env -u SLURM_JOB_ID -u GUARD_JOB_ID BASH_ENV="$gate/bash_env.sh" PYTHONPATH="$gate" "$@")
}
c01=$'^H4R-C01 sim.py runs only inside a job; guard/budget.card lists it under compute\nguard run runs/spinup --why \'Run job.sh for run spinup.\' -- --time=120 job.sh$'
expect_refusal compute-python C01 -- gated python3 sim.py
expect_refusal compute-python-args C01 -- gated python3 ./sim.py --max-steps 1
expect_refusal compute-bash C01 -- gated bash job.sh
expect_refusal compute-exec C01 -- gated ./job.sh
expect_refusal compute-shebang C01 -- gated ./sim.py
expect_refusal compute-other-dir C01 -- gated bash -c 'cd x && python3 ../sim.py'
c01_lines() { [[ $(gated python3 sim.py 2>&1) =~ $c01 ]]; }
expect compute-line2 ok - -- c01_lines
expect compute-slurm-job ok '^ran$' -- gated env SLURM_JOB_ID=1000 python3 sim.py
expect compute-guard-job ok '^ran$' -- gated env GUARD_JOB_ID=skynet-20261019T120000Z python3 sim.py
expect compute-guard-job-bash ok '^ran$' -- gated env GUARD_JOB_ID=skynet-20261019T120000Z bash job.sh
expect compute-unlisted ok '^ran$' -- gated python3 other.py
expect compute-help ok '^ran$' -- gated python3 sim.py --help
expect compute-inline ok '^1$' -- gated python3 -c 'print(1)'
# A guide, not a wall: python3 -I skips sitecustomize, and a renamed copy is not on the list.
expect compute-isolated-passes ok '^ran$' -- gated python3 -I sim.py
expect compute-renamed-passes ok '^ran$' -- gated bash -c 'cp sim.py sim2.py && python3 sim2.py'
printf 'account: gom\ncompute: none\n' > "$WL/ocean/guard/budget.card"
expect_refusal compute-card-from-main C01 -- gated python3 sim.py
git -C "$WL/ocean" commit -q -am "compute: none"; git -C "$WL/ocean" push -q origin HEAD:main 2>/dev/null
expect compute-card-none ok '^ran$' -- gated python3 sim.py
expect compute-outside-checkout ok '^ran$' -- bash -c 'cd "$1" && cp ocean/other.py sim.py && env BASH_ENV="$2/bash_env.sh" PYTHONPATH="$2" python3 sim.py' _ "$WL" "$gate"

shimmed() {  # shimmed <command>: runs it in the project with lib/shim first on PATH, as the sandbox sets it
  (cd "$WL/ocean" && PATH="$shim:$PATH" "$@")
}
git -C "$WL/ocean" switch -q -c work
expect_refusal shim-force S03 -- shimmed git push --force origin work
expect_refusal shim-force-short S03 -- shimmed git push -fu origin work
expect_refusal shim-force-with-lease S03 -- shimmed git push --force-with-lease origin work
expect_refusal shim-force-with-lease-ref S03 -- shimmed git push --force-with-lease=work:abc origin work
expect_refusal shim-plus-refspec S03 -- shimmed git push origin +HEAD:main
expect_refusal shim-force-global-opts S03 -- shimmed git -C "$WL/ocean" -c push.default=simple push -f
expect shim-force-line2 ok '^git pull --rebase origin main$' -- bash -c 'cd "$1/ocean" && PATH="$2:$PATH" git push origin +HEAD:main 2>&1 | tail -n 1' _ "$WL" "$shim"
expect shim-force-line2-branch ok '^git pull --rebase origin work$' -- bash -c 'cd "$1/ocean" && PATH="$2:$PATH" git push --force 2>&1 | tail -n 1' _ "$WL" "$shim"

expect shim-push-passes ok - -- shimmed git push -q origin work
expect shim-push-landed ok - -- git -C "$WL/ocean" rev-parse -q --verify refs/remotes/origin/work
expect shim-git-passes ok '^work$' -- shimmed git branch --show-current
expect shim-full-path-passes ok - -- shimmed "$(command -v git)" push -q --force origin work

mkdir -p "$WL/ocean/runs/spinup/out" "$WL/ocean/data" "$WL/scratch-$$"
expect_refusal shim-rm-data S02 -- shimmed rm -rf data
expect_refusal shim-rm-top S02 -- shimmed rm -rf .
expect_refusal shim-rm-parent S02 -- shimmed rm -fr "${WL:?}"
expect_refusal shim-rm-split-flags S02 -- shimmed rm -r -f --verbose data
expect_refusal shim-rm-dotdot S02 -- shimmed rm -rf runs/spinup/../..
expect shim-rm-names-run-dir ok '^H4R-S02 rm -rf \.\./\.\./data is outside .*/ocean/runs/spinup$' -- bash -c 'cd "$1/ocean/runs/spinup" && PATH="$2:$PATH" rm -rf ../../data 2>&1 | head -n 1' _ "$WL" "$shim"
expect shim-rm-data-kept ok - -- test -d "$WL/ocean/data"
expect shim-rm-run-dir ok - -- shimmed rm -rf runs/spinup/out
expect shim-rm-run-dir-gone fail - -- test -e "$WL/ocean/runs/spinup/out"
expect shim-rm-tmp ok - -- shimmed rm -rf "${WL:?}/scratch-$$" /tmp/guard-walls-absent-$$
expect shim-rm-plain ok - -- bash -c 'touch "$1/ocean/x/f" && cd "$1/ocean" && PATH="$2:$PATH" rm x/f && ! test -e x/f' _ "$WL" "$shim"
expect shim-rm-r-only ok - -- shimmed rm -r data
expect shim-rm-full-path ok - -- bash -c 'mkdir -p "$1/ocean/data2" && cd "$1/ocean" && PATH="$2:$PATH" /bin/rm -rf data2' _ "$WL" "$shim"

sleeper() {  # sleeper <tag> [VAR=value...]: a background process whose command line names <tag>, printing its pid
  env "${@:2}" bash -c "exec -a 'python3 walls-$1' sleep 300" >/dev/null 2>&1 & echo $!
}
mine=$(sleeper mine); job=$(sleeper job GUARD_JOB_ID=skynet-1); other=$(sleeper other GUARD_SESSION=someone-else)
sleep 0.3
expect_refusal shim-pkill-job S01 -- shimmed pkill -f 'walls-job'
expect_refusal shim-pkill-other-session S01 -- shimmed env GUARD_SESSION=me pkill -f 'walls-other'
expect_refusal shim-pkill-signal-first S01 -- shimmed pkill -9 -f 'python3 walls'
expect shim-pkill-job-alive ok - -- kill -0 "$job"
expect shim-pkill-other-alive ok - -- kill -0 "$other"
expect shim-pkill-mine ok - -- shimmed pkill -f 'walls-mine'
expect shim-pkill-mine-gone fail - -- bash -c 'sleep 0.3; kill -0 "$1" 2>/dev/null' _ "$mine"
expect shim-pkill-no-match fail - -- shimmed pkill -f 'walls-nothing-matches-this'
expect shim-pkill-no-f fail - -- shimmed pkill -x nonexistent-walls-proc-name-$$
kill "$job" "$other" 2>/dev/null; wait "$mine" "$job" "$other" 2>/dev/null
