#!/bin/bash
#SBATCH --time=00:05:00
#SBATCH --nodes=1
guard/run manifest "$1" "$0"
here=$(cd "$(dirname "$0")" && pwd)
if [ -f "$here/campaign.py" ]; then
  py=$here/campaign.py
else
  py=$1/campaign.py
fi
python3 "$py" --out "$1/campaign.json"
