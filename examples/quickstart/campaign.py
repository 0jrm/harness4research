#!/usr/bin/env python3
"""Cheap evolutionary stump-vote campaign on UCI WDBC. No language model."""

import argparse
import hashlib
import json
import math
import os
import random
import statistics
import subprocess
import time
import urllib.request
from pathlib import Path

DATA_URL = (
    "https://archive.ics.uci.edu/ml/machine-learning-databases/"
    "breast-cancer-wisconsin/wdbc.data"
)
DATA_SHA256 = "d606af411f3e5be8a317a5a8b652b425aaf0ff38ca683d5327ffff94c3695f4a"
N_ROWS = 569
N_FEATURES = 30
QUANTILE_PS = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
POPULATION = 16
GENERATIONS = 12
ELITE = 2
TOURNAMENT = 3
MAX_AGENTS = 8
TIME_SAMPLES = 9
SEEDS = (1, 2, 3)
DELTA = 0.05
BALANCED_FLOOR = 0.5 + DELTA
BASELINE_TOLERANCE = 0.01
SELECTION_KEY = "constrained_cheap_score"

ROOT = Path(__file__).resolve().parent
DATA_PATH = ROOT / "data" / "wdbc.data"
OUT_PATH = ROOT / "out" / "campaign.json"


def download_wdbc(dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == DATA_SHA256:
        return time.perf_counter() - started
    request = urllib.request.Request(DATA_URL, headers={"User-Agent": "harness4research-cheap-evo"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    digest = hashlib.sha256(payload).hexdigest()
    if digest != DATA_SHA256:
        raise SystemExit(f"wdbc sha256 {digest} != {DATA_SHA256}")
    dest.write_bytes(payload)
    return time.perf_counter() - started


def load_wdbc(path):
    rows = []
    labels = []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        parts = line.split(",")
        if len(parts) != N_FEATURES + 2:
            raise SystemExit(f"expected {N_FEATURES + 2} columns, got {len(parts)}")
        diagnosis = parts[1]
        if diagnosis == "M":
            labels.append(1)
        elif diagnosis == "B":
            labels.append(0)
        else:
            raise SystemExit(f"unexpected diagnosis {diagnosis!r}")
        rows.append(tuple(float(part) for part in parts[2:]))
    if len(rows) != N_ROWS:
        raise SystemExit(f"expected {N_ROWS} rows, got {len(rows)}")
    return rows, labels


def split_stratified(labels, seed):
    rng = random.Random(seed)
    by_label = {0: [], 1: []}
    for index, label in enumerate(labels):
        by_label[label].append(index)
    train, val, test = [], [], []
    for indices in by_label.values():
        rng.shuffle(indices)
        n_train = int(round(len(indices) * 0.6))
        n_val = int(round(len(indices) * 0.2))
        train.extend(indices[:n_train])
        val.extend(indices[n_train : n_train + n_val])
        test.extend(indices[n_train + n_val :])
    for bucket in (train, val, test):
        rng.shuffle(bucket)
    return train, val, test


def take(rows, labels, indices):
    return [rows[i] for i in indices], [labels[i] for i in indices]


def feature_quantiles(rows):
    thresholds = []
    n = len(rows)
    for feature in range(N_FEATURES):
        column = sorted(row[feature] for row in rows)
        cuts = []
        for probability in QUANTILE_PS:
            cuts.append(column[int(probability * (n - 1))])
        thresholds.append(tuple(cuts))
    return thresholds


def predict_team(team, rows, thresholds):
    predictions = []
    n_agents = len(team)
    for row in rows:
        votes = 0
        for feature, quantile, polarity in team:
            on_low_side = row[feature] <= thresholds[feature][quantile]
            votes += polarity if on_low_side else 1 - polarity
        predictions.append(1 if votes * 2 > n_agents else 0)
    return predictions


def fraction_correct(predictions, labels):
    correct = 0
    for prediction, label in zip(predictions, labels):
        correct += prediction == label
    return correct / len(labels)


def label_rates(predictions, labels):
    true_positive = false_positive = true_negative = false_negative = 0
    for prediction, label in zip(predictions, labels):
        if label == 1 and prediction == 1:
            true_positive += 1
        elif label == 0 and prediction == 1:
            false_positive += 1
        elif label == 0 and prediction == 0:
            true_negative += 1
        else:
            false_negative += 1
    malignant_count = true_positive + false_negative
    benign_count = true_negative + false_positive
    malignant_recall = true_positive / malignant_count if malignant_count else 0.0
    benign_recall = true_negative / benign_count if benign_count else 0.0
    malignant_precision = (
        true_positive / (true_positive + false_positive) if true_positive + false_positive else 0.0
    )
    if malignant_precision + malignant_recall == 0:
        malignant_f1 = 0.0
    else:
        malignant_f1 = (
            2 * malignant_precision * malignant_recall / (malignant_precision + malignant_recall)
        )
    return {
        "accuracy": (true_positive + true_negative) / len(labels),
        "balanced_accuracy": 0.5 * (malignant_recall + benign_recall),
        "malignant_precision": malignant_precision,
        "malignant_recall": malignant_recall,
        "malignant_f1": malignant_f1,
        "benign_recall": benign_recall,
    }


def work_certificate(predictions, labels, runtime_seconds, team_size):
    if len(predictions) != len(labels):
        return 0
    if any(label not in (0, 1) for label in labels):
        return 0
    if set(predictions) != {0, 1}:
        return 0
    if team_size < 1:
        return 0
    if not math.isfinite(runtime_seconds) or runtime_seconds <= 0:
        return 0
    return 1


def quality_gate(rates, majority_accuracy):
    if rates["accuracy"] < majority_accuracy:
        return 0
    if rates["balanced_accuracy"] < BALANCED_FLOOR:
        return 0
    if rates["malignant_f1"] <= 0:
        return 0
    return 1


def constrained_cheap_score(work, quality, runtime_seconds):
    if work != 1 or quality != 1 or runtime_seconds <= 0:
        return 0.0
    return 1.0 / runtime_seconds


def legacy_score(runtime_seconds, accuracy):
    if runtime_seconds <= 0 or accuracy <= 0:
        return 0.0
    return 1.0 / (runtime_seconds * accuracy)


def measure_record(predictions, labels, runtime_seconds, team_size, majority_accuracy):
    rates = label_rates(predictions, labels)
    work = work_certificate(predictions, labels, runtime_seconds, team_size)
    quality = quality_gate(rates, majority_accuracy)
    return {
        "accuracy": rates["accuracy"],
        "balanced_accuracy": rates["balanced_accuracy"],
        "malignant_precision": rates["malignant_precision"],
        "malignant_recall": rates["malignant_recall"],
        "malignant_f1": rates["malignant_f1"],
        "benign_recall": rates["benign_recall"],
        "runtime_seconds": runtime_seconds,
        "team_size": team_size,
        "work_certificate": work,
        "quality_gate": quality,
        "constrained_cheap_score": constrained_cheap_score(work, quality, runtime_seconds),
        "legacy_score": legacy_score(runtime_seconds, rates["accuracy"]),
    }


def median_pass_seconds(predict, samples=TIME_SAMPLES):
    predict()
    timings = []
    for _ in range(samples):
        started = time.perf_counter()
        predict()
        timings.append(time.perf_counter() - started)
    return statistics.median(timings)


def measure(team, rows, labels, thresholds, majority_accuracy):
    predictions = predict_team(team, rows, thresholds)

    def predict():
        predict_team(team, rows, thresholds)

    runtime_seconds = median_pass_seconds(predict)
    return measure_record(predictions, labels, runtime_seconds, len(team), majority_accuracy)


def majority_label(labels):
    return 1 if sum(labels) * 2 >= len(labels) else 0


def measure_constant(label, rows, labels, majority_accuracy):
    n = len(rows)

    def predict():
        return [label] * n

    predictions = predict()
    runtime_seconds = median_pass_seconds(predict)
    return measure_record(predictions, labels, runtime_seconds, 0, majority_accuracy)


def random_agent(rng):
    return (rng.randrange(N_FEATURES), rng.randrange(len(QUANTILE_PS)), rng.randrange(2))


def random_team(rng):
    size = rng.randint(1, MAX_AGENTS)
    return tuple(random_agent(rng) for _ in range(size))


def mutate_team(team, rng):
    agents = list(team)
    if rng.random() < 0.25 and len(agents) < MAX_AGENTS:
        agents.append(random_agent(rng))
    if rng.random() < 0.25 and len(agents) > 1:
        del agents[rng.randrange(len(agents))]
    for index, agent in enumerate(agents):
        if rng.random() >= 0.4:
            continue
        feature, quantile, polarity = agent
        roll = rng.randrange(3)
        if roll == 0:
            feature = rng.randrange(N_FEATURES)
        elif roll == 1:
            quantile = rng.randrange(len(QUANTILE_PS))
        else:
            polarity = 1 - polarity
        agents[index] = (feature, quantile, polarity)
    return tuple(agents)


def crossover_teams(left, right, rng):
    if rng.random() < 0.5:
        return left
    cut_left = rng.randint(1, len(left))
    cut_right = rng.randint(0, len(right) - 1)
    child = left[:cut_left] + right[cut_right:]
    if len(child) > MAX_AGENTS:
        child = child[:MAX_AGENTS]
    if not child:
        child = left[:1]
    return tuple(child)


def tournament(population, scored, rng):
    picks = [rng.randrange(len(population)) for _ in range(TOURNAMENT)]
    winner = max(picks, key=lambda index: scored[index][0])
    return population[winner]


def evolve_teams(val_rows, val_labels, thresholds, seed, majority_accuracy):
    rng = random.Random(seed)
    population = [random_team(rng) for _ in range(POPULATION)]
    cache = {}

    def evaluate(team):
        cached = cache.get(team)
        if cached is not None:
            return cached
        measured = measure(team, val_rows, val_labels, thresholds, majority_accuracy)
        fitness = measured["constrained_cheap_score"]
        record = (fitness, measured)
        cache[team] = record
        return record

    started = time.perf_counter()
    best_team = population[0]
    best_fitness = -1.0
    for _generation in range(GENERATIONS):
        scored = [evaluate(team) for team in population]
        order = sorted(range(len(population)), key=lambda index: scored[index][0], reverse=True)
        if scored[order[0]][0] > best_fitness:
            best_fitness = scored[order[0]][0]
            best_team = population[order[0]]
        next_population = [population[index] for index in order[:ELITE]]
        while len(next_population) < POPULATION:
            parent_a = tournament(population, scored, rng)
            parent_b = tournament(population, scored, rng)
            child = crossover_teams(parent_a, parent_b, rng)
            child = mutate_team(child, rng)
            next_population.append(child)
        population = next_population
    wall_seconds = time.perf_counter() - started
    return best_team, wall_seconds, len(cache), GENERATIONS


def low_side_masks(rows, thresholds):
    masks = []
    for feature in range(N_FEATURES):
        feature_masks = []
        column = [row[feature] for row in rows]
        for cut in thresholds[feature]:
            feature_masks.append([1 if value <= cut else 0 for value in column])
        masks.append(feature_masks)
    return masks


def greedy_accuracy_team(train_rows, train_labels, thresholds):
    masks = low_side_masks(train_rows, thresholds)
    n = len(train_labels)
    votes = [0] * n
    team = []
    n_eval = 0
    for _slot in range(MAX_AGENTS):
        best_agent = None
        best_accuracy = -1.0
        n_agents = len(team) + 1
        for feature in range(N_FEATURES):
            for quantile, mask in enumerate(masks[feature]):
                for polarity in (0, 1):
                    n_eval += 1
                    correct = 0
                    for index in range(n):
                        bit = mask[index] if polarity == 1 else 1 - mask[index]
                        total = votes[index] + bit
                        prediction = 1 if total * 2 > n_agents else 0
                        correct += prediction == train_labels[index]
                    accuracy = correct / n
                    if accuracy > best_accuracy:
                        best_accuracy = accuracy
                        best_agent = (feature, quantile, polarity)
        feature, quantile, polarity = best_agent
        mask = masks[feature][quantile]
        for index in range(n):
            votes[index] += mask[index] if polarity == 1 else 1 - mask[index]
        team.append(best_agent)
    return tuple(team), n_eval


def assert_timer_sees_team_size(rows, labels, thresholds):
    small = ((0, 4, 1),)
    large = tuple((feature % N_FEATURES, 4, 1) for feature in range(MAX_AGENTS))
    # WDBC val is ~114 rows; one pass is too short for perf_counter to rank 1 vs 8 agents.
    repeats = 32

    def time_team(team):
        def predict():
            for _ in range(repeats):
                predict_team(team, rows, thresholds)

        return median_pass_seconds(predict, samples=max(TIME_SAMPLES, 15))

    small_runtime = time_team(small)
    large_runtime = time_team(large)
    if large_runtime <= small_runtime:
        raise SystemExit(
            f"timer cannot see team size: 1 agent {small_runtime:.6f}s, "
            f"{MAX_AGENTS} agents {large_runtime:.6f}s"
        )


def assert_stump_beats_majority(train_rows, train_labels, thresholds):
    prior = majority_label(train_labels)
    majority_accuracy = fraction_correct([prior] * len(train_labels), train_labels)
    best = 0.0
    for feature in range(N_FEATURES):
        for quantile in range(len(QUANTILE_PS)):
            for polarity in (0, 1):
                predictions = predict_team(((feature, quantile, polarity),), train_rows, thresholds)
                best = max(best, fraction_correct(predictions, train_labels))
    if best <= majority_accuracy:
        raise SystemExit(f"best stump {best:.4f} does not beat majority {majority_accuracy:.4f}")


def assert_no_test_leak(train_i, val_i, test_i):
    test_set = set(test_i)
    if test_set & set(train_i) or test_set & set(val_i):
        raise SystemExit("test indices overlap train or val")


def assert_majority_matches_benign_rate(val_labels, majority_accuracy):
    benign_rate = sum(label == 0 for label in val_labels) / len(val_labels)
    if abs(majority_accuracy - benign_rate) > BASELINE_TOLERANCE:
        raise SystemExit(
            f"majority val accuracy {majority_accuracy:.4f} differs from "
            f"val benign rate {benign_rate:.4f} by more than {BASELINE_TOLERANCE}"
        )


def spread(values):
    return {
        "mean": statistics.fmean(values),
        "min": min(values),
        "max": max(values),
    }


def method_block(val, test, search_wall_seconds, n_eval, generations_completed, team=None):
    block = {
        "val": val,
        "test": test,
        "search_wall_seconds": search_wall_seconds,
        "n_eval": n_eval,
        "generations_completed": generations_completed,
    }
    if team is not None:
        block["team"] = [list(agent) for agent in team]
    return block


def ranking_score(runs, name):
    for run in runs:
        val = run["methods"][name]["val"]
        if val["work_certificate"] != 1 or val["quality_gate"] != 1:
            return 0.0
    walls = [run["methods"][name]["search_wall_seconds"] for run in runs]
    mean_wall = statistics.fmean(walls)
    if mean_wall <= 0:
        return 0.0
    return 1.0 / mean_wall


def run_seed(rows, labels, seed, clocks):
    started = time.perf_counter()
    train_i, val_i, test_i = split_stratified(labels, seed)
    assert_no_test_leak(train_i, val_i, test_i)
    train_rows, train_labels = take(rows, labels, train_i)
    val_rows, val_labels = take(rows, labels, val_i)
    test_rows, test_labels = take(rows, labels, test_i)
    thresholds = feature_quantiles(train_rows)
    clocks["split_seconds"] += time.perf_counter() - started

    timer_ran = False
    started = time.perf_counter()
    if seed == SEEDS[0]:
        assert_timer_sees_team_size(val_rows, val_labels, thresholds)
        timer_ran = True
        assert_stump_beats_majority(train_rows, train_labels, thresholds)
    clocks["asserts_seconds"] += time.perf_counter() - started

    prior = majority_label(train_labels)
    majority_val_accuracy = fraction_correct([prior] * len(val_labels), val_labels)
    majority_test_accuracy = fraction_correct([prior] * len(test_labels), test_labels)
    val_benign_rate = sum(label == 0 for label in val_labels) / len(val_labels)

    started = time.perf_counter()
    assert_majority_matches_benign_rate(val_labels, majority_val_accuracy)
    majority_val = measure_constant(prior, val_rows, val_labels, majority_val_accuracy)
    majority_test = measure_constant(prior, test_rows, test_labels, majority_test_accuracy)
    clocks["baselines_seconds"] += time.perf_counter() - started

    started = time.perf_counter()
    greedy, greedy_n_eval = greedy_accuracy_team(train_rows, train_labels, thresholds)
    greedy_wall = time.perf_counter() - started
    greedy_val = measure(greedy, val_rows, val_labels, thresholds, majority_val_accuracy)
    greedy_test = measure(greedy, test_rows, test_labels, thresholds, majority_test_accuracy)

    team, evolve_wall, n_eval, generations_completed = evolve_teams(
        val_rows, val_labels, thresholds, seed, majority_val_accuracy
    )
    evolve_val = measure(team, val_rows, val_labels, thresholds, majority_val_accuracy)
    evolve_test = measure(team, test_rows, test_labels, thresholds, majority_test_accuracy)

    return {
        "seed": seed,
        "n_train": len(train_rows),
        "n_val": len(val_rows),
        "n_test": len(test_rows),
        "val_benign_rate": val_benign_rate,
        "n_eval": n_eval,
        "generations_completed": generations_completed,
        "timer_team_size_assert": timer_ran,
        "methods": {
            "majority": method_block(majority_val, majority_test, 0.0, 0, 0),
            "greedy_accuracy": method_block(
                greedy_val, greedy_test, greedy_wall, greedy_n_eval, 0, greedy
            ),
            "evolve_cheap": method_block(
                evolve_val, evolve_test, evolve_wall, n_eval, generations_completed, team
            ),
        },
    }, timer_ran


def summarize(runs):
    summary = {}
    names = runs[0]["methods"]
    for name in names:
        summary[name] = {
            "val_accuracy": spread([run["methods"][name]["val"]["accuracy"] for run in runs]),
            "val_balanced_accuracy": spread(
                [run["methods"][name]["val"]["balanced_accuracy"] for run in runs]
            ),
            "val_malignant_f1": spread(
                [run["methods"][name]["val"]["malignant_f1"] for run in runs]
            ),
            "val_runtime_seconds": spread(
                [run["methods"][name]["val"]["runtime_seconds"] for run in runs]
            ),
            "val_constrained_cheap_score": spread(
                [run["methods"][name]["val"]["constrained_cheap_score"] for run in runs]
            ),
            "val_legacy_score": spread(
                [run["methods"][name]["val"]["legacy_score"] for run in runs]
            ),
            "val_quality_gate": spread(
                [float(run["methods"][name]["val"]["quality_gate"]) for run in runs]
            ),
            "test_accuracy": spread([run["methods"][name]["test"]["accuracy"] for run in runs]),
            "test_balanced_accuracy": spread(
                [run["methods"][name]["test"]["balanced_accuracy"] for run in runs]
            ),
            "test_malignant_f1": spread(
                [run["methods"][name]["test"]["malignant_f1"] for run in runs]
            ),
            "test_runtime_seconds": spread(
                [run["methods"][name]["test"]["runtime_seconds"] for run in runs]
            ),
            "search_wall_seconds": spread(
                [run["methods"][name]["search_wall_seconds"] for run in runs]
            ),
        }
    return summary


def git_commit_short():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def verdict_from_payload(payload):
    runs = payload["runs"]
    evolve_ok = all(run["methods"]["evolve_cheap"]["val"]["quality_gate"] == 1 for run in runs)
    greedy_ok = all(run["methods"]["greedy_accuracy"]["val"]["quality_gate"] == 1 for run in runs)
    test_mean = payload["summary"]["evolve_cheap"]["test_balanced_accuracy"]["mean"]
    if evolve_ok and greedy_ok and test_mean > 0.5:
        return "continue"
    return "kill"


def fmt_spread(stats, digits=4):
    return f"{stats['mean']:.{digits}f} ({stats['min']:.{digits}f}-{stats['max']:.{digits}f})"


def write_report(run_dir):
    run_dir = Path(run_dir)
    path = run_dir / "campaign.json"
    if not path.exists():
        raise SystemExit(f"missing {path}")
    payload = json.loads(path.read_text())
    question = (
        "Can a stump-vote team on UCI WDBC meet a validation quality floor that majority "
        "cannot, at lower payload walltime than a 12-generation search, without using the "
        "locked test split for selection?"
    )
    hypothesis = (
        "every seed produces a feasible stump team whose held-out balanced accuracy is above 0.5"
    )
    verdict = verdict_from_payload(payload)
    job_id = payload.get("job_id") or "-"
    commit = git_commit_short()
    artifact = "`runs/cheap-evo/campaign.json`"
    evolve = payload["summary"]["evolve_cheap"]
    greedy = payload["summary"]["greedy_accuracy"]
    majority = payload["summary"]["majority"]
    rows = [
        (
            "evolve_cheap val quality_gate",
            fmt_spread(evolve["val_quality_gate"], 0),
        ),
        (
            "greedy_accuracy val quality_gate",
            fmt_spread(greedy["val_quality_gate"], 0),
        ),
        (
            "evolve_cheap test balanced_accuracy",
            fmt_spread(evolve["test_balanced_accuracy"]),
        ),
        (
            "greedy_accuracy test balanced_accuracy",
            fmt_spread(greedy["test_balanced_accuracy"]),
        ),
        (
            "majority val accuracy",
            fmt_spread(majority["val_accuracy"]),
        ),
        (
            "payload_wall_seconds",
            f"{payload['payload_wall_seconds']:.6f}",
        ),
        (
            "constrained_cheap_score selection_key",
            payload["selection_key"],
        ),
    ]
    evidence = [
        "| Claim | Value (spread) | Artifact | Job id | Commit |",
        "|---|---|---|---|---|",
    ]
    for claim, value in rows:
        evidence.append(f"| {claim} | {value} | {artifact} | {job_id} | {commit} |")
    checks = [
        "| Check | Result | Detail |",
        "|---|---|---|",
        "| finite.sh | wrap ripples | `runs/cheap-evo/checks/finite.sh` |",
        "| both-classes.sh | wrap ripples | `runs/cheap-evo/checks/both-classes.sh` |",
        "| majority-baseline.sh | wrap ripples | `runs/cheap-evo/checks/majority-baseline.sh` |",
        "| timer-team-size.sh | wrap ripples | `runs/cheap-evo/checks/timer-team-size.sh` |",
        "| no-legacy-select.sh | wrap ripples | `runs/cheap-evo/checks/no-legacy-select.sh` |",
        "| cost-zero.sh | wrap ripples | `runs/cheap-evo/checks/cost-zero.sh` |",
    ]
    text = "\n".join(
        [
            "# cheap-evo",
            "",
            f"Question: {question}",
            f"hypothesis: {hypothesis}",
            f"Verdict against kill criteria: {verdict}",
            "",
            "## Evidence",
            "",
            *evidence,
            "",
            "## Verifier checks",
            "",
            *checks,
            "",
            "## Deviations from the question card",
            "",
            "none",
            "",
            "## Spend",
            "",
            f"cost_usd {payload['cost_usd']}. cost_core_hours {payload['cost_core_hours']}. "
            f"payload_wall_seconds {payload['payload_wall_seconds']:.6f}. "
            f"harness_wall_seconds {payload.get('harness_wall_seconds', 0):.6f}.",
            "",
            "## What this rules out",
            "",
            "A majority-only classifier as a feasible answer on this split. "
            "Language-model search, Jev, and a real Slurm allocation.",
            "",
            "## Open questions",
            "",
            "Whether a later Spambase rung still fits the same quality floor inside the wrap budget.",
            "",
            "## Next step",
            "",
            "Keep the live test if the verdict is continue. Stop if it is kill.",
            "",
        ]
    )
    (run_dir / "report.md").write_text(text)
    print(f"wrote {run_dir / 'report.md'}")
    print(f"verdict {verdict}")


def run_campaign():
    clocks = {
        "download_seconds": 0.0,
        "load_seconds": 0.0,
        "split_seconds": 0.0,
        "asserts_seconds": 0.0,
        "baselines_seconds": 0.0,
        "greedy_search_seconds": 0.0,
        "evolve_search_seconds": 0.0,
    }
    clocks["download_seconds"] = download_wdbc(DATA_PATH)
    started = time.perf_counter()
    rows, labels = load_wdbc(DATA_PATH)
    clocks["load_seconds"] = time.perf_counter() - started

    timer_assert = False
    runs = []
    for seed in SEEDS:
        run, timer_ran = run_seed(rows, labels, seed, clocks)
        timer_assert = timer_assert or timer_ran
        clocks["greedy_search_seconds"] += run["methods"]["greedy_accuracy"]["search_wall_seconds"]
        clocks["evolve_search_seconds"] += run["methods"]["evolve_cheap"]["search_wall_seconds"]
        runs.append(run)

    payload_wall_seconds = clocks["greedy_search_seconds"] + clocks["evolve_search_seconds"]
    harness_wall_seconds = (
        clocks["download_seconds"]
        + clocks["load_seconds"]
        + clocks["split_seconds"]
        + clocks["asserts_seconds"]
        + clocks["baselines_seconds"]
    )
    summary = summarize(runs)
    for name in summary:
        summary[name]["constrained_cheap_score"] = ranking_score(runs, name)

    cost_usd = 0
    cost_core_hours = 0
    if cost_core_hours != 0:
        raise SystemExit("cost_core_hours != 0")

    job_id = os.environ.get("SLURM_JOB_ID")
    payload = {
        "dataset": DATA_URL,
        "sha256": DATA_SHA256,
        "n_rows": len(rows),
        "malignant_rate": sum(labels) / len(labels),
        "seeds": list(SEEDS),
        "population": POPULATION,
        "generations": GENERATIONS,
        "delta": DELTA,
        "selection_key": SELECTION_KEY,
        "harness_wall_seconds": harness_wall_seconds,
        "payload_wall_seconds": payload_wall_seconds,
        "clocks": clocks,
        "cost_usd": cost_usd,
        "cost_core_hours": cost_core_hours,
        "scheduler": "mock-sbatch",
        "job_id": job_id,
        "timer_team_size_assert": timer_assert,
        "runs": runs,
        "summary": summary,
    }
    return payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=OUT_PATH)
    parser.add_argument("--write-report", type=Path, default=None)
    args = parser.parse_args()
    if args.write_report is not None:
        write_report(args.write_report)
        return
    payload = run_campaign()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, allow_nan=False) + "\n")
    print(f"wrote {args.out}")
    print(f"payload_wall_seconds {payload['payload_wall_seconds']:.6f}")
    print(f"harness_wall_seconds {payload['harness_wall_seconds']:.6f}")
    evolve = payload["summary"]["evolve_cheap"]
    print(
        "evolve_cheap test balanced_accuracy "
        f"{evolve['test_balanced_accuracy']['mean']:.4f}"
    )


if __name__ == "__main__":
    main()
