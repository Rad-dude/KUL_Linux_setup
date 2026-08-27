#!/usr/bin/env python3
"""Splice data/graph.json into tools/explorer_template.html to produce
../explorer.html. Re-run after re-running extract_graph.py."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
graph = json.loads((ROOT / "data/graph.json").read_text())
compact = json.dumps(graph, separators=(",", ":"))
assert "</script" not in compact, "graph JSON contains a literal </script> -- would break embedding"

template = (ROOT / "tools/explorer_template.html").read_text()
out = template.replace("%%GRAPH_JSON%%", compact)
(ROOT / "explorer.html").write_text(out)
print(f"wrote {ROOT / 'explorer.html'} ({len(out)} bytes)")
