# KUL_software — codebase map

Start here. This ties together everything in `codebase_map/` — see
`PLAN.md` for how this was built and why, this file for what it found.

**Interactive explorer**: https://claude.ai/code/artifact/6fef0533-a635-4a45-9d77-30a9def38828
(also saved at `explorer.html` — self-contained, opens in any browser
offline). Search any file, click a node for its purpose/functions/calls/tool
dependencies (each with a plain-language description), drag to rearrange.
Click "View internal structure" on any file with detected calls to drill
into a second-level graph: that file's own functions, in source order, with
edges to the other functions/tools/files each one calls — a step-by-step
view of what happens inside a single script, not just which files touch
which. That inner view is still a line-order heuristic, not a true
control-flow trace (see the extractor's `internal.steps` field and
`compute_function_ranges()` for how it's attributed). Currently private to
the account that published it; share it from the page's share menu if
others need it.

## The shape of the codebase

`KUL_software` (this checkout; upstream name `KUL_Linux_setup`) is an
install root. `setup_environment.sh` (33 sections) provisions ~15 third-party
neuroimaging tools and clones three KUL-authored pipelines into `src/`:

- **KUL_NIS** (~42k LOC, 94 code files) — the orchestrator. BIDS conversion,
  dMRI/fMRI preprocessing, tumor segmentation, DSC perfusion, connectomics.
  Its master script, `KUL_clinical_fmridti.sh`, drives the whole clinical
  workflow end to end and calls into both other pipelines.
- **KUL_VBG** (~8.3k LOC, 11 code files) — lesion-aware virtual brain
  grafting: excises a lesion, fills it with synthetic tissue, runs
  FreeSurfer/FastSurfer parcellation on the result.
- **KUL_FWT** (~12k LOC, 18 code files) — parcellation-driven fiber
  tractography: generates anatomical VOIs, then tracks and filters bundles.

**Hub-and-spoke, confirmed by grep across all three repos**: KUL_NIS calls
into KUL_VBG and KUL_FWT (bare script name, resolved via `PATH` — see
"Why bare-name calls" below); neither of the other two ever calls back into
KUL_NIS or into each other. See `diagrams/architecture.md` for the
picture.

## Where to look for what

| Question | Where |
|---|---|
| "What does the whole system look like?" | `diagrams/architecture.md` |
| "What does KUL_NIS/VBG/FWT actually contain, entry point by entry point?" | `diagrams/kul_nis_overview.md`, `kul_vbg_overview.md`, `kul_fwt_overview.md` — or the narrative detail in `notes/inventory_KUL_*.md` |
| "What calls what, exactly — with line numbers?" | `explorer.html` (or `data/graph.json` directly) |
| "How does setup_environment.sh's install order work, and which conda env does stage X need?" | `notes/setup_environment_analysis.md` |
| "How accurate is any of this?" | `notes/extractor_validation.md` |
| "I changed the code, how do I refresh this?" | See "Keeping this current" below |

## Findings worth knowing before you touch this codebase

These came out of the inventory + extraction work, not from any README —
they're the kind of thing that costs an afternoon to rediscover otherwise.

- **Cross-script calls resolve via `PATH`, not paths.** `setup_environment.sh`'s
  `repos` section puts all three project directories on `PATH`, and most
  script-to-script calls — cross-project and a good deal of intra-project —
  use the bare script name. There's no automatic fallback: the installer's
  own comment warns that KUL_FWT's scripts must already resolve on `PATH`
  before `KUL_clinical_fmridti.sh` runs.
- **External-tool and script calls are almost never direct.** All three
  projects funnel calls through a "build a command-line string in a
  variable, then `eval` it via a wrapper function" idiom — `task_in`/`cmd`
  + `KUL_task_exec`/`task_exec` in KUL_NIS/KUL_VBG, the same shape with
  different names (`run`/`run_soft`) in `KUL_VBG_multiparc.sh`. A plain
  line-start grep for command names misses almost everything; this is why
  the extractor scans whole file text rather than just command positions.
- **Two known documentation/code mismatches**: `KUL_FS_multiparc.sh`'s
  header claims its atlases live in "sibling KUL_VBG_latest repo" — the code
  actually reads its own local `KUL_NIS/atlases/`, no real KUL_VBG
  dependency. `KUL_VBG.sh`'s own Usage text mentions
  `KUL_VBG_cook_template.sh`/`KUL_VBG_multiparc.sh` as if related, but never
  calls either — they're independent, separately-run utilities.
- **Several "current" scripts have a stale twin still in the tree**:
  `KUL_dcm2bids_new.sh` (older, despite the name) is still what
  `KUL_multisubjects_dcm2bids.sh` actually calls, not the current
  `KUL_dcm2bids.sh`. `share/nilearn/KUL_fmriproc_nilearn_new.sh` is a stale
  515-line duplicate of the current 713-line top-level version. Three
  lausanne-atlas LUT scripts (`remap_lausanne_to_msbp.py`,
  `generate_msbp_luts.py`, `make_readable_lut.py`) are byte-identical
  duplicates shipped in *both* KUL_VBG and KUL_NIS.
- **Two small bugs found during inventory** (not fixed, just documented):
  `KUL_FWT_make_VOIs_4Temp.sh` self-locates via `which KUL_FWT_make_VOIs.sh`
  — the *non*-`_4Temp` name, apparently copy-paste. `KUL_FWT_make_TCKs_4Temp.sh`
  silently skips the HTML bundle-report step that `KUL_FWT_make_TCKs.sh`
  runs — template-data runs get no contact-sheet report, and nothing flags
  this.
- **Genuinely dynamic dependencies** (can't be resolved by reading source,
  only by running it): `KUL_FWT_make_VOIs*.sh` pick a per-bundle recipe file
  from `track_recipes/` by name at runtime (from the `-c` config file);
  `KUL_FWT_make_TCKs*.sh` similarly pick a reference tractogram from
  `KUL_FWT_templates/TCK_models/`; `KUL_fmriproc_spm_new.sh` picks one of 6
  SPM12 `.m` job scripts based on run-count and an algorithm flag. These are
  modeled as explicit "dynamic" edges in `data/graph.json`, not silently
  dropped.
- **Not everything is wired into automation.** A handful of scripts are
  orphans by design — manual/QC tools nothing calls: `KUL_dcm2bids.py`,
  `KUL_BIDS_clean.py`, `KUL_eddy_squad.py`, `KUL_make_fMRI_labels.sh`,
  several `KUL_FWT_*` standalone Python utilities. Others are dev/WIP/backup
  and should not be mistaken for the current path: `KUL_lesion_fs_recall.sh`,
  `KUL_radsyndisco.sh`, `KUL_VSC_prepare_dwiprep.sh`,
  `KUL_dwiprep_group_fba_bkup.sh`, `KUL_karawun2brainlab.sh`. Full list with
  reasons in each `diagrams/kul_*_overview.md`.

## How this was built (short version — see PLAN.md for the full rationale)

1. Three parallel research agents produced a narrative inventory of KUL_NIS,
   KUL_VBG, and KUL_FWT (`notes/inventory_KUL_*.md`) — entry points vs.
   helpers vs. dev/deprecated, every local and cross-project call pattern,
   every external tool called, with exact line numbers and idioms.
2. A hand-written analysis of `setup_environment.sh`'s 33 install sections
   and conda/venv env ownership (`notes/setup_environment_analysis.md`).
3. A regex/heuristic Python extractor (`tools/extract_graph.py`), tuned
   against those inventories, producing `data/graph.json` — 289 nodes, 3258
   edges. Not a real parser (bash doesn't have a robust free one); documented
   heuristics instead, validated against the inventories'
   documented facts (`notes/extractor_validation.md`) — two real bugs were
   caught and fixed this way (a cross-project name-collision mis-resolution,
   and a line-number drift after comment-stripping).
4. Hand-authored architecture + per-project Mermaid diagrams
   (`diagrams/*.md`) for the "orient in 30 seconds" view.
5. An interactive explorer (`explorer.html`, force-directed call graph +
   detail panel) built from the same `graph.json`, for the "trace this exact
   call" view.

## Keeping this current

This is meant to be re-run, not a one-time snapshot:

```bash
python3 codebase_map/tools/extract_graph.py    # re-scan src/, rewrite data/graph.json
python3 codebase_map/tools/build_explorer.py   # re-splice graph.json into explorer.html
```

A new file gets its purpose line and any new external tool gets its
description from `tools/curated_metadata.py` (`NODE_PURPOSE`,
`TOOL_INFO`, keyed by node id / tool name) — these are hand-written, not
regenerated, so add an entry there when adding a script or calling a new
tool for the first time; the extractor logs which nodes/tools are missing
one so nothing has to be tracked by hand.

Then republish `explorer.html` as the same Artifact (same file path) if you
want the hosted copy updated too. The Mermaid diagrams and the narrative
findings above were hand-authored from the inventories and won't
auto-update — re-check them if a change touches the areas they describe
(new entry point, changed cross-project call, a stale duplicate finally
removed, etc.).

`data/graph.json`'s `unresolved` array and the `source: "manual"` edges are
the extractor's own record of what it couldn't resolve automatically —
worth a glance after a re-run to see if anything new needs a manual note
the way `track_recipes/`/`TCK_models/`/SPM12 dispatch got one.
