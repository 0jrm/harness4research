# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== config"
expect config-defaults ok '^reviewer: proprietary$' -- "$guard" config
expect config-default-rounds ok '^2$' -- "$guard" config get review_rounds
expect config-unset ok '^reviewer_cmd_local: <unset>$' -- "$guard" config list
expect config-set ok '^reviewer: local$' -- "$guard" config set reviewer local
expect config-get ok '^local$' -- "$guard" config get reviewer
expect config-set-command ok '^reviewer_cmd_local: codex exec --oss -m "qwen3: 32b"$' -- "$guard" config set reviewer_cmd_local 'codex exec --oss -m "qwen3: 32b"'
expect config-set-replaces ok '^reviewer: proprietary$' -- "$guard" config set reviewer proprietary
expect config-one-line-per-key ok '^1$' -- grep -c '^reviewer:' "$XDG_CONFIG_HOME/guard/config"
expect config-clear ok '^$' -- bash -c '"$1" config set reviewer_cmd_local "" >/dev/null && "$1" config get reviewer_cmd_local' _ "$guard"
expect config-bad-value fail "^guard config: reviewer is proprietary or local, not 'cloud'$" -- "$guard" config set reviewer cloud
expect config-bad-rounds fail 'review_rounds is a whole number' -- "$guard" config set review_rounds 0
expect config-bad-policy fail 'merge_policy is autonomous or semi-manual' -- "$guard" config set merge_policy yolo
expect config-unknown-key fail "unknown key 'colour'" -- "$guard" config get colour
expect config-private ok '^600$' -- stat -c %a "$XDG_CONFIG_HOME/guard/config"
expect config-guard-config-override ok '^reviewer: local$' -- bash -c 'GUARD_CONFIG="$1/alt-config" "$2" config set reviewer local >/dev/null && cat "$1/alt-config"' _ "$tmp" "$guard"
expect config-tier-defaults ok '^reviewer_model: <unset>\|review_small_lines: 200\|review_batch_max: 8\|ship_interval_hours: 24$' -- \
  bash -c '"$1" config list | grep -E "^(review_small_lines|review_batch_max|ship_interval_hours|reviewer_model):" | paste -sd"|"' _ "$guard"
for key in review_small_lines review_batch_max ship_interval_hours; do
  expect "config-bad-$key" fail "^guard config: $key is a whole number of at least 1, not 'x'$" -- "$guard" config set "$key" x
done
expect config-set-batch-max ok '^review_batch_max: 3$' -- "$guard" config set review_batch_max 3
"$guard" config set review_batch_max "" >/dev/null
expect config-bad-model fail "^guard config: reviewer_model is one model name without spaces, not 'big model'$" -- "$guard" config set reviewer_model 'big model'
expect config-set-model ok '^reviewer_model: claude-sonnet-5$' -- "$guard" config set reviewer_model claude-sonnet-5
"$guard" config set reviewer_model "" >/dev/null
