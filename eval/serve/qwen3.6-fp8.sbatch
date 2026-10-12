#!/usr/bin/env bash
# usage: sbatch eval/serve/qwen3.6-fp8.sbatch    stop: scancel --name=h4r-vllm-qwen3.6
# Serves Qwen/Qwen3.6-35B-A3B-FP8 for the evaluation with the model host's launch command from their serving
# report (2026-10-09), on one A100 that Slurm assigns. Only the model path, which is our copy, and the port differ.
#SBATCH --job-name=h4r-vllm-qwen3.6
#SBATCH --partition=gpu
#SBATCH --gres=gpu:a100:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=3-00:00:00
#SBATCH --output=%x-%j.log
set -euo pipefail
python=${VLLM_PYTHON:-$HOME/vllm-0.21.0/bin/python}
model=${MODEL_DIR:-$HOME/models/qwen36-35b-fp8}
port=${PORT:-9185}
nvidia-smi -L
"$python" -c 'import vllm, torch; print("vllm", vllm.__version__, "torch", torch.__version__)'
exec "$python" -m vllm.entrypoints.openai.api_server \
  --model "$model" --served-model-name Qwen/Qwen3.6-35B-A3B-FP8 --host 127.0.0.1 --port "$port" \
  --dtype auto --tensor-parallel-size 1 --gpu-memory-utilization 0.92 --max-model-len 131072 \
  --max-num-seqs 8 --max-num-batched-tokens 8192 --kv-cache-dtype auto --seed 0 --trust-remote-code \
  --enable-auto-tool-choice --enable-prompt-tokens-details --limit-mm-per-prompt '{"image":0,"video":0}' \
  --tool-call-parser qwen3_xml --reasoning-parser qwen3
