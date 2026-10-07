#!/usr/bin/env bash
# usage: tests/atlas-golden.sh
# Builds the atlas fixture with TZ=UTC and a fixed guard stamp, renders its atlas, and prints the page with the fixture
# path and the render time masked. tests/golden/atlas-fixture.html holds the expected output. After a deliberate change
# to the page, refresh it with: tests/atlas-golden.sh > tests/golden/atlas-fixture.html
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=$(mktemp -d "$here/.atlas-fixture.XXXXXX"); trap 'rm -rf "$dir"' EXIT
export TZ=UTC ATLAS_FIXTURE_STAMP=v0.0-golden
bash "$here/tests/atlas-fixture.sh" "$dir" > "$dir/env.sh"
( . "$dir/env.sh"; python3 "$here/lib/atlas.py" --out "$dir/golden.html" > /dev/null )
sed -e "s#$dir#/FIXTURE#g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] UTC/GENERATED/g' \
    -e 's/datetime="[^"]*" data-age/datetime="GENERATED" data-age/' "$dir/golden.html"
