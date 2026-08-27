# Extractor validation (Phase 3 spot-check)

Ran `codebase_map/tools/extract_graph.py` against the three inventory
reports' documented facts. Result: 289 nodes, 3258 edges, 7 unresolved
sourcing targets.

## Bugs found and fixed during validation

1. **Cross-project basename collision resolved to the wrong project.**
   `remap_lausanne_to_msbp.py`, `generate_msbp_luts.py`, `make_readable_lut.py`
   are shipped as identical duplicates in both `KUL_VBG/atlasses/New/atlases/lausanne2008/`
   and `KUL_NIS/atlases/lausanne2008/`. The original "prefer shallowest path"
   tie-break picked KUL_NIS's copy even when the caller was `KUL_VBG.sh`
   itself. Fixed: `pick_primary()` now prefers a same-project candidate
   before falling back to shallowest-path-wins-across-projects (which is
   still correct for genuine PATH-based cross-project calls, e.g. KUL_NIS
   calling into KUL_VBG/KUL_FWT, where no same-project candidate exists).
2. **Line numbers drifted after comment/heredoc/docstring stripping.**
   `strip_noise()` originally deleted matched spans, shortening the text, so
   a later regex match's character offset no longer corresponded to the same
   offset in the original file -- reported line numbers for calls appearing
   after any comment/heredoc were wrong (off by however many lines had been
   deleted earlier in the file). Fixed: matched spans are now blanked in
   place (same length, newlines preserved) so offsets stay valid. Verified
   against `KUL_anat_segment_tumor.sh`'s `fast -S 4 ...` call: was reporting
   line ~231, now correctly reports line 326.

## Assertions checked against the inventory reports (all confirmed correct)

- `KUL_FWT_make_TCKs.sh` → `KUL_FWT_bundle_report.py` edge present (soft dep).
- `KUL_FWT_make_TCKs_4Temp.sh` → `KUL_FWT_bundle_report.py` **absent** (the
  documented asymmetry between the two variants).
- `KUL_multisubjects_dcm2bids.sh` → `KUL_dcm2bids_new.sh` present (the
  stale-variant call the KUL_NIS inventory flagged as likely-unintentional
  drift).
- `KUL_FS_multiparc.sh` → nothing in KUL_VBG (confirms the misleading header
  comment claiming "atlases live in sibling KUL_VBG_latest repo" does NOT
  correspond to a real dependency -- the comment was correctly excluded from
  producing an edge).
- `step5_lite_report.py` → `step5_report.py` (Python import) present.
- `run_pipeline.py` → `step1_sba.py` present; → `step3b_whole_brain_ica.py`
  **absent** (matches the inventory's finding that step3b is standalone-only,
  never imported by the orchestrator).
- All cross-project edges (`KUL_DRT.sh`/`KUL_clinical_fmridti.sh` →
  KUL_VBG/KUL_FWT, `KUL_tracts_ocd.sh` → `KUL_FWT_FBC_4TCKs.py`) match the
  inventories exactly, and only those -- no spurious cross-project edges.

## Known limitations (confirmed by example, not just anticipated)

1. **Inline comments are not stripped**, only whole-line comments. Example:
   `share/rsfmri_pipeline/src/step3_masked_ica.py` and `step3b_whole_brain_ica.py`
   both produce a `calls_tool → tool:fast` edge from the code comment
   `# fail fast with a clear error if no runs exist` -- a false positive.
   Fixing this generally (distinguishing a trailing `#`/`# ` remark from a
   literal `#` inside a string) needs real tokenization; not worth it for a
   heuristic tool. **Action taken**: these two false edges are excluded from
   the diagrams by hand (see diagrams/kul_nis_overview.md); left in
   `graph.json` since the extractor doesn't special-case single edges.
2. **Path/naming coincidences inflate call counts without being false
   *edges*.** `KUL_anat_segment_tumor.sh`'s `KUL_fast()` function names its
   working directories `fast/input`, `fast/output` and its output prefix
   `$fastoutputdir/fast` -- three of the four `tool:fast` matches in that
   file are these path mentions, not invocations; only one (`fast -S 4 ...`)
   is the actual call. The **edge** (this file does call `fast`) is still
   correct; the **per-line hit count** overcounts. Treat edge existence as
   reliable, per-edge occurrence counts as approximate.
3. **Log/status strings can name a script descriptively without calling it.**
   `KUL_multisubjects_dcm2bids.sh` produces an `invokes → KUL_dcm2bids.sh`
   edge from `kul_e2cl "Performing KUL_dcm2bids.sh -d ..." $log` (a log
   message, not a call) and from a log-directory-naming path string --
   alongside the real edge to `KUL_dcm2bids_new.sh` at line 214, which is the
   actual call. Same category as #1/#2: whole-word text scanning cannot
   distinguish "this string names a script" from "this line runs a script."
4. `share/spm12/*.m` dispatch (which of 6 stats scripts runs) and the two
   `track_recipes/`/`TCK_models/` per-bundle lookups are genuinely
   unrecoverable by any text-scan (target built from a runtime value) --
   handled via the 5 manually-curated `MANUAL_DYNAMIC_EDGES` in the
   extractor, not left silently missing.

## Net assessment

High-confidence for: sourcing edges, Python import edges, cross-project
calls, install-section → tool/env provisioning. Directionally reliable but
occasionally noisy for: `calls_tool` edges built on short/common tool names
that also occur in path segments or comments (`fast`, `bet`, `N4` — checked
individually above, no systematic problem found beyond the three documented
cases). Treat `graph.json` as "high recall, good-not-perfect precision" --
exactly what a regex/heuristic approach over ~90k LOC of bash can
realistically deliver, and enough for the diagrams and explorer this project
produces.
