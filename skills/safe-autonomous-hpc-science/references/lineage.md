# Question lineage

Read this before you write a question card, to set `supersedes` and `spawned_from`.

Copy `runs/_template/question.card` to `runs/<run_id>/question.card`. When the card replaces an earlier run, set `supersedes` to that run id; when it grows out of one, set `spawned_from`. Otherwise write `none`, since the card freezes at its first commit. The atlas draws the question map from these two keys.
