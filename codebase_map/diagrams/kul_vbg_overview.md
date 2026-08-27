# KUL_VBG — pipeline overview

Four independent entry points — none call each other programmatically
(`KUL_VBG.sh`'s own usage text mentions the other three, but the code never
invokes them; confirmed by the extractor finding no such edges after
comment-stripping). Every one defines its own local `task_exec`/`run`
function rather than sharing one library — unlike KUL_NIS, there's no
`KUL_main_functions.sh` equivalent here.

```mermaid
flowchart TB
    VBG["KUL_VBG.sh\n(main driver — lesion excision, synthetic-tissue\ngraft, FreeSurfer/FastSurfer/SynthSeg parcellation)"]
    MULTIPARC["KUL_VBG_multiparc.sh\n(standalone — same atlas set as VBG.sh -M,\nrunnable on any completed recon-all output)"]
    COOKTEMPLATE["KUL_VBG_cook_template.sh\n(manual/one-off — edit-and-run template builder,\nhardcoded example paths)"]
    SYNTHPATS["KUL_synth_pats_4VBG.sh\n(research/dev — synthetic lesioned-brain cohort generator)"]

    QC["KUL_VBG_QC.py\n(inpainting QC HTML report)"]
    OVERLAP["KUL_lesion_overlap.py\n(lesion/parcellation volumetric overlap)"]
    REMAP["remap_lausanne_to_msbp.py\n(atlasses/ — code-in-data-tree exception,\nalso duplicated inside KUL_NIS/atlases/)"]

    VBG --> QC
    VBG -- "-O flag" --> OVERLAP
    VBG -- "-M flag" --> REMAP
    MULTIPARC -- "-O flag" --> OVERLAP
    MULTIPARC --> REMAP

    VBG -. "mentioned in Usage text only,\nnever actually called" .-> MULTIPARC
    VBG -. "mentioned in Usage text only,\nnever actually called" .-> COOKTEMPLATE

    NIS_CALLER["KUL_clinical_fmridti.sh\n(KUL_NIS, function KUL_run_VBG)"]
    NIS_CALLER -- "bare name via PATH,\nalways passes -o explicitly\n(per KUL_VBG.sh comment)" --> VBG

    TOOLS["FreeSurfer (recon-all, mri_synthstrip/synthseg,\nsegment_subregions) · FastSurfer · ANTs (heavy) ·\nFSL · mrtrix3 (labelconvert)"]
    VBG --> TOOLS
    MULTIPARC --> TOOLS
    COOKTEMPLATE -- "hd-bet\n(still used here, unlike VBG.sh)" --> TOOLS
    SYNTHPATS -- "hd-bet" --> TOOLS
```

## Notable details not shown above

- **HD-BET was removed from `KUL_VBG.sh` itself** (changelog-documented) but
  is still actively used in `KUL_VBG_cook_template.sh` and
  `KUL_synth_pats_4VBG.sh` — an inconsistency across the project's own
  scripts, not a bug in the graph.
- **Self-location is PATH-dependent**: `KUL_VBG.sh` finds its own directory
  via `which KUL_VBG.sh`, `KUL_VBG_multiparc.sh` via the more robust
  `$(dirname "${BASH_SOURCE[0]}")`. A symlink or full-path invocation of
  `KUL_VBG.sh` would silently break its template/atlas/LUT lookups.
- **`Docker/`** (Dockerfile, entrypoint.sh, build.sh, KUL_VBG.def) is
  packaging metadata, not part of this call graph — see
  `notes/inventory_KUL_VBG.md` for what it vendors (ANTs, mrtrix3 fork, FSL,
  FreeSurfer 8.2.0, FastSurfer, all pinned to specific commits).
