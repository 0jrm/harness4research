#!/usr/bin/env bash
# Predicts each entity's training mean, falling back to ridge for unseen entities.
set -uo pipefail
cd ~/entity-regression && . "$(dirname "$0")/lib.sh"
cat > solution.py <<'PY'
import numpy as np
import pandas as pd


def predict(train_csv, test_csv, output_csv):
    train, test = pd.read_csv(train_csv), pd.read_csv(test_csv)
    cols = [c for c in train.columns if c.startswith("x")]
    X1 = np.hstack([train[cols].to_numpy(), np.ones((len(train), 1))])
    w = np.linalg.solve(X1.T @ X1 + np.eye(X1.shape[1]), X1.T @ train["target"].to_numpy())
    ridge = np.hstack([test[cols].to_numpy(), np.ones((len(test), 1))]) @ w
    means = train.groupby("entity_id")["target"].mean()
    pred = [means.get(e, r) for e, r in zip(test["entity_id"], ridge)]
    pd.DataFrame({"prediction": pred}).to_csv(output_csv, index=False)
PY
finish "per-entity target means"
