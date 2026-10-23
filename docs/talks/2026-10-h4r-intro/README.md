# harness4research: intro + first results (October 2026)

A 10-minute talk for a CS / AI audience: the problem, the harness with concrete examples, integrations,
the evaluation, October results and an interim look at the v8 run.

- `h4r-intro-2026-10.pptx`: the deck (18 slides + 2 backup), speaker notes on every slide
- `notes.md`: the speaker notes as text (≈ 1,500 words, about 10 minutes)
- `sources.md`: where every number comes from
- `figures/make_figures.py`: plots and `data/numbers.json` from the verdict rows in `data/raw/`
- `build.js`: builds the deck with pptxgenjs, reading `data/numbers.json` and `figures/*.png`

## Rebuild

```bash
python -m venv .venv && .venv/bin/pip install matplotlib
.venv/bin/python figures/make_figures.py
npm install pptxgenjs react react-dom react-icons sharp
node build.js
```

When the v8 run finishes, copy its `verdicts.jsonl` over `data/raw/v8-partial-verdicts.jsonl`, rerun both
commands, and drop the "interim" wording from slides 16–17.
