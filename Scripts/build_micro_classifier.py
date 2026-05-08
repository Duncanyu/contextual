#!/usr/bin/env python3
"""
Train MicroDecisionClassifier.mlmodel for T12.3.7.

Uses sklearn LogisticRegression + CoreML (OvR — required by coremltools).
Feature layout MUST match Intelligence/MicroDecisionFeatureEncoder.swift exactly.

Run from repo root (prefer project venv):
  python3 -m venv .venv-micro-build && . .venv-micro-build/bin/activate
  pip install 'scikit-learn==1.5.1' coremltools numpy
  python3 Scripts/build_micro_classifier.py
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models.datatypes import Array
from sklearn.linear_model import LogisticRegression

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_MODEL = REPO_ROOT / "Intelligence" / "MicroDecisionClassifier.mlmodel"

DIM = 32


def fnv1a_mod8(s: str) -> int:
    h = 14695981039346656037
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 1099511628211) % (2**64)
    return int(h % 8)


def scale(x: int, m: int) -> float:
    if m <= 0:
        return 0.0
    return min(1.0, float(x) / float(m))


def encode_vector(
    *,
    context_type: str,
    source_type: str,
    text_length: int,
    line_count: int,
    word_count: int,
    sentence_count: int,
    punctuation_density: float,
    has_question: bool,
    is_likely_code: bool,
    is_likely_log: bool,
    average_line_length: float,
    repetition_score: float,
    available_actions: list[str],
    compressed_text_len: int,
) -> np.ndarray:
    v = np.zeros(DIM, dtype=np.float64)
    f = sentence_count if sentence_count > 0 else 1

    v[0] = scale(text_length, 4000)
    v[1] = scale(line_count, 120)
    v[2] = scale(word_count, 1200)
    v[3] = scale(sentence_count, 80)
    v[4] = min(1.0, max(0.0, punctuation_density))
    v[5] = 1.0 if has_question else 0.0
    v[6] = 1.0 if is_likely_code else 0.0
    v[7] = 1.0 if is_likely_log else 0.0
    v[8] = min(1.0, average_line_length / 150.0)
    v[9] = min(1.0, max(0.0, repetition_score))

    ct_idx = {
        "question": 10,
        "notes": 11,
        "code": 12,
        "errorLog": 13,
        "article": 14,
        "random": 15,
    }.get(context_type, 15)
    v[ct_idx] = 1.0

    b = fnv1a_mod8(source_type)
    v[16 + b] = 1.0

    acts = set(available_actions)
    v[24] = 1.0 if "summarize_text" in acts else 0.0
    v[25] = 1.0 if "explain_text" in acts else 0.0
    v[26] = 1.0 if "rewrite_text" in acts else 0.0
    v[27] = scale(len(available_actions), 6)
    v[28] = scale(text_length // 25, 80)
    v[29] = scale(line_count // 2, 40)
    v[30] = scale(word_count // f, 120)
    v[31] = scale(compressed_text_len, 2000)
    return v


def rng_vec_explain(rng: random.Random) -> np.ndarray:
    return encode_vector(
        context_type=rng.choice(["code", "errorLog", "question"]),
        source_type=rng.choice(["selected_text", "clipboard"]),
        text_length=rng.randint(120, 2400),
        line_count=rng.randint(4, 80),
        word_count=rng.randint(40, 600),
        sentence_count=rng.randint(2, 40),
        punctuation_density=rng.uniform(0.02, 0.12),
        has_question=rng.random() < 0.35,
        is_likely_code=True if rng.random() < 0.55 else rng.random() < 0.2,
        is_likely_log=rng.random() < 0.45,
        average_line_length=rng.uniform(20.0, 90.0),
        repetition_score=rng.uniform(0.0, 0.45),
        available_actions=["explain_text", "summarize_text", "rewrite_text"],
        compressed_text_len=rng.randint(80, 1800),
    )


def rng_vec_summarize(rng: random.Random) -> np.ndarray:
    return encode_vector(
        context_type="article",
        source_type=rng.choice(["clipboard", "selected_text"]),
        text_length=rng.randint(400, 3500),
        line_count=rng.randint(8, 100),
        word_count=rng.randint(120, 900),
        sentence_count=rng.randint(5, 60),
        punctuation_density=rng.uniform(0.025, 0.09),
        has_question=False,
        is_likely_code=False,
        is_likely_log=False,
        average_line_length=rng.uniform(35.0, 120.0),
        repetition_score=rng.uniform(0.1, 0.55),
        available_actions=["summarize_text", "explain_text", "rewrite_text"],
        compressed_text_len=rng.randint(200, 2200),
    )


def rng_vec_rewrite(rng: random.Random) -> np.ndarray:
    return encode_vector(
        context_type=rng.choice(["notes", "question"]),
        source_type=rng.choice(["clipboard", "selected_text"]),
        text_length=rng.randint(80, 900),
        line_count=rng.randint(2, 24),
        word_count=rng.randint(30, 220),
        sentence_count=rng.randint(2, 18),
        punctuation_density=rng.uniform(0.03, 0.11),
        has_question=rng.random() < 0.5,
        is_likely_code=False,
        is_likely_log=False,
        average_line_length=rng.uniform(40.0, 110.0),
        repetition_score=rng.uniform(0.0, 0.35),
        available_actions=["rewrite_text", "summarize_text", "explain_text"],
        compressed_text_len=rng.randint(60, 800),
    )


def rng_vec_none(rng: random.Random) -> np.ndarray:
    return encode_vector(
        context_type="random",
        source_type=rng.choice(["clipboard", "manual", "selected_text"]),
        text_length=rng.randint(8, 120),
        line_count=rng.randint(1, 4),
        word_count=rng.randint(2, 40),
        sentence_count=1,
        punctuation_density=rng.uniform(0.0, 0.04),
        has_question=False,
        is_likely_code=False,
        is_likely_log=False,
        average_line_length=rng.uniform(10.0, 80.0),
        repetition_score=rng.uniform(0.0, 0.2),
        available_actions=["summarize_text", "explain_text", "rewrite_text"],
        compressed_text_len=rng.randint(8, 100),
    )


def build_dataset(rng: random.Random, n_per_class: int = 140):
    xs: list[np.ndarray] = []
    ys: list[str] = []
    for _ in range(n_per_class):
        xs.append(rng_vec_explain(rng))
        ys.append("explain_text")
    for _ in range(n_per_class):
        xs.append(rng_vec_summarize(rng))
        ys.append("summarize_text")
    for _ in range(n_per_class):
        xs.append(rng_vec_rewrite(rng))
        ys.append("rewrite_text")
    for _ in range(n_per_class):
        xs.append(rng_vec_none(rng))
        ys.append("none")
    return np.stack(xs), np.array(ys)


def main() -> int:
    rng = random.Random(42)
    X, y = build_dataset(rng)
    clf = LogisticRegression(max_iter=800, multi_class="ovr")
    clf.fit(X, y)

    model = ct.converters.sklearn.convert(
        clf,
        input_features=[("features", Array(DIM))],
        output_feature_names="classLabel",
    )
    OUT_MODEL.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(OUT_MODEL))
    print(f"[build_micro_classifier] wrote {OUT_MODEL}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
