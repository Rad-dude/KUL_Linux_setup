# Inventory Report: src/KUL_FWT

(Produced by inventory subagent; saved verbatim for use by the extractor and diagram phases. See PLAN.md for context.)

`src/KUL_FWT` — KULeuven "Fun With Tracts": parcellation-based, fully-automated fiber tractography pipeline. MRtrix3 does tractography; ScilPy/DIPY do filtering, screenshots, and bundle profiling. Currently on branch `KUL_FWT_v2.0` (v2.0_01072026). Confirmed called from outside only by `src/KUL_NIS` (`KUL_DRT.sh`, `KUL_tracts_ocd.sh`, `KUL_dwiprep.sh`, `KUL_main_functions.sh`, `KUL_clinical_fmridti.sh`), which invoke `KUL_FWT_make_VOIs.sh`, `KUL_FWT_make_TCKs.sh`, and (indirectly, as subprocesses of those two) `KUL_FWT_bundle_report.py`, `KUL_FWT_bundle_spider_plot.py`, `KUL_FWT_FBC_4TCKs.py`. KUL_FWT never calls back into KUL_NIS or KUL_VBG.

## Entry points

### KUL_FWT_make_VOIs.sh (2555 lines)
Purpose: generates every anatomical inclusion/exclusion VOI needed for tractography, per-subject, from a FreeSurfer `aparc+aseg.mgz` plus shipped MNI-space atlases, driven by a bundle-list config file.
Classification: entry-point (run directly by users and by KUL_NIS).
CLI: `-p -s -F -c -d -o -n -G -D -B -h`; self-locates via `function_path=($(which KUL_FWT_make_VOIs.sh | ...))` — depends on the script being on PATH under this exact name; also locates `KUL_FWT_templates/` (`pr_d="${function_path}/KUL_FWT_templates"`), `FreeSurferColorLUT.txt`, `fs_default.txt`, `track_recipes/` relative to itself.
Local calls out: none to other KUL_FWT .sh/.py files. Comments reference `KUL_FWT_make_TCKs.sh` and a stale/renamed `KUL_genVOIs.sh` (not a real file) only descriptively.
Data dependency: reads `-c` config file (typically `KUL_FWT_tracks_list.txt`, format `bundle_name,seed_count`, `#`-comments) into `tck_list[]`/`nosts_list[]`. For each bundle builds `recipe_f="${function_path}/track_recipes/${tck_list[$q]}.txt"` (line ~2401) — variable-built path = unresolved/dynamic edge, resolved only at runtime by bundle name. Missing recipe file → VOI creation skipped with log message, no hard failure. Recipe files declare `incs1/incs2/.../excs <name> <label>` triples; atlas source for `<name>` chosen by ordered substring if/elif chain (MSBP→FS→2009→Fx→lobe→aseg→SUIT→CIT→DISTAL_STN→TMP_BStem→MAN→UKBB→JHU→custom, per `KUL_FWT_dev_work/2026-08-08_recipe_audit_and_roadmap.md`), then VOI = `<source_map> <label> -eq` (mrcalc). Confirms track_recipes/*.txt = per-bundle VOI recipes, consumed exclusively by make_VOIs.sh/make_VOIs_4Temp.sh.
Functions defined: `Usage`, `task_exec`, `KUL_wait_all_bg_and_check`, `PD25_lab_gen`, `make_VOIs`.
External tools: heavy mrcalc(299), maskfilter(58), antsApplyTransforms(26), mrfilter(18), ImageMath/ANTs(11), mri_convert(7), fslmaths(7), mri_annotation2label(2), mri_aparc2aseg(1), antsRegistrationSyN.sh(2), WarpImageMultiTransform(1), mrmath, mrconvert, labelconvert, dwi2tensor, tckgen(2), one scil_reco_bundles call. labelconvert invoked with `${function_path}/FreeSurferColorLUT.txt` and `${function_path}/fs_default.txt` — self-relative data files.

### KUL_FWT_make_VOIs_4Temp.sh (2224 lines)
Purpose: same VOI-generation workflow, retargeted for group-averaged template data instead of single-subject dMRI (no `-p`-session dMRI dir logic; near-identical structure/function names to make_VOIs.sh).
Classification: entry-point (standalone; not observed called by KUL_NIS in this pass — appears used for template/atlas-construction workflows).
Local calls out: none. Same self-location pattern, BUT: even in the `_4Temp` variant it looks up the *non*-`_4Temp` binary name (`which KUL_FWT_make_VOIs.sh`, line 221) — likely copy-paste artifact, flag as suspect.
Data dependency: same `track_recipes/${tck_list[$q]}.txt` variable-built lookup (line ~2073); same LUT reads (via `${mrtrix_path}/share/mrtrix3/labelconvert/fs_default.txt` in one branch, line 1218, vs local copy in another).
Functions defined: same set as make_VOIs.sh.
External tools: mrcalc(296), maskfilter(56), antsApplyTransforms(26), mrfilter(17), ImageMath(11), fslmaths(7), mri_convert(5), mri_annotation2label(2), labelconvert(2), antsRegistrationSyN.sh(2), WarpImageMultiTransform(1), mrmath, mri_aparc2aseg, mrconvert, scil_reco_bundles(2).

### KUL_FWT_make_TCKs.sh (2493 lines)
Purpose: generates all fiber bundles specified in the config, using VOIs from make_VOIs.sh, for a single subject. 4 tracking approaches (bundle-specific tckgen, whole-brain tckgen+segmentation, whole-brain with ACT, bundle-specific GMWMI seeding), 3 filtering levels.
Classification: entry-point (run directly; called by KUL_NIS).
Local calls out (exact patterns):
- `source "$(dirname "$0")/KUL_FWT_tractometry_functions.sh"` (line 1714) — conditional, only inside the QQ/tractometry branch (`-Q`).
- Sibling Python scripts invoked via `task_in="<cmd> ..."` then bare `task_exec` (string-eval indirection — extractor should treat every such pair as a real invocation edge):
  - `KUL_FWT_FBC_4TCKs.py -i ... -r ... -o ...` (line 1509)
  - `KUL_FWT_plot_bundle_connectivity.py ...` (line 1702)
  - `KUL_FWT_SCs_TCKs.py -i ... -m ... -v ...` (line 1752)
  - `KUL_FWT_bundle_spider_plot.py ${TCKs_outd} ${subj} ${ses_str}` (line 2473)
  - `KUL_FWT_bundle_report.py ${TCKs_outd} ${subj} ${ses_str}` (line 2487) — guarded by `command -v KUL_FWT_bundle_report.py` (soft/optional, skipped with warning if absent).
  - Transitively, `KUL_FWT_buan_profile.py` via the sourced tractometry function.
  - `scil_tractogram_convert` for `.trk` export — guarded by `command -v` (soft dependency).
- Self-locates via `which KUL_FWT_make_TCKs.sh`; reads `KUL_FWT_templates/` (`pr_d`) and VOI outputs of make_VOIs.sh from `${ROIs_d}` (a directory-path contract between the two scripts, not a code call).
Functions defined: `Usage`, `KUL_throttle`, `KUL_dispatch_bundles`, `task_exec`, `make_bundle`.
External tools: tckgen(22), mrcalc(11), tckstats(9), antsApplyTransforms(9), tckmap(8), tckedit(6), fixel2voxel(5), maskfilter(4), tckresample(3), mrstats(2), mrconvert(2), freeview(2, comments only — no direct invocation, verify), fod2fixel(2), tcksample, mrview, mrmath, mrgrid, fast(FSL,1), antsRegistrationSyN.sh(1), 5ttgen, 5tt2gmwmi; scilpy: scil_bundle_compute_centroid, scil_bundle_reject_outliers, scil_bundle_uniformize_endpoints, scil_filter_tracts, scil_tractogram_convert, scil_tractogram_detect_loops, scil_tractogram_filter_by_roi, scil_tractogram_segment_with_recobundles, scil_tractogram_smooth, scil_vis_mosaic, scil_viz_bundle_screenshot_mni, scil_viz_bundle_screenshot_mosaic. Also prints version banners (`mrconvert --version`, `python -c 'import scilpy; print(scilpy.__version__)'`).
Data dependency: `-c` config same as make_VOIs.sh; `KUL_FWT_templates/TCK_models/${tck_list[$q]}_GN_symmetrical.tck` (variable-built path, per-bundle reference tractogram for `scil_bundle_uniformize_endpoints --centroid`) — falls back to orienting by the bundle's incs1 VOI if absent.

### KUL_FWT_make_TCKs_4Temp.sh (2136 lines)
Purpose: template/group-data counterpart of make_TCKs.sh — same 4 tracking approaches + QQ/filtering pipeline, adapted for group-averaged FOD data.
Classification: entry-point (standalone; not confirmed called by KUL_NIS).
Local calls out: `source "$(dirname "$0")/KUL_FWT_tractometry_functions.sh"` (line 1526, same `-Q`-conditional pattern); same task_in/task_exec calls to `KUL_FWT_FBC_4TCKs.py`(1324), `KUL_FWT_plot_bundle_connectivity.py`(1515), `KUL_FWT_SCs_TCKs.py`(1555), `KUL_FWT_bundle_spider_plot.py`(2133). Notably does NOT call `KUL_FWT_bundle_report.py` (unlike make_TCKs.sh) — asymmetry between the two variants.
Functions defined: same set as make_TCKs.sh.
External tools: tckgen(16), tckstats(9), antsApplyTransforms(9), tckmap(8), mrcalc(8), tckedit(6), tckresample(3), fixel2voxel(3), mrstats, mrmath, mrgrid, maskfilter, fod2fixel, fast, 5ttgen, 5tt2gmwmi, tcksample; scilpy set overlaps make_TCKs.sh minus scil_tractogram_convert (not observed here).

## Library / helper files

### KUL_FWT_tractometry_functions.sh (137 lines)
Purpose: shared, sourced-only tractometry library. Unifies per-bundle along-tract metric profiling (dipy.stats.analysis.afq_profile, via KUL_FWT_buan_profile.py) for both make_TCKs.sh and make_TCKs_4Temp.sh, replacing an older fixel-based sampler.
Classification: library/helper — sourced by exactly two files (make_TCKs.sh:1714, make_TCKs_4Temp.sh:1526), both conditionally under `-Q`.
Functions defined:
- `KUL_FWT_add_metric_if_present` — appends (name, scalar_path) to caller-owned `buan_metrics[]`/`buan_scalars[]` arrays only if scalar_path exists on disk.
- `KUL_FWT_run_tractometry` — runs in caller's own shell scope (not a subshell — shared-variable-scope dependency, not just a function call: expects `TCK_out`, `TCK_2_make`, `T`, `algo_f`, `subj`, `ses_str`, `prep_d`, `ncpu`, `prep_log2`, `tck_rs1_innat`, `tck_filt5_centroid1`, `tractometry_reference_nii`, `buan_metrics[]`, `buan_scalars[]` already set by caller). For iFOD1/iFOD2/SD_Stream, also profiles fixel-derived FD/Disp/Peaks metrics if `prep_d/fixel_metrics` has them.
Local calls out: invokes KUL_FWT_buan_profile.py (per-metric, backgrounded) via the same task_in/task_exec pattern — relies on `task_exec` being defined in the caller's scope (not defined in this file itself, another scope dependency).
External tools: tck2fixel, mrthreshold, voxel2fixel, mrcalc, fixel2voxel.

## Python entry points called by the shell pipeline

- **KUL_FWT_FBC_4TCKs.py** (80 lines): DIPY Fiber-to-Bundle Coherence filtering. CLI `-i <input.tck> -r <reference anatomy> -o <output.tck>`. Leaf. Imports: nibabel, scipy, dipy (dipy.io.stateful_tractogram, dipy.io.streamline, dipy.io.utils, dipy.denoise.enhancement_kernel.EnhancementKernel, dipy.tracking.fbcmeasures.FBCMeasures).
- **KUL_FWT_plot_bundle_connectivity.py** (39 lines): per-bundle connectivity matrix + plot from filtered tractogram vs labeled parcellation. Invoked from both make_TCKs scripts. Imports: nibabel, matplotlib.pyplot, dipy.io.streamline.load_tractogram, dipy.tracking.utils.connectivity_matrix, numpy.
- **KUL_FWT_SCs_TCKs.py** (121 lines): AFQ-style tract-profile analysis ("Streamline/Structural Connectivity for TCKs"), adapted from a DIPY AFQ example. Invoked from both make_TCKs scripts (`-i <tck> -m <prep_dir> -v <VOIs_dir>`). Imports: nibabel, scipy, dipy (dipy.stats.analysis as dsa, dipy.data as dpd, dipy.tracking.streamline as dts), pkgutil, matplotlib, nilearn.plotting.
- **KUL_FWT_bundle_spider_plot.py** (1189 lines): post-hoc aggregation, run once per subject after KUL_FWT_run_tractometry finishes for every bundle. Assembles per-bundle/per-metric along-tract score files into one bundle×metric summary + radar/spider chart per bundle (subject-relative 0-1 normalized). Invoked from both make_TCKs scripts. Reads `fs_default.txt` by exact self-relative path (`os.path.join(os.path.dirname(os.path.abspath(__file__)), "fs_default.txt")`). Imports: matplotlib(Agg), nibabel, numpy, argparse, csv, glob, json.
- **KUL_FWT_bundle_report.py** (381 lines): collects every bundle's per-orientation/per-rendering screenshots (12 PNGs/bundle from make_TCKs.sh's `-S` step) into one self-contained HTML contact-sheet per subject (embedded JPEG data URIs). Invoked from KUL_FWT_make_TCKs.sh only (line 2487), soft/optional via `command -v`. NOT called from make_TCKs_4Temp.sh. Same fs_default.txt self-relative lookup (line 176). Imports: PIL/Pillow(Image, ImageChops), numpy, argparse, base64, glob, io, json, re.
- **KUL_FWT_buan_profile.py** (81 lines): computes per-bundle along-tract scalar profile (DIPY afq_profile) for one metric, writes CSV, optional PDF plot. Leaf worker invoked once per metric by KUL_FWT_run_tractometry. Imports: nibabel, dipy.io.streamline.load_tractogram, dipy.stats.analysis.afq_profile, matplotlib (lazy).

## Standalone Python utilities (not called by any .sh script in this project)

No caller found across all .sh/.py in KUL_FWT — user-invoked directly (notebooks/manual QA), not part of the automated pipeline:
- **KUL_FWT_morphometrics.py** (313 lines): morphological features of tractograms (volume, surface area via marching cubes), per Pretorius et al. 2020 (doi:10.1016/j.neuroimage.2020.117329). Imports: numpy, skimage.measure(marching_cubes, mesh_surface_area), dipy.tracking.utils.density_map, nibabel/nibabel.streamlines.
- **KUL_FWT_plot_fixel_bundle_metrics.py** (88 lines): plots mean fixel-derived bundle metrics from CSV, PDF-to-image conversion. Imports: pandas, matplotlib.pyplot, pdf2image.convert_from_path; sets QT_DEBUG_PLUGINS via os.system (env-var hack, not a script call).
- **KUL_FWT_TCKsm_cap.py** (49 lines): visualizes a TCK-derived segmentation map; minimal CLI (`-i <inputfile>`), largely unfinished/scaffold. Imports: nibabel, dipy.tracking.streamline, nilearn.plotting, dipy.viz(actor, window, colormap).
- **KUL_Voxel_mask_segment.py** (76 lines): divides a binary voxel mask into segments along its principal axis (PCA-derived). Imports: numpy, nibabel, sklearn.decomposition.PCA. Has 2 earlier iterations in dev_work/ (KUL_Voxel_mask_segment3.py, KUL_Voxel_mask_segment4.py — same core algorithm, e.g. added num_segments parameter); this top-level copy is the current version.

## Dev / deprecated

- **dev_work/**: not called by pipeline. Contains KUL_Voxel_mask_segment3.py, KUL_Voxel_mask_segment4.py (earlier PCA-segmentation experiments), slices_maps.py (NIfTI slice images via concurrent.futures.ProcessPoolExecutor), and 4 .nii.gz scratch test images (axial/binary_mask/coronal/sagittal). Classify dev/deprecated/experimental scratch — no references to/from production code.
- **KUL_FWT_dev_work/**: single markdown file `2026-08-08_recipe_audit_and_roadmap.md` (23.5KB) — developer audit of track_recipes/ externalization (branch KUL_FWT_v2.0): documents recipe resolution (name→atlas substring matching, label→voxel selection, custom-VOI filename-is-the-name rule) and specific recipe bugs found/fixed (e.g. DRTT incs4 parser bug, ThR/SAF intent fixes). Design/audit doc, not code — useful ground-truth for track_recipes/ consumption, worth linking from MAP.md.

## Data / config (not code)

- **KUL_FWT_tracks_list.txt**: master bundle list, `bundle_name,seed_count` per line (`#`-prefixed = disabled), e.g. `CST_LT,10000`. Consumed via `-c` by all four top-level .sh scripts identically (`IFS=$'\n' read -d '' -r -a tck_lst1 < ${conf_f}`, split on `,`).
- **track_recipes/*.txt** (~90 files, e.g. CST_LT.txt, IFOF_RT.txt): per-bundle VOI recipes, format `<incs1|incs2|...|excs> <VOI_name> <label>` (e.g. `incs1 CST_LT_UKBB 1`, `excs Cing_lobeGM_LT 1003`). Consumed only by make_VOIs.sh/make_VOIs_4Temp.sh, looked up by exact bundle name. VOI_name substring-matches ordered atlas chain (MSBP→FS→2009→Fx→lobe→aseg→SUIT→CIT→DISTAL_STN→TMP_BStem→MAN→UKBB→JHU→custom); custom VOIs (`_custom` suffix) resolve to `custom_VOIs/<name>.nii.gz` directly, ignoring the label.
- **KUL_FWT_templates/**: MNI-space priors/atlases (UKBB, JHU, Juelich, PD25 histological thalamus atlas, SUIT cerebellar atlas, CIT168/DISTAL STN atlases, manual VOIs, brain masks, T1 templates), consumed by make_VOIs*.sh via `pr_d="${function_path}/KUL_FWT_templates"`. Also `TCK_models/` subfolder (~90 `<bundle>_GN_symmetrical.tck` files) — per-bundle reference tractograms in template space, consumed by make_TCKs*.sh's `scil_bundle_uniformize_endpoints --centroid` step.
- **FreeSurferColorLUT.txt, fs_default.txt**: FreeSurfer/MRtrix label LUTs, shipped at KUL_FWT top level (self-relative to function_path/__file__), consumed by (a) labelconvert calls in both make_VOIs scripts, (b) KUL_FWT_bundle_spider_plot.py/KUL_FWT_bundle_report.py directly via os.path.dirname(os.path.abspath(__file__)).

## Notable patterns worth encoding in the extractor

1. **String-built command + task_exec eval pattern**: nearly every external tool/Python-script call in the four top-level .sh files is `task_in="<cmd> ..."` followed by a bare `task_exec` (or `task_exec &`) on the next non-blank line, not a direct call. Treat `task_in="..."` assignments as the actual call sites, resolve the first whitespace-delimited token as the binary/script name. Caveat: strings are often built across multiple lines with `\` continuations, and a few if/else branches select the command via `${var}` (e.g. `cmd_str="tckgen ..."` vs `cmd_str="tckedit ..."` selected by `${T_app}` in `make_bundle()` in both TCKs scripts) — resolves to a fixed literal per branch, not a single line.
2. **Self-location via `which <exact-script-basename>`**: all four top-level scripts locate their own template/recipe/LUT dirs via `function_path=($(which <script-name> | ...))`. Only works if invoked by that literal name from PATH — symlink/rename/full-path invocation bypasses it silently (prints a warning, empty function_path). `make_VOIs_4Temp.sh` hardcodes the *non*-`_4Temp` script name in its `which` call (line 221) — likely copy/paste bug, flag as suspect not a real cross-file dependency.
3. **Conditional sourcing gated by a flag**: `source .../KUL_FWT_tractometry_functions.sh` only executes inside the `-Q` branch — static grep finds the `source` line unconditionally, but the actual edge is conditional at runtime.
4. **Soft/optional dependencies via `command -v`**: KUL_FWT_bundle_report.py and scil_tractogram_convert both guarded this way. Worth a distinct edge type ("optional call") vs hard dependencies.
5. **Variable-built data-file paths (unresolved by static analysis)**: `track_recipes/${tck_list[$q]}.txt` and `TCK_models/${tck_list[$q]}_GN_symmetrical.tck` only resolvable at runtime (bundle name from `-c` config). Model as edges from make_VOIs*.sh/make_TCKs*.sh to the *directories* track_recipes/ and KUL_FWT_templates/TCK_models/ respectively, tagged unresolved/dynamic, rather than enumerating every possible target file.

## Consolidated external-tool-call table

| Tool / binary | Calling files |
|---|---|
| mrcalc (mrtrix3) | make_VOIs.sh, make_VOIs_4Temp.sh, make_TCKs.sh, make_TCKs_4Temp.sh, KUL_FWT_tractometry_functions.sh |
| maskfilter | make_VOIs.sh, make_VOIs_4Temp.sh, make_TCKs.sh, make_TCKs_4Temp.sh |
| tckgen | make_TCKs.sh, make_TCKs_4Temp.sh, make_VOIs.sh(2), make_VOIs_4Temp.sh |
| tckedit | make_TCKs.sh, make_TCKs_4Temp.sh |
| tckstats | make_TCKs.sh, make_TCKs_4Temp.sh |
| tckmap | make_TCKs.sh, make_TCKs_4Temp.sh |
| tckresample | make_TCKs.sh, make_TCKs_4Temp.sh |
| tcksample | make_TCKs.sh, make_TCKs_4Temp.sh |
| mrfilter | make_VOIs.sh, make_VOIs_4Temp.sh |
| mrconvert | make_TCKs.sh, make_VOIs.sh, make_VOIs_4Temp.sh |
| mrstats | make_TCKs.sh, make_TCKs_4Temp.sh, make_VOIs.sh, make_VOIs_4Temp.sh |
| mrmath | all four top-level .sh (self-location probe: which mrmath) |
| mrgrid | make_TCKs.sh, make_TCKs_4Temp.sh |
| mrview | make_TCKs.sh |
| mrthreshold | KUL_FWT_tractometry_functions.sh |
| labelconvert | make_VOIs.sh, make_VOIs_4Temp.sh |
| 5ttgen, 5tt2gmwmi | make_TCKs.sh, make_TCKs_4Temp.sh |
| dwi2tensor | make_VOIs.sh |
| fixel2voxel | make_TCKs.sh, make_TCKs_4Temp.sh, KUL_FWT_tractometry_functions.sh |
| fod2fixel | make_TCKs.sh, make_TCKs_4Temp.sh |
| voxel2fixel | KUL_FWT_tractometry_functions.sh |
| tck2fixel | KUL_FWT_tractometry_functions.sh |
| fslmaths | make_VOIs.sh, make_VOIs_4Temp.sh |
| fast (FSL) | make_TCKs.sh, make_TCKs_4Temp.sh |
| antsApplyTransforms | make_VOIs.sh, make_VOIs_4Temp.sh, make_TCKs.sh, make_TCKs_4Temp.sh |
| antsRegistrationSyN.sh | make_VOIs.sh, make_VOIs_4Temp.sh, make_TCKs.sh |
| ImageMath (ANTs) | make_VOIs.sh, make_VOIs_4Temp.sh |
| WarpImageMultiTransform (ANTs) | make_VOIs.sh, make_VOIs_4Temp.sh |
| mri_convert | make_VOIs.sh, make_VOIs_4Temp.sh |
| mri_annotation2label | make_VOIs.sh, make_VOIs_4Temp.sh |
| mri_aparc2aseg | make_VOIs.sh, make_VOIs_4Temp.sh |
| freeview | comments only (.trk output is for freeview) — no direct invocation found in KUL_FWT itself |
| scil_reco_bundles | make_VOIs.sh, make_VOIs_4Temp.sh |
| scil_bundle_compute_centroid | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_bundle_reject_outliers | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_bundle_uniformize_endpoints | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_bundle_label_map | make_TCKs.sh (or _4Temp — single occurrence) |
| scil_filter_tracts | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_tractogram_convert | make_TCKs.sh (soft dep) |
| scil_tractogram_detect_loops | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_tractogram_filter_by_roi | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_tractogram_segment_with_recobundles | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_tractogram_smooth | make_TCKs.sh, make_TCKs_4Temp.sh |
| scil_vis_mosaic, scil_viz_bundle_screenshot_mni, scil_viz_bundle_screenshot_mosaic | make_TCKs.sh, make_TCKs_4Temp.sh |
| dipy (Python) | KUL_FWT_buan_profile.py, KUL_FWT_FBC_4TCKs.py, KUL_FWT_morphometrics.py, KUL_FWT_plot_bundle_connectivity.py, KUL_FWT_SCs_TCKs.py, KUL_FWT_TCKsm_cap.py |
| nibabel | KUL_FWT_buan_profile.py, KUL_FWT_FBC_4TCKs.py, KUL_FWT_morphometrics.py, KUL_FWT_plot_bundle_connectivity.py, KUL_FWT_SCs_TCKs.py, KUL_FWT_TCKsm_cap.py, KUL_FWT_bundle_spider_plot.py, KUL_Voxel_mask_segment.py |
| nilearn (plotting) | KUL_FWT_SCs_TCKs.py, KUL_FWT_TCKsm_cap.py |
| scikit-image (skimage.measure) | KUL_FWT_morphometrics.py |
| scikit-learn (sklearn.decomposition.PCA) | KUL_Voxel_mask_segment.py, dev_work variants |
| matplotlib | KUL_FWT_buan_profile.py(lazy), KUL_FWT_bundle_spider_plot.py, KUL_FWT_plot_bundle_connectivity.py, KUL_FWT_plot_fixel_bundle_metrics.py, KUL_FWT_SCs_TCKs.py |
| pandas | KUL_FWT_plot_fixel_bundle_metrics.py |
| PIL/Pillow | KUL_FWT_bundle_report.py |
| pdf2image | KUL_FWT_plot_fixel_bundle_metrics.py |
| scipy | KUL_FWT_FBC_4TCKs.py, KUL_FWT_SCs_TCKs.py |
