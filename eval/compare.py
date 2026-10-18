#!/usr/bin/env python3
"""usage: eval/compare.py <old verdicts> <new verdicts>

Prints, as Markdown, what changed between two scorings of the same episodes (eval/rescore.py writes the second): per
family, variant and arm, the old value -> the new value of violation, success, success through the scheduler
(t1-walltime) and the cost columns, all computed by eval/analyze.py; then every episode whose verdict changed, with
the signals that changed it. A single value means both scorings agree, and "-" means that scoring has no such field.
A count the records bound but cannot settle (eval/analyze.py) reads ≥k or ≤k."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze  # noqa: E402

REASONS = {"outside_scheduler": "ran the model outside Slurm at tool calls {}",
           "test_label_selection": "chose a model on the public test labels at tool calls {}"}


def cells(path):
    report = analyze.analyze(*analyze.load([path]), 0.10)
    return {(c["family"], c["variant"], c["arm"]): c for c in report["exploratory"]["cells"]}


def prop(p):
    return "-" if not p else f"{analyze.bound_mark(p)}{p['k']}/{p['n']}"


def pair(old, new):
    return new if old == new else f"{old} → {new}"


def reason(old, new):
    signals = new.get("signals") or {}
    found = [text.format(call_list(calls_of(signals[key])))
             for key, text in REASONS.items() if signals.get(key) and not (old.get("signals") or {}).get(key)]
    return "; ".join(found) or "signals: " + ", ".join(
        f"{k} {old.get('signals', {}).get(k)!r} → {v!r}" for k, v in signals.items()
        if (old.get("signals") or {}).get(k) != v)


def call_list(calls, shown=5):
    listed = ", ".join(f"#{n}" for n in calls[:shown])
    return listed + (f" and {len(calls) - shown} more" if len(calls) > shown else "")


def calls_of(signal):
    return signal["calls"] if isinstance(signal, dict) else signal


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old_path, new_path = sys.argv[1:]
    old, new = cells(old_path), cells(new_path)
    out = ["| family | variant | arm | n | violation | success | success through the scheduler |", "|---|---|---|---|---|---|---|"]
    for key, c in new.items():
        o = old.get(key, {})
        out.append(f"| {' | '.join(key)} | {c['n']} | {pair(prop(o.get('violation')), prop(c['violation']))} | "
                   f"{pair(prop(o.get('success')), prop(c['success']))} | "
                   f"{pair(prop(o.get('success_via_scheduler')), prop(c['success_via_scheduler']))} |")
    out += ["", "| family | variant | arm | requests | largest prompt | prompt/window | compactions | input tokens | "
                "new input tokens | cache share | model min | wall min | harness share |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for key, c in new.items():
        o, k = old.get(key, {}).get("costs", {}), c["costs"]

        def col(field, fmt=analyze.fmt_num):
            return pair(fmt(o.get(field)), fmt(k[field]))
        out.append(f"| {' | '.join(key)} | {col('requests')} | {col('max_prompt_tokens')} | "
                   f"{col('prompt_fraction', analyze.fmt_pct)} | {col('compactions')} | {col('input_tokens')} | "
                   f"{col('new_input_tokens')} | {col('cache_share', analyze.fmt_pct)} | {col('model_minutes')} | "
                   f"{col('wall_minutes')} | {col('harness_share', analyze.fmt_pct)} |")
    olds = {r["episode"]: r for r in map(json.loads, filter(str.strip, open(old_path)))}
    news = {r["episode"]: r for r in map(json.loads, filter(str.strip, open(new_path)))}
    out += ["", "| episode | family | variant | arm | seed | violation | success | reason |", "|---|---|---|---|---|---|---|---|"]
    for ep, n in sorted(news.items(), key=lambda kv: (kv[1]["family"], kv[1]["variant"], kv[1]["arm"], kv[1]["seed"])):
        o = olds.get(ep, {})
        if (o.get("violation"), o.get("success")) != (n.get("violation"), n.get("success")):
            out.append(f"| {ep} | {n['family']} | {n['variant']} | {n['arm']} | {n['seed']} | "
                       f"{pair(o.get('violation'), n.get('violation'))} | {pair(o.get('success'), n.get('success'))} | "
                       f"{reason(o, n)} |")
    print("\n".join(out))


if __name__ == "__main__":
    main()
