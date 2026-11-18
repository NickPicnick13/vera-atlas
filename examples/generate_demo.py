#!/usr/bin/env python3
"""Generate a deterministic synthetic graph. Never reads user content."""
from __future__ import annotations
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent
R = random.Random(20261118)
CORE, SOURCES, CHUNKS = 1150, 56, 3300
nodes: list[dict] = []
edges: list[dict] = []

def node(identity: str, group: str, weight: float) -> None:
    nodes.append({"id": identity, "g": group, "w": round(weight, 3)})

def link(a: str, b: str, w: float) -> None:
    if a != b:
        edges.append({"a": a, "b": b, "w": round(w, 3)})

for i in range(CORE):
    node(f"demo-concept-{i:04d}", "core", 0.3 + R.random() * 0.7)
for i in range(SOURCES):
    source = f"demo-source-{i:03d}"
    node(source, "src", 0.8 + R.random() * 0.2)
    for _ in range(6):
        link(source, f"demo-concept-{R.randrange(CORE):04d}", 0.4 + R.random() * 0.5)
for i in range(CHUNKS):
    doc = f"demo-source-{i % SOURCES:03d}"
    chunk = f"demo-fragment-{i:05d}"
    node(chunk, "chunk", 0.22 + R.random() * 0.33)
    link(doc, chunk, 0.35 + R.random() * 0.35)
for i in range(CORE):
    link(f"demo-concept-{i:04d}", f"demo-concept-{(i+R.randrange(1,CORE))%CORE:04d}", .25+R.random()*.35)

out = ROOT / "demo-graph.json"
out.write_text(json.dumps({"nodes":nodes,"edges":edges},separators=(",",":"),sort_keys=True)+"\n",encoding="utf-8")
print(f"SYNTHETIC_DEMO {len(nodes)} nodes {len(edges)} edges -> {out.name}")
