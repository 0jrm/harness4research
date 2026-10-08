#!/usr/bin/env bash
# usage: eval/env/site-python.sh
# Builds eval/env/.site-venv, the scientific Python the sandbox offers at /opt/site/python, from the pinned versions
# in site-requirements.txt. Run once per machine; it needs network access to pypi.org and no root.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
venv=$here/.site-venv
[ ! -e "$venv" ] || { echo "site-python.sh: $venv exists; remove it to rebuild" >&2; exit 2; }
python3 -m venv "$venv"
"$venv/bin/pip" install -q --disable-pip-version-check -r "$here/site-requirements.txt"
# Scripts such as pip name this host path in their #! line; inside the sandbox the venv is at /opt/site/python.
grep -l "^#!$venv/bin/python" "$venv"/bin/* | xargs sed -i "1s|^#!$venv/bin/python|#!/opt/site/python/bin/python|"
"$venv/bin/python" -c 'import numpy, pandas, sklearn, scipy; print("site python ready:", numpy.__version__, pandas.__version__, sklearn.__version__, scipy.__version__)'
