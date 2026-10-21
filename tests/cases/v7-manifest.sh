# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== manifest"
echo "$tmp/rows" > "$R/inputs.list"
expect manifest-writes ok - -- env SLURM_JOB_ID=555 LOADEDMODULES=hycom/2.3 bash job.sh "$R"
expect manifest-content ok 'modules: hycom/2.3' -- cat "$R/manifest-555.txt"
expect manifest-idempotent ok 'manifest exists' -- env SLURM_JOB_ID=555 bash job.sh "$R"
rm -f "$R"/manifest-* "$R/inputs.list"
