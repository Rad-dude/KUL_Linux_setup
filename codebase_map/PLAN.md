# KUL_software codebase map — project plan

Status: **draft, not started**. Written after an initial survey of the repo;
implementation has not begun. See "Open decisions" at the bottom — that's
what we need to talk through before work starts.

## 1. What this is for

`KUL_software` is a self-contained install root (`setup_environment.sh`, 33
sections) for a neuroimaging stack. Inside `src/` it vendors ~15 third-party
tools (FSL, mrtrix3, ANTs, FreeSurfer, FastSurfer, HD-BET, HD-GLIO-AUTO,
scilpy, LoRE-SD, karawun, itksnap, leaddbs, matlab_apps/spm12, afni,
psychopy) plus three KUL-authored pipelines that are the actual object of
interest:

| project | files | sh/py/m LOC | role |
|---|---|---|---|
| `src/KUL_NIS` | 309 | ~42,200 | orchestrator: BIDS conversion, dwiprep, fMRI, connectomics, calls into VBG/FWT |
| `src/KUL_FWT` | 232 | ~12,100 | fiber tractography module, called by KUL_NIS, standalone-capable |
| `src/KUL_VBG` | 134 | ~8,300 | virtual brain grafting (lesion-aware segmentation/registration), called by KUL_NIS, standalone-capable |

Confirmed via grep: KUL_NIS calls into KUL_VBG and KUL_FWT (10 files
reference them); neither KUL_VBG nor KUL_FWT calls back into KUL_NIS or each
other. So the shape is hub-and-spoke, not a mesh — KUL_NIS is the hub.

Goal: produce a map of this codebase — architecture + call/dependency graph
— that a future developer (or me, in a future session) can use to
orient quickly, trace a pipeline stage to its implementation, and see what
external tools (FSL/mrtrix3/ANTs/FreeSurfer/...) each stage actually shells
out to.

## 2. What "graph" means here (proposed)

Two layers, not one diagram — a single diagram can't serve both "orient in
30 seconds" and "trace this exact call":

1. **Architecture view** (small, hand-legible): the 3 KUL projects, the
   setup_environment.sh install sections that provision them, and the
   external tool dependencies, as a handful of Mermaid diagrams embedded in
   a markdown doc.
2. **Call/dependency graph** (large, exhaustive): every script/function as a
   node, every `source`/invoke/`import`/subprocess call as an edge, machine-
   generated into structured data (JSON) — the thing that actually scales to
   ~90k LOC and ~670 files. Rendered as a filterable interactive view
   (Artifact, force-directed or hierarchical) since Mermaid stops being
   readable past a few dozen nodes.

The JSON is the primary deliverable — diagrams are views over it. That's
also what makes this re-runnable rather than a one-time snapshot.

## 3. Method

Full bash/Python static analysis (real AST-level call resolution across
shell scripts) is not practical here — bash doesn't have a robust free
parser, function/script names are frequently built from variables, and the
codebase mixes bash, Python, and a little MATLAB. So the extractor will be
**regex/heuristic-based**, not a true parser, and will be explicit about
that limitation in its output (dynamic dispatch shows up as "unresolved"
edges, not silently dropped).

Extraction targets per file type:
- **bash (`*.sh`)**: `source`/`.` includes, direct invocations of sibling
  `KUL_*.sh` scripts, function definitions and intra-file calls, calls to a
  curated list of external tool binaries (mrtrix3, FSL, ANTs, FreeSurfer,
  dcm2niix, HD-BET/HD-GLIO, etc.) to produce "this stage depends on tool X"
  edges.
- **Python (`*.py`)**: `import`/`from X import`, `subprocess.run/call/Popen`
  args that name a shell script or CLI tool.
- **MATLAB (`*.m`, `*.mlab`)**: light treatment only (function name
  references) — low priority, small fraction of the codebase.
- **`setup_environment.sh`**: parse its 33 named sections and their
  ordering/gating (`--only`/`--skip` already gives us the section names for
  free via `--list`), so the install graph and the runtime call graph share
  one node vocabulary for the external tools.

Concretely this means writing a small Python analysis script (checked into
`codebase_map/tools/`) rather than doing the extraction by hand via chat —
at this scale (232–309 files per project) that's the only way it stays
accurate and reproducible. The script is a deliverable in its own right:
future dev re-runs it after changes instead of re-deriving the map by hand.

## 4. Deliverables and layout

```
codebase_map/
├── PLAN.md                  # this file
├── tools/
│   └── extract_graph.py     # regex/heuristic extractor -> graph.json
├── data/
│   └── graph.json           # nodes + typed edges, the source of truth
├── diagrams/
│   ├── architecture.md      # hand-legible Mermaid: projects, install sections, external tools
│   ├── kul_nis_overview.md  # KUL_NIS entry points -> stage scripts -> external tools
│   ├── kul_vbg_overview.md
│   └── kul_fwt_overview.md
├── explorer.html            # Artifact-published interactive view of graph.json (search/filter/zoom)
└── MAP.md                   # narrative doc: architecture, entry points, data flow, how to regenerate/extend
```

## 5. Phases

1. **Inventory** — enumerate all files in the three projects + top-level
   setup, classify by type (entry-point script / stage script / helper /
   template / atlas-data / docs), tag third-party tool directories as
   external "leaf" nodes (their internals are out of scope — we care that
   something calls `flirt` or `mrconvert`, not FSL's own source).
2. **Extractor** — write and run `extract_graph.py`, producing `graph.json`.
3. **Spot-check** — manually verify a sample of edges (say 15-20, across all
   three projects and a few setup sections) against source to confirm the
   heuristics aren't systematically wrong before trusting the full graph.
4. **Diagrams** — generate the architecture Mermaid doc and the three
   per-project overview docs from the validated graph.
5. **Interactive explorer** — publish `explorer.html` as an Artifact for
   browsing the full graph (this is the piece that needs the
   `artifact-design`/diagramming skills and, if it needs to persist state
   like saved filters, `artifact-capabilities`).
6. **MAP.md** — tie it together: architecture narrative, pipeline data flow
   (BIDS → dwiprep → VBG → FWT → connectome, etc.), entry points per
   project, how to regenerate the graph after future changes, known gaps.

## 6. Known limitations (documented up front, not discovered later)

- Regex-based extraction misses calls built from variables/indirection
  (`$KUL_SCRIPT_DIR/${stage}.sh`) — these become "unresolved" edges, not
  silently dropped, and get called out in MAP.md.
- Third-party tools (`src/FSL`, `src/mrtrix3`, `src/afni`, etc.) are treated
  as black-box external dependencies, not scanned internally — in scope only
  as edge targets ("KUL_NIS calls `flirt`"), not as their own subgraph.
- MATLAB/`.mlab` files get light treatment — small fraction of the codebase,
  low value for the effort.
- Binary/data files (`.gz`, `.tck`, `.nii`, `.mat`, atlases) are inventoried
  as nodes (they're pipeline inputs/outputs) but obviously not parsed.

## 7. Open decisions — to discuss before starting

- **Depth**: is the two-layer plan (architecture Mermaid + full JSON graph +
  interactive explorer) the right scope, or is a single architecture-level
  doc enough for now, with the exhaustive call graph as a later phase if
  needed?
- **Interactive explorer**: worth publishing as an Artifact, or would static
  Mermaid/markdown docs in the repo be more useful day-to-day (no need to
  open a browser to a hosted page, works offline/in-editor)?
- **Scale of effort**: this repo is large enough (~90k LOC across the three
  projects) that parallelizing the inventory/extraction phase across
  multiple subagents (or a Workflow) would be faster than one linear pass —
  want me to do that, or keep it to a single agent working through it
  sequentially?
- **Freshness**: one-time snapshot, or should `extract_graph.py` be treated
  as a maintained tool you'd rerun after future changes (affects how much
  polish/robustness it's worth investing in now)?
