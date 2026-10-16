#!/usr/bin/env bash
# usage, first line of work in a job script: manifest.sh "$RUN_DIR" "$0" "$@"
# Writes <run_dir>/manifest-<jobid>.txt before any work. Never overwrites, so resubmits are safe.
# HPC_LOCK_FILES: space-separated env lockfiles to hash. HPC_HASH_INPUTS=1: hash inputs, else size+mtime.
set -euo pipefail
run_dir=${1%/}; shift
id=${SLURM_ARRAY_JOB_ID:+${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID:-}}
id=${id:-${SLURM_JOB_ID:-${PBS_JOBID:-${FLUX_JOB_ID:-local-$(date +%s)}}}}
[ -z "${HPC_JOB_ID:-}" ] || id=$HPC_JOB_ID
out="$run_dir/manifest-$id.txt"
[ -e "$out" ] && { echo "manifest exists: $out" >&2; exit 0; }
short_hash() { sha256sum "$1" | cut -c1-16; }
{
  echo "time: $(date -u +%FT%TZ)"
  echo "host: $(hostname)"
  echo "job_id: $id"
  echo "run_id: $(basename "$run_dir")"
  echo "commit: $(git rev-parse HEAD)"
  echo "dirty_files: $(git status --porcelain | wc -l)"
  echo "modules: ${LOADEDMODULES:-none}"
  echo "venv: ${VIRTUAL_ENV:-none}"
  echo "conda: ${CONDA_PREFIX:-none}"
  echo "cuda_visible_devices: ${CUDA_VISIBLE_DEVICES:-unset}"
  echo "python: $(command -v python3 || echo none)"
  c=${APPTAINER_CONTAINER:-${SINGULARITY_CONTAINER:-}}
  if [ -n "$c" ]; then echo "container: $c $(stat -c '%s %Y' "$c")"; else echo "container: none"; fi
  for f in ${HPC_LOCK_FILES:-}; do echo "lock: $f $(short_hash "$f")"; done
  if [ -f "$run_dir/inputs.list" ]; then
    while read -r f; do
      [ -z "$f" ] && continue
      if [ "${HPC_HASH_INPUTS:-0}" = 1 ]; then echo "input: $f $(short_hash "$f")"
      else echo "input: $f $(stat -c '%s %Y' "$f")"; fi
    done < "$run_dir/inputs.list"
  fi
  echo "command: $*"
} > "$out"
