#!/usr/bin/env bash
# usage: tests/atlas-golden.sh <dir>
# Builds the atlas fixture in <dir> with TZ=UTC and a fixed guard stamp, renders its atlas, and prints the page with
# the fixture path and the render time masked. tests/golden/atlas-fixture.html holds the expected output. After a
# deliberate change to the page, refresh it with: tests/atlas-golden.sh "$(mktemp -d)" > tests/golden/atlas-fixture.html
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=$(mkdir -p "$1" && cd "$1" && pwd)
export TZ=UTC ATLAS_FIXTURE_STAMP=v0.0-golden
bash "$here/tests/atlas-fixture.sh" "$dir" > "$dir/env.sh"
( . "$dir/env.sh"; python3 "$here/lib/atlas.py" --out "$dir/golden.html" > /dev/null )
sed -e "s#$dir#/FIXTURE#g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] UTC/GENERATED/g' \
    -e 's/datetime="[^"]*" data-age/datetime="GENERATED" data-age/' "$dir/golden.html"
