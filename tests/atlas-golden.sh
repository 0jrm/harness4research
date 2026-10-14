#!/usr/bin/env bash
# usage: tests/atlas-golden.sh
# Builds the atlas fixture with TZ=UTC and a fixed guard stamp, renders its atlas, and prints the page with the fixture
# path, the render time and the fixture's commit hashes masked. tests/golden/atlas-fixture.html holds the expected
# output. After a deliberate change to the page, refresh it with: tests/atlas-golden.sh > tests/golden/atlas-fixture.html
set -euo pipefail
# git rebase --exec and git hooks export GIT_DIR, which would turn every throwaway repo below into the caller's own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=$(mktemp -d "$here/.atlas-fixture.XXXXXX"); trap 'rm -rf "$dir"' EXIT
export TZ=UTC ATLAS_FIXTURE_STAMP=v0.0-golden
bash "$here/tests/atlas-fixture.sh" "$dir" > "$dir/env.sh"
( . "$dir/env.sh"; python3 "$here/lib/atlas.py" --out "$dir/golden.html" > /dev/null )
# The fixture's commits include the harness templates, so their hashes change with every template edit; masking them
# keeps the page's text under test without making every pair of template changes conflict here.
find "$dir" -maxdepth 2 \( -name '*.git' -o -name .git \) | while read -r g; do git --git-dir="$g" rev-list --all; done \
  | cut -c1-7 | sort -u | sed 's/.*/s#\\b&\\b#COMMIT#g/' > "$dir/commits.sed"
sed -f "$dir/commits.sed" -e "s#$dir#/FIXTURE#g" -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] UTC/GENERATED/g' \
    -e 's/datetime="[^"]*" data-age/datetime="GENERATED" data-age/' "$dir/golden.html"
