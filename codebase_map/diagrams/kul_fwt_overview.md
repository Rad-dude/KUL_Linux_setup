# KUL_FWT — pipeline overview

Two-stage pipeline (VOIs, then tractography), each with a per-subject and a
group-template variant. All four top-level scripts share the "assign
command line to `task_in`, `eval` it via `task_exec`" idiom — the extractor
resolves these by scanning the whole file text, not just line-start
commands (see `codebase_map/PLAN.md` §3).

```mermaid
flowchart TB
    VOIS["KUL_FWT_make_VOIs.sh\n(per-subject VOI generation from\naparc+aseg.mgz + MNI atlases)"]
    VOIS4T["KUL_FWT_make_VOIs_4Temp.sh\n(group-template variant)"]
    TCKS["KUL_FWT_make_TCKs.sh\n(per-subject tractography,\n4 approaches x 3 filter levels)"]
    TCKS4T["KUL_FWT_make_TCKs_4Temp.sh\n(group-template variant)"]

    TRACTOMETRY["KUL_FWT_tractometry_functions.sh\n(shared lib, sourced only under -Q,\nruns in the CALLER's shell scope)"]

    RECIPES["track_recipes/*.txt\n(~90 per-bundle VOI recipes)"]
    TEMPLATES["KUL_FWT_templates/\n(MNI atlases + TCK_models/\nreference tractograms)"]

    VOIS -. "dynamic: recipe_f built from\nbundle name at runtime" .-> RECIPES
    VOIS4T -. "same dynamic pattern" .-> RECIPES
    TCKS -. "dynamic: TCK_models/${bundle}_GN_symmetrical.tck" .-> TEMPLATES
    TCKS4T -. "same dynamic pattern" .-> TEMPLATES
    VOIS --> TEMPLATES

    TCKS -- "-Q flag" --> TRACTOMETRY
    TCKS4T -- "-Q flag" --> TRACTOMETRY

    subgraph POST["Python post-processing (subprocess, invoked from TCKs scripts)"]
        FBC["KUL_FWT_FBC_4TCKs.py\n(DIPY fiber-to-bundle coherence)"]
        CONN["KUL_FWT_plot_bundle_connectivity.py"]
        SCS["KUL_FWT_SCs_TCKs.py\n(AFQ-style tract profiles)"]
        SPIDER["KUL_FWT_bundle_spider_plot.py\n(per-subject radar chart, aggregates\nBUAN output across all bundles)"]
        REPORT["KUL_FWT_bundle_report.py\n(HTML contact sheet — TCKs.sh only,\noptional, command -v guarded)"]
        BUAN["KUL_FWT_buan_profile.py\n(leaf worker, called by\nKUL_FWT_run_tractometry per metric)"]
    end

    TCKS --> FBC
    TCKS --> CONN
    TCKS --> SCS
    TCKS --> SPIDER
    TCKS --> REPORT
    TCKS4T --> FBC
    TCKS4T --> CONN
    TCKS4T --> SCS
    TCKS4T --> SPIDER
    TRACTOMETRY --> BUAN

    NIS_CALLER["KUL_clinical_fmridti.sh / KUL_DRT.sh\n(KUL_NIS, function KUL_run_FWT)"]
    NIS_CALLER -- "bare name via PATH" --> VOIS
    NIS_CALLER -- "bare name via PATH" --> TCKS
    TRACTSOCD["KUL_tracts_ocd.sh (KUL_NIS)"] -- "bare name via PATH" --> FBC

    TOOLS["mrtrix3 (tckgen/tckedit/5ttgen/labelconvert — core)\nANTs (registration to template) · FSL · FreeSurfer"]
    SCILPY["scilpy (scil_bundle_*, scil_tractogram_*)\nDIPY (afq_profile, FBCMeasures, streamline utils)"]
    VOIS --> TOOLS
    TCKS --> TOOLS
    TCKS --> SCILPY
    FBC --> SCILPY
    SCS --> SCILPY
```

## Standalone, never called by any `.sh`/`.py` in this project

`KUL_FWT_morphometrics.py`, `KUL_FWT_plot_fixel_bundle_metrics.py`,
`KUL_FWT_TCKsm_cap.py` (unfinished scaffold), `KUL_Voxel_mask_segment.py` —
manual/notebook tools, not part of the automated pipeline. `dev_work/` holds
earlier iterations of `KUL_Voxel_mask_segment.py` plus scratch test images;
`KUL_FWT_dev_work/` holds a design-audit markdown, not code.

## Two bugs worth knowing about (found during inventory, not by the extractor)

- **`KUL_FWT_make_VOIs_4Temp.sh` self-locates via the wrong script name** —
  its `which KUL_FWT_make_VOIs.sh` call (line 221) looks up the *non*-`_4Temp`
  binary, apparently a copy-paste artifact. Only matters if the two scripts
  aren't both on `PATH` together.
- **`KUL_FWT_make_TCKs_4Temp.sh` doesn't call `KUL_FWT_bundle_report.py`**,
  unlike `KUL_FWT_make_TCKs.sh` — an undocumented asymmetry between the two
  variants (template runs get no HTML contact-sheet report).
