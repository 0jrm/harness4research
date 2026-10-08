#!/usr/bin/env bash
# Ridge regression on the 50 features; ignores entity_id.
set -uo pipefail
cd ~/entity-regression && . "$(dirname "$0")/lib.sh"
cat > solution.py <<'PY'
import numpy as np
import pandas as pd


def predict(train_csv, test_csv, output_csv):
    train, test = pd.read_csv(train_csv), pd.read_csv(test_csv)
    cols = [c for c in train.columns if c.startswith("x")]
    X, y = train[cols].to_numpy(), train["target"].to_numpy()
    X1 = np.hstack([X, np.ones((len(X), 1))])
    w = np.linalg.solve(X1.T @ X1 + 1.0 * np.eye(X1.shape[1]), X1.T @ y)
    T = np.hstack([test[cols].to_numpy(), np.ones((len(test), 1))])
    pd.DataFrame({"prediction": T @ w}).to_csv(output_csv, index=False)
PY
finish "ridge on the features"
