#!/usr/bin/env bash
# usage: GPU=<uuid from nvidia-smi -L> eval/serve/qwen3.6-fp8.sh    run it in tmux; stop it with Ctrl-C there
# Serves Qwen/Qwen3.6-35B-A3B-FP8 for the evaluation with the model host's launch command from their serving
# report (2026-10-09). The model path, which is our copy, and the port differ, and prefix caching is on, which
# vLLM 0.21 leaves off for this hybrid model unless asked (its 'align' mode for the Mamba layers is experimental). On skynet it runs outside
# Slurm on GPU 1: Slurm's gres.conf lists /dev/nvidia1-3, and /dev/nvidia1 is GPU 0, the model host's.
set -euo pipefail
python=${VLLM_PYTHON:-/conda/$USER/h4r/vllm-0.21.0/bin/python}
model=${MODEL_DIR:-/conda/$USER/h4r/models/qwen36-35b-fp8}
port=${PORT:-9185}
# Compile and download caches default to the NFS home, where vLLM's torch.compile cache writes stall for minutes.
cache=${CACHE_DIR:-/conda/$USER/h4r/cache}
export VLLM_CACHE_ROOT=$cache/vllm TRITON_CACHE_DIR=$cache/triton TORCHINDUCTOR_CACHE_DIR=$cache/inductor \
  HF_HOME=$cache/huggingface XDG_CACHE_HOME=$cache
# FlashInfer's top-k/top-p sampler compiles itself with nvcc on first use; skynet has no CUDA 13 toolkit.
export VLLM_USE_FLASHINFER_SAMPLER=0
: "${GPU:?set GPU to the UUID of the GPU to use, from nvidia-smi -L}"
used=$(nvidia-smi --id="$GPU" --query-gpu=memory.used --format=csv,noheader,nounits)
[ "$used" -le 1024 ] || { echo "GPU $GPU already has $used MiB in use" >&2; exit 1; }
# vLLM reads CUDA_VISIBLE_DEVICES as integers; in PCI bus order CUDA numbers GPUs as nvidia-smi does.
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$(nvidia-smi --id="$GPU" --query-gpu=index --format=csv,noheader)
nvidia-smi -L | grep "$GPU"
"$python" -c 'import vllm, torch; print("vllm", vllm.__version__, "torch", torch.__version__, "cuda device 0 is", torch.cuda.get_device_properties(0).uuid)'
exec "$python" -m vllm.entrypoints.openai.api_server \
  --model "$model" --served-model-name Qwen/Qwen3.6-35B-A3B-FP8 --host 127.0.0.1 --port "$port" \
  --dtype auto --tensor-parallel-size 1 --gpu-memory-utilization 0.92 --max-model-len 131072 \
  --max-num-seqs 8 --max-num-batched-tokens 8192 --kv-cache-dtype auto --seed 0 --trust-remote-code \
  --enable-auto-tool-choice --enable-prompt-tokens-details --limit-mm-per-prompt '{"image":0,"video":0}' \
  --tool-call-parser qwen3_xml --reasoning-parser qwen3 --enable-prefix-caching
