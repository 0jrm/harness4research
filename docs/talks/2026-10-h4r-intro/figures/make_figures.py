"""Figures and slide numbers for the harness4research intro talk.

Reads the verdict rows in ../data/raw and writes figures/*.png plus data/numbers.json,
which build.js reads, so every number on a slide comes from a verdict file.

Run: <venv with matplotlib>/bin/python figures/make_figures.py
"""

import json
import math
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
RAW = HERE.parent / "data" / "raw"

INK = "#1B2A3A"
MUTED = "#6B7785"
GRID = "#E3E7EC"
NO_HARNESS = "#9AA5B1"
HARNESS = "#1F7A8C"
APPROVER = "#E9A23B"

FAMILIES = [
    ("t1-walltime", "Walltime"),
    ("t8-fixture", "Broken\nfixture"),
    ("t3-entity-overlap", "Leaky\nsplit"),
]

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 16,
    "axes.edgecolor": MUTED,
    "axes.labelcolor": INK,
    "xtick.color": INK,
    "ytick.color": INK,
    "axes.spines.top": False,
    "axes.spines.right": False,
})


def load(name):
    return [json.loads(line) for line in open(RAW / f"{name}.jsonl")]


def wilson(k, n, z=1.959964):
    if n == 0:
        return (0.0, 0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (p, max(0.0, c - h), min(1.0, c + h))


def newcombe(k1, n1, k2, n2):
    """Difference p1 - p2 with Newcombe's method 10 interval."""
    p1, l1, u1 = wilson(k1, n1)
    p2, l2, u2 = wilson(k2, n2)
    d = p1 - p2
    lo = d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2)
    hi = d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)
    return (d, lo, hi)


def scored(rows):
    return [r for r in rows if r.get("violation") is not None and not r.get("extra")]


def tally(rows, metric, **where):
    sel = [r for r in rows if all(r[k] == v for k, v in where.items())]
    return sum(bool(r[metric]) for r in sel), len(sel)


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def rate_bars(ax, groups, colors, labels, title, ylabel):
    """groups: list of (xlabel, [(k, n), ...]) one (k, n) per series."""
    width = 0.8 / len(labels)
    for gi, (_, series) in enumerate(groups):
        for si, (k, n) in enumerate(series):
            if n == 0:
                continue
            p, lo, hi = wilson(k, n)
            x = gi + (si - (len(labels) - 1) / 2) * width
            ax.bar(x, p * 100, width * 0.92, color=colors[si],
                   label=labels[si] if gi == 0 else None)
            ax.errorbar(x, p * 100, yerr=[[max(0.0, p - lo) * 100], [max(0.0, hi - p) * 100]],
                        color=INK, capsize=4, lw=1.3)
            ax.text(x, hi * 100 + 2.5, f"{k}/{n}", ha="center", va="bottom",
                    fontsize=14, color=INK)
    ax.set_xticks(range(len(groups)), [g for g, _ in groups])
    ax.set_ylim(0, 118)
    ax.set_yticks([0, 25, 50, 75, 100])
    ax.set_ylabel(ylabel)
    ax.yaxis.grid(True, color=GRID)
    ax.set_axisbelow(True)
    ax.set_title(title, loc="left", fontsize=16, color=INK, fontweight="bold")


def save(fig, name):
    fig.savefig(HERE / name, dpi=200, bbox_inches="tight", transparent=False,
                facecolor="white")
    plt.close(fig)


def headline(oct_rows, numbers):
    va = tally(oct_rows, "violation", arm="A", variant="trap")
    ve = tally(oct_rows, "violation", arm="E", variant="trap")
    sa = tally(oct_rows, "success", arm="A", variant="control")
    se = tally(oct_rows, "success", arm="E", variant="control")
    fig, axes = plt.subplots(1, 2, figsize=(10, 5.0))
    rate_bars(axes[0], [("No harness", [va]), ("Harness", [ve])],
              [NO_HARNESS], ["x"], "Rule broken on traps  (lower is better)",
              "% of episodes")
    for patch in axes[0].patches[1:]:
        patch.set_color(HARNESS)
    rate_bars(axes[1], [("No harness", [sa]), ("Harness", [se])],
              [NO_HARNESS], ["x"], "Task done on controls  (higher is better)",
              "% of episodes")
    for patch in axes[1].patches[1:]:
        patch.set_color(HARNESS)
    fig.tight_layout(w_pad=3)
    save(fig, "october-headline.png")
    numbers["oct"] = {
        "viol_A": va, "viol_E": ve, "succ_A": sa, "succ_E": se,
        "viol_diff": newcombe(ve[0], ve[1], va[0], va[1]),
        "succ_diff": newcombe(se[0], se[1], sa[0], sa[1]),
    }


def per_family(oct_rows, res_rows, numbers):
    fig, axes = plt.subplots(1, 2, figsize=(11, 5.0), sharey=True)
    out = {}
    for ax, rows, title in [(axes[0], oct_rows, "October scoring"),
                            (axes[1], res_rows, "Stricter re-score")]:
        groups = []
        for fam, label in FAMILIES:
            a = tally(rows, "violation", arm="A", variant="trap", family=fam)
            e = tally(rows, "violation", arm="E", variant="trap", family=fam)
            groups.append((label, [a, e]))
            out.setdefault(fam, {})[title] = {"A": a, "E": e}
        rate_bars(ax, groups, [NO_HARNESS, HARNESS], ["No harness", "Harness"],
                  title, "% of trap episodes breaking a rule" if ax is axes[0] else "")
    axes[0].legend(frameon=False, loc="upper left", fontsize=13)
    fig.tight_layout(w_pad=2)
    save(fig, "per-family-violations.png")
    numbers["per_family"] = out
    # Control-side rule breaks the re-score found, for the notes.
    numbers["rescore_controls"] = {
        fam: {arm: tally(res_rows, "violation", arm=arm, variant="control", family=fam)
              for arm in ("A", "E")}
        for fam, _ in FAMILIES
    }
    numbers["rescore"] = {
        "viol_A": tally(res_rows, "violation", arm="A", variant="trap"),
        "viol_E": tally(res_rows, "violation", arm="E", variant="trap"),
    }
    numbers["rescore"]["viol_diff"] = newcombe(*numbers["rescore"]["viol_E"],
                                               *numbers["rescore"]["viol_A"])


def cost(res_rows, v8_rows, numbers):
    """Median model requests per episode, harness arm, v7 (October, re-scored rows) vs v8."""
    fig, axes = plt.subplots(1, 2, figsize=(11, 5.0))
    out = {}
    for ax, metric, title, fmt in [
        (axes[0], "requests", "Requests per episode (median)", "{:.0f}"),
        (axes[1], "prompt_share", "Largest prompt, % of window (median)", "{:.0f}%"),
    ]:
        groups = []
        for fam, label in FAMILIES:
            vals = []
            for rows in (res_rows, v8_rows):
                sel = [r for r in rows if r["arm"] == "E" and r["family"] == fam]
                if metric == "requests":
                    vals.append(median([r["requests"] for r in sel]))
                else:
                    vals.append(median([100 * r["max_prompt_tokens"] / r["context_window"]
                                        for r in sel]))
            groups.append((label, vals))
            out.setdefault(fam, {})[metric] = vals
        width = 0.38
        for gi, (_, vals) in enumerate(groups):
            for si, (v, color) in enumerate(zip(vals, [NO_HARNESS, HARNESS])):
                x = gi + (si - 0.5) * width
                ax.bar(x, v, width * 0.92, color=color,
                       label=["Harness v7 (October)", "Harness v8 (interim)"][si] if gi == 0 else None)
                ax.text(x, v * 1.02, fmt.format(math.floor(v + 0.5)), ha="center", va="bottom", fontsize=14)
        ax.set_xticks(range(len(groups)), [g for g, _ in groups])
        ax.yaxis.grid(True, color=GRID)
        ax.set_axisbelow(True)
        ax.set_title(title, loc="left", fontsize=16, color=INK, fontweight="bold")
        ax.margins(y=0.15)
    axes[0].legend(frameon=False, loc="upper left", fontsize=13)
    fig.tight_layout(w_pad=3)
    save(fig, "cost-v7-v8.png")
    numbers["cost"] = out
    # Episode counts behind each v8 median, for the slide caption.
    numbers["cost_n_v8"] = {fam: sum(1 for r in v8_rows if r["arm"] == "E" and r["family"] == fam)
                            for fam, _ in FAMILIES}


def v8_interim(v8_all, v8_rows, numbers):
    arms = [("A", NO_HARNESS, "No harness"), ("E", HARNESS, "Harness v8"),
            ("E-approver", APPROVER, "Harness v8 + slow approver")]
    fig, axes = plt.subplots(1, 2, figsize=(11, 5.4))
    for ax, variant, metric, title, ylabel in [
        (axes[0], "trap", "violation", "Rule broken on traps  (lower is better)", "% of episodes"),
        (axes[1], "control", "success", "Task done on controls  (higher is better)", ""),
    ]:
        groups = []
        for fam, label in FAMILIES:
            groups.append((label, [tally(v8_rows, metric, arm=a, variant=variant, family=fam)
                                   for a, _, _ in arms]))
        rate_bars(ax, groups, [c for _, c, _ in arms], [l for _, _, l in arms], title, ylabel)
    fig.tight_layout(w_pad=2, rect=(0, 0.08, 1, 1))
    fig.legend(*axes[0].get_legend_handles_labels(), loc="lower center", ncol=3,
               frameon=False, fontsize=14)
    save(fig, "v8-interim.png")
    numbers["v8"] = {
        "rows": len(v8_all),
        "scored": len(v8_rows),
        "planned": 181,
        "viol": {a: tally(v8_rows, "violation", arm=a, variant="trap") for a, _, _ in arms},
        "succ": {a: tally(v8_rows, "success", arm=a, variant="control") for a, _, _ in arms},
    }
    v = numbers["v8"]
    v["viol_diff"] = newcombe(*v["viol"]["E"], *v["viol"]["A"])
    v["succ_diff"] = newcombe(*v["succ"]["E"], *v["succ"]["A"])
    dead = [r for r in v8_all if r["arm"] == "E-deadlock"]
    v["deadlock"] = [{k: r[k] for k in ("requests", "wall_seconds", "violation", "success")}
                     | {"jobs": r["signals"].get("jobs")} for r in dead]


def main():
    oct_rows = scored(load("october-verdicts"))
    res_rows = scored(load("october-rescored-verdicts"))
    v8_all = load("v8-partial-verdicts")
    v8_rows = scored(v8_all)
    numbers = {}
    headline(oct_rows, numbers)
    per_family(oct_rows, res_rows, numbers)
    cost(res_rows, v8_rows, numbers)
    v8_interim(v8_all, v8_rows, numbers)
    (HERE.parent / "data" / "numbers.json").write_text(json.dumps(numbers, indent=1) + "\n")
    print(json.dumps(numbers, indent=1))


if __name__ == "__main__":
    main()
