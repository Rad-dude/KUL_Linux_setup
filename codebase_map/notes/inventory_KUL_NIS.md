# Inventory Report: src/KUL_NIS

(Produced by inventory subagent; saved verbatim for use by the extractor and diagram phases. See PLAN.md for context.)

Scope covered in depth: the 51 top-level `.sh`/`.py` files, `KUL_DTI_ALPS/`, `VSC/`, `tools/` (both subdirs), and the `share/` code (rsfmri_pipeline, dsc, nilearn, spm12) — 84 files. `atlases/` (3 `.py` LUT-generator scripts + LUT/atlas data), `studies/cappelle2021/` and `studies/verhaaren2022/` (7 one-off study scripts), `study_config/`, and `docs/` treated as data/study-specific — logged for existence only.

## 0. Naming/structural conventions to hard-code into the extractor

1. **Universal preamble** (~40 of the 45 top-level .sh entry points):
   ```
   kul_main_dir=$(dirname "$0")
   script=$(basename "$0")
   source $kul_main_dir/KUL_main_functions.sh
   ```
   (some older scripts use backtick form; a few — `KUL_bids_summary.sh`, `KUL_lesion_fs_recall.sh`, `KUL_reg_pwi_2_T1.sh`, `KUL_conn_make_nets.sh`, `KUL_anat_b2subject.sh`, `KUL_VSC_prepare_dwiprep.sh`, `KUL_radsyndisco.sh` — skip this preamble entirely; treat that omission as a dev/orphan-script signal). Recognize this exact 3-line (or 2-line) shape as "sources KUL_main_functions.sh" without needing per-line regex variety.
2. **`function Usage { cat <<USAGE ... USAGE exit 1 }`** immediately after the preamble marks a real entry point; presence of `getopts "..."` confirms it. Files with neither are one-offs.
3. **Two distinct sibling-call idioms, both need resolving to the same node**:
   - Explicit path: `${kul_main_dir}/KUL_X.sh` or `$kul_main_dir/KUL_X.sh` (e.g. `KUL_FS_multiparc.sh`, `KUL_dsc_perfusion.sh`, `KUL_DTI_ALPS/KUL_calc_DTIALPS.sh`, `KUL_fmri_denoise.sh`, `KUL_nii2dcm.py`, `KUL_FAT1w.py`, `share/nilearn/KUL_nilearn_glm.py`).
   - **Bare name relying on PATH** (installer puts `kul_main_dir` itself, plus the sibling KUL_VBG and KUL_FWT checkouts, on PATH): `KUL_VBG.sh`, `KUL_FWT_make_VOIs.sh`, `KUL_FWT_make_TCKs.sh`, `KUL_FWT_FBC_4TCKs.py`, and most in-repo calls (`KUL_dcm2bids.sh`, `KUL_preproc_all.sh`, `KUL_anat_segment_tumor.sh`, `KUL_dwiprep_anat.sh`, `KUL_dwiprep_MNI.sh`, `KUL_fmriproc_*.sh`, `KUL_run_rsfMRI_networks.sh`, `KUL_mrview_figure.sh`, `KUL_synb0.sh`→`KUL_radsyndisco.sh`, `KUL_karawun_prepare.sh`, `KUL_anat_register.sh`, `KUL_anat_biascorrect.sh`). **The extractor cannot tell these apart from a plain word in a string without a known-script-name allowlist** — build one from the enumerated file list and match bare tokens against it; this is exactly how the KUL_VBG/KUL_FWT cross-project edges must be detected (no `source`/explicit path to grep).
   - Both idioms typically assigned to `task_in="..."` then run via `KUL_task_exec` (from `KUL_main_functions.sh`) — `task_in=` assignment is the highest-value grep anchor, not direct invocation.
4. **Indirection via resolved-at-runtime path variables**: `_fs_multiparc="${kul_main_dir}/KUL_FS_multiparc.sh"` then `task_in="${_fs_multiparc} ..."` a few lines later (`KUL_clinical_fmridti.sh:3024/3028`); `nilearn_glm_script="$kul_main_dir/share/nilearn/KUL_nilearn_glm.py"` then `cmd="$python_exe \"$nilearn_glm_script\" ..."` (`KUL_fmriproc_nilearn_new.sh:398/469`, second indirection on `$python_exe`, resolved from conda-env activation). Extractor should do a two-pass: collect `varname=".../KUL_X.sh"`-shaped assignments first, then substitute into later `task_in=`/`cmd=`/direct-call lines in the same file.
5. **Function name collisions with real script names**: `KUL_dwiprep.sh` defines local helper functions `kul_dwi2mask` and `kul_mrview_figure` (lowercase-first) that are NOT calls to `KUL_mrview_figure.sh` — don't let a fuzzy match conflate them. Nearly every entry point locally (re)defines its own `KUL_antsApply_Transform` — intra-file helper functions, not edges.
6. **getopts flag letters not standardized** across files — don't build a single flag schema, just capture the raw getopts string per file.
7. Two same-basename files in two locations with diverging content: `KUL_fmriproc_nilearn_new.sh` (top level, 713 lines, current) vs `share/nilearn/KUL_fmriproc_nilearn_new.sh` (515 lines, older — missing `-c` auto-core-scheduling and `KUL_PYFMRI_ENV` convention). Treat as two distinct nodes; flag the share/ copy as stale.

## 1. Entry points

### Master orchestrator

**KUL_clinical_fmridti.sh** (3784 lines) — top-level clinical pipeline driver; given `-p participant -t <1-7>` scaffolds a study, converts DICOM→BIDS, runs fmriprep/dwiprep/freesurfer/fastsurfer, tumor segmentation, VBG, multiparc, FWT tractography, fMRI GLM (SPM or nilearn), DSC perfusion, DTI-ALPS, PACS/Karawun export.
- getopts: `"p:t:d:n:v:R:F:O:a:f:T:D:S:P:E:NC:y:m:XBrseUQW"`
- Functions: Usage, KUL_scaffold, KUL_resolve_lesion, KUL_copy_lesion_to_anat, KUL_make_pacs_dropdirs, KUL_check_redo, KUL_verify_results, KUL_check_pyfmri_env, KUL_antsApply_Transform, KUL_pad_anat, KUL_convert2bids, KUL_check_data, KUL_rigid_register, KUL_run_fmriprep, KUL_run_dwiprep, KUL_run_freesurfer, KUL_run_fastsurfer, KUL_segment_tumor, KUL_run_VBG, KUL_run_multiparc, KUL_run_FWT, KUL_anatomical_biascorrect, KUL_register_anatomical_images, KUL_clear_cT1w, KUL_fmriproc, KUL_run_rsfMRI_networks, KUL_run_dsc, KUL_run_dwiprep_anat, KUL_run_dwiprep_MNI, KUL_calc_DTI_ALPS, KUL_run_cT1w_subtraction
- Local calls out (mostly bare via PATH, a few explicit path): `KUL_dcm2bids.sh` (bare), `KUL_preproc_all.sh` (bare, ×3 fmriprep/dwiprep/freesurfer), `KUL_anat_segment_tumor.sh`, `KUL_anat_biascorrect.sh`, `KUL_anat_register.sh`, `KUL_mrview_figure.sh` (several), `${kul_main_dir}/KUL_FS_multiparc.sh` (explicit, via `$_fs_multiparc`), `KUL_fmriproc_nilearn_new.sh`/`KUL_fmriproc_spm_new.sh`/`KUL_fmriproc_conn.sh` (bare, dispatched by `-E`), `KUL_run_rsfMRI_networks.sh` (bare), `${kul_main_dir}/KUL_dsc_perfusion.sh` (explicit), `KUL_dwiprep_anat.sh`, `KUL_dwiprep_MNI.sh` (bare), `${kul_main_dir}/KUL_DTI_ALPS/KUL_calc_DTIALPS.sh` (explicit), `$kul_main_dir/KUL_nii2dcm.py` (explicit, via `_nii2dcm_script`), `KUL_karawun_prepare.sh` (bare), and re-invokes itself recursively per processing-type.
- Cross-project: `KUL_VBG.sh` (bare, via task_in, function KUL_run_VBG); `KUL_FWT_make_VOIs.sh`/`KUL_FWT_make_TCKs.sh` (bare, via task_in, function KUL_run_FWT).
- External tools: recon-all, run_fastsurfer.sh/docker fastsurfer, docker (hd-glio-auto indirectly), antsRegistration, mrcalc/mrgrid/mrthreshold, dwifslpreproc, topup, bet, dwigradcheck, matlab (via SPM path), 7z, synb0 (mentioned).

### DICOM→BIDS family
- **KUL_dcm2bids.sh** (v1.0, 2023, current) — DICOM→BIDS wrapping `Dcm2Bids` + `dcm2niix`. getopts `"c:d:p:o:s:t:aveh"`. Functions: Usage, kul_dcmtags, kul_find_relevant_dicom_file. Called (bare) by KUL_clinical_fmridti.sh.
- **KUL_dcm2bids_new.sh** (v0.9, 2021, despite name is OLDER than KUL_dcm2bids.sh) — near-identical; getopts `"c:d:p:o:s:t:avehx"`. Functions: Usage, kul_dcmtags, kul_find_relevant_dicom_file. Actively called (bare) by KUL_multisubjects_dcm2bids.sh line 214 — **the multi-subject wrapper calls the stale "_new" variant, not current KUL_dcm2bids.sh**, likely-unintentional drift, surface as an edge not silently normalized.
- **KUL_multisubjects_dcm2bids.sh** — wraps KUL_dcm2bids_new.sh over a CSV of subjects. getopts `"d:c:o:veth"`.
- **KUL_dcm2bids.py** — argparse CLI using mrconvert; standalone DICOM-series-level nifti+tag helper. Function: getDicomTag. **Orphan**: no .sh invokes it.

### dMRI preprocessing family (dwiprep)
- **KUL_dwiprep.sh** (1.4k+ lines, v1.4) — core diffusion preprocessing: denoise, degibbs, bias-correct, dwifslpreproc(topup+eddy), upsample, register to T1w, tensor/FOD fitting (dhollander/tax/tournier/lore_sd). getopts `"p:s:n:d:e:m:v:x:f:M:rbcu"`. Functions: Usage, KUL_dwiprep_convert, kul_dwi2mask(local), kul_mrview_figure(local, NOT the script). Calls out: KUL_synb0.sh (bare, task_in), KUL_mrview_figure.sh (bare). Tools: mrconvert, mrcalc, mrcat, mrmath, mrtransform, dwifslpreproc, dwidenoise, dwibiascorrect, mrdegibbs, dwi2mask, dwi2response, dwi2fod, dwi2tensor, tensor2metric, tckgen, voxel2fixel, dwigradcheck, topup.
- **KUL_dwiprep_anat.sh** — registers dwi to T1w/anatomy + FreeSurfer. getopts `"p:n:s:m:vMh"`. Calls KUL_mrview_figure.sh (bare). Tools: mrgrid, mrcat, mrthreshold, mrtransform, dwiextract, 5ttgen, warpinit, labelconvert, mri_convert, mri_annotation2label, antsRegistration, antsApplyTransforms, ConvertTransformFile, `source $FREESURFER_HOME/SetUpFreeSurfer.sh`.
- **KUL_dwiprep_MNI.sh** — warps FA/dMRI-derived maps to MNI. getopts `"p:n:s:vh"`. No sibling calls; relies on fmriprep's warp.
- **KUL_dwiprep_fibertract.sh** — per-subject deterministic/probabilistic tractography (early named-project style). getopts `"p:c:r:s:n:w:fvh"`. Functions: Usage, kul_mrtrix_tracto, KUL_antsApply_Transform. Tools: tckgen, tckedit, tckmap, fslmerge, fslmaths, mrstats, antsApplyTransforms.
- **KUL_dwiprep_FT.sh** — variant fiber-tracking script "for S61759" (named-project one-off). getopts `"p:s:o:n:vh"`. Functions: Usage, KUL_antsApply_Transform, kul_mrtrix_FT. Tools: 5ttgen, tcksift, tckedit, tckmap, mri_convert, mri_annotation2label, antsApplyTransforms.
- **KUL_dwiprep_group_fba.sh** (current, v1.0 2021) — group fixel-based analysis. getopts `"n:g:t:a:v"`. Tools: dwi2response, dwi2fod, mtnormalise, population_template, responsemean, dwi2mask, tcksift, tckgen, mrtransform, dwi2tensor, tensor2metric.
- **KUL_dwiprep_group_fba_bkup.sh** — dev/backup duplicate, older algorithm options. Classify deprecated, superseded-by KUL_dwiprep_group_fba.sh.

### fMRI processing family
- **KUL_fmriproc_conn.sh** — melodic-based automated fMRI analysis assuming fmriprep+AROMA output. getopts `"p:s:v:"`. Functions: Usage, KUL_antsApply_Transform, KUL_compute_melodic. Calls out: `$kul_main_dir/KUL_fmri_denoise.sh` (explicit path, task_in). Tools: fsl_glm, antsApplyTransforms, mrinfo.
- **KUL_fmriproc_nilearn_new.sh** (current, 713 lines) — MATLAB-free first-level task-fMRI GLM via nilearn. getopts `"p:s:S:P:c:j:J:n:T:C:v:"`. Functions: Usage, KUL_antsApply_Transform, KUL_throttle, KUL_populate_SPM_results, KUL_tsv_filter, KUL_prep_run, KUL_compute_nilearn. Calls out: `$python_exe "$nilearn_glm_script"` where `nilearn_glm_script="$kul_main_dir/share/nilearn/KUL_nilearn_glm.py"` (two-hop indirection). Tools: susan, slicer, fslstats, antsApplyTransforms, tedana, matlab (stale help text only), mrinfo.
- **KUL_fmriproc_spm_new.sh** — task-fMRI GLM via MATLAB/SPM12. getopts `"p:s:S:P:c:j:J:T:v:"`. Functions: Usage, KUL_antsApply_Transform, KUL_throttle, KUL_threshold_SPM_Bizzi, KUL_tsv_filter, KUL_prep_run, KUL_compute_SPM_matlab. Calls out (implicit, via matlab -r): share/spm12/*.m job scripts. Tools: matlab, spm12, susan, slicer, fslstats, antsApplyTransforms, tedana.
- **KUL_fmri_denoise.sh** — post-fMRIPrep confound regression + bandpass + SUSAN smoothing; `--method nilearn|fsl`. No getopts, no Usage, no KUL_main_functions.sh source (self-contained `set -euo pipefail`). Called (explicit path) from both KUL_fmriproc_conn.sh and KUL_run_rsfMRI_networks.sh. Tools: fsl_glm, fslmaths (susan/bptf), fmriprep (reads confounds TSVs).
- **KUL_fmri_scrubbing.sh** — DVARS/FD-based scrubbing of resting-state fMRI. getopts `"p:n:s:d:f:l:r:c:o:v"`. Tools: mrconvert, csvkit, fmriprep.
- **KUL_make_fMRI_labels.sh** — interactive menu-driven one-off helper for hand-adding a single fMRI activation label to a Karawun folder; header says "NOT part of the automatic pipeline." No getopts/Usage/main_functions source. Classify entry point (manual utility).
- **KUL_run_rsfMRI_networks.sh** — presurgical/eloquent-cortex rsfMRI network mapping; denoises BOLD runs then drives share/rsfmri_pipeline/. getopts `"p:c:P:Iv:"`. Calls out: `$kul_main_dir/KUL_fmri_denoise.sh` (explicit path), `bash $pipeline_dir/src/step0_synthseg.sh`, `python3 $pipeline_dir/src/run_pipeline.py --steps 1 2 3`, `python3 $pipeline_dir/src/step5_lite_report.py` (all `$pipeline_dir="$kul_main_dir/share/rsfmri_pipeline"`). Sets `RSFMRI_VBG_DIR="$cwd/KUL_VBG"` env var consumed by step0_synthseg.sh (indirect cross-project data dependency on KUL_VBG's *output* directory, not a call). Tools: SynthSeg (via step0), fmriprep, antsApplyTransforms.

### Anatomical / registration family
- **KUL_anat_biascorrect.sh** — N4 bias-correct structural BIDS images. getopts `"p:v:s:"`. Functions: Usage, KUL_check_data, KUL_biascorrect, KUL_biascorrect_anat_images. Tools: N4BiasFieldCorrection.
- **KUL_anat_register.sh** — rigid/affine/SyN registration to T1w. getopts `"p:t:s:i:o:n:v:d:m:r:cw"`. Functions: Usage, KUL_antsApply_Transform, KUL_check_data, KUL_rigid_register, KUL_affine_register, KUL_warp2MNI, KUL_register_anatomical_images. Tools: antsRegistration, antsRegistrationSyN, antsApplyTransforms, hd-bet, bet, ConvertTransformFile.
- **KUL_anat_lesionheatmap.sh** — group lesion heat map after tumor segmentation + fmriprep MNI normalisation. getopts `"p:a:n:v:c"`. Calls out: KUL_anat_register.sh (bare, line 201). Tools: mrmath, fmriprep (warp), antsApplyTransforms.
- **KUL_anat_segment_tumor.sh** — AI-based tumor/resection-cavity segmentation. getopts `"p:v:R"`. Functions: Usage, KUL_antsApply_Transform, KUL_check_data, KUL_hd_glio_auto, KUL_resseg, KUL_fast, KUL_fastsurfer. Calls out: KUL_mrview_figure.sh (bare). Tools: docker (hd-glio-auto), HD-BET/hd-bet, resseg, fast, run_fastsurfer/fastsurfer, mrgrid, mrcalc, antsApplyTransforms, antsRegistrationSyN.
- **KUL_anat_b2subject.sh** — tiny 14-line positional-arg script (no getopts/Usage/main_functions source): warps MNI-space image back to subject space via fmriprep's inverse transform. Tools: antsApplyTransforms, fmriprep (`.h5` transform). Classify borderline entry-point/dev.
- **KUL_T1T2FLAIRMTR_ratio.sh** — T1/T2, T1/FLAIR, MTR ratio computation (Ganzetti/Pareto method). getopts `"p:s:f:n:d:acmv"`. Functions: Usage, KUL_antsApply_Transform, KUL_antsApply_Transform_MNI, KUL_iso_biascorrect, KUL_MTI_reorient_crop_hdbet_iso, KUL_rigid_register, KUL_reg2t1, KUL_computeratio, KUL_apply_warp2mni, KUL_MTI_register_computeratio. Tools: N4BiasFieldCorrection, antsRegistration/antsRegistrationSyN, hd-bet/HD-BET, bet, run_fastsurfer/fastsurfer, samseg, run_samseg, fslstats.
- **KUL_MS_lesion_stats.sh** — MS lesion map stats via FreeSurfer SAMSEG + MTR/T1T2/T1FLAIR ratios (named-study script, generalized). getopts `"p:s:n:t:argv"`. Functions: Usage, KUL_create_results_file, KUL_compute_stats. Tools: samseg, fastsurfer/run_fastsurfer.
- **KUL_lesion_fs_recall.sh** — explicit "dev Alpha" header, WIP for named project S61759: FreeSurfer recon-all on lesioned brains via lesion-fill-and-swap. getopts `"p:a:t:f:l:z:s:o:m:n:bvh"`, but `source KUL_main_functions.sh` line is **commented out**; self-locates via `which KUL_lesion_fs_recall.sh`. Tools: antsRegistration, antsBrainExtraction, N4, recon-all, mri_convert, mri_annotation2label, fslmaths, fslstats. Classify dev/WIP, superseded by KUL_VBG + KUL_FS_multiparc.sh.
- **KUL_FS_multiparc.sh** — FreeSurfer recon-all + multi-scale parcellation for non-lesioned subjects (types 4/5/6, no VBG). getopts (long-form) `":s:f:i:n:Xvh"`. Uses local `atlases_dir="${script_dir}/atlases"` (KUL_NIS's OWN atlases/ dir, NOT reaching into KUL_VBG despite a stale header comment claiming "atlases live in sibling KUL_VBG_latest repo" — **doc/code mismatch, flag for MAP.md**). Tools: recon-all, run_fastsurfer, mri_surf2surf, segment_subregions.

### DSC perfusion family
- **KUL_dsc_perfusion.sh** (current, v1.0) — full DSC-MRI perfusion pipeline. getopts `"p:d:a:l:F:I:e:r:b:P:y:n:v:LR"`. ~25 local functions (KUL_dsc_* family, see full list in source). Calls out: `python3 ${kul_main_dir}/share/dsc/KUL_dsc_fit.py` (explicit path subprocess), KUL_mrview_figure.sh (bare, guarded by command -v). References `$cwd/BIDS/derivatives/KUL_compute/.../KUL_VBG/output_VBG/...` as read-only data dependency on KUL_VBG's output (not a call). Tools: ANTs (antsMotionCorr, N4, antsRegistration), FreeSurfer (mri_synthstrip, mri_vol2vol), MRtrix3 (mrconvert, mrcalc, mrgrid, dwidenoise, mrstats).
- **share/dsc/KUL_dsc_fit.py** — DSC-MRI quantification worker (dR2*, BSW leakage correction, SVD deconvolution). Library/helper invoked as subprocess by KUL_dsc_perfusion.sh. Docstring: vectorised rewrite of tools/KUL_DSC_analysis/Good_DSCLC_fit5.py.

### Tractography / Karawun export family
- **KUL_tracts_ocd.sh** — generates slMFB/ATR tracts for OCD patients (named-project script). No getopts. Functions: KUL_antsApply_Transform, KUL_make_fs_roi, KUL_tckgen. Calls out: KUL_FWT_FBC_4TCKs.py (bare, cross-project, via cmd=). Tools: mrcalc, mrmath, tckgen, tcksift2, tckmap, antsApplyTransforms.
- **KUL_karawun_prepare.sh** (current, v0.3) — prepares fMRI/DTI results for Brainlab Elements Server via Karawun. getopts `"p:t:r:va"`. Functions: Usage, KUL_karawun_get_tract, KUL_karawun_get_voi, KUL_karawun_auto_discover_tracts. Calls out: `"${kul_main_dir}/KUL_FAT1w.py"` (explicit path). References both KUL_VBG FreeSurfer output and KUL_FS_multiparc.sh output as alternative FS-subregion sources. Tools: karawun, mri_vol2vol, segment_subregions, mrgrid, mrcalc, mrstats, tckstats, antsApplyTransforms.
- **KUL_karawun2brainlab.sh** (v0.1, 2020) — earlier/simpler Karawun export, superseded by KUL_karawun_prepare.sh. getopts `"p:sv"`. Classify likely-superseded standalone entry point.
- **KUL_mrview_figure.sh** — generic visualisation/screenshot utility (mrview single view, TRA/SAG/COR PNGs, or montage). getopts `"p:u:o:d:f:a:t:v:"`. Function: KUL_mrview. Heavily reused: called (bare) by ~10 other scripts (KUL_anat_segment_tumor.sh, KUL_dsc_perfusion.sh, KUL_dwiprep.sh, KUL_dwiprep_anat.sh, KUL_clinical_fmridti.sh, KUL_conn_make_nets.sh) — effectively acts as a shared library despite being invoked as a subprocess, not sourced.

### qsiprep / connectome / synb0 (docker-based) family
- **KUL_MRtrix3_connectome.sh** — runs mrtrix3_connectome docker pipeline. getopts `"p:s:n:l:gv"`. Tools: docker, mrtrix_connectome.
- **KUL_qsiprep.sh** — runs qsiprep or mrtrix_connectome via docker. getopts `"w:p:s:n:m:t:gv"`. Tools: docker, qsiprep, mrtrix_connectome, dwiextract.
- **KUL_synb0.sh** — runs synb0-disco via docker. getopts `"p:s:m:n:cv"`. Calls out: KUL_radsyndisco.sh (bare, line 258, docker-free fallback). Tools: docker, synb0, hd-bet, mri_synthstrip, topup, fslmerge, dwiextract.
- **KUL_radsyndisco.sh** — docker-free synb0-disco re-implementation; own inline task_exec (not KUL_task_exec), no KUL_main_functions.sh source, no getopts, TODOs in header. Classify dev/WIP. Tools: topup, fslmaths, fslmerge, antsRegistration, antsApplyTransforms (via a python .../inference.py call to an undefined `$sbzd_p2` path — likely broken/unfinished).
- **KUL_bids_crop.sh** — crops T1w z-axis to remove neck ("USE AT OWN RISK", destructive/irreversible). getopts `"p:n:av"`. Tools: qsiprep (motivation), mrgrid.

### DTI-ALPS
- **KUL_DTI_ALPS/KUL_calc_DTIALPS.sh** — computes DTI-ALPS index using predefined MNI spheres warped to native dMRI space. Sourced/invoked from `${kul_main_dir}/KUL_DTI_ALPS/KUL_calc_DTIALPS.sh` by KUL_clinical_fmridti.sh (function KUL_calc_DTI_ALPS, type-7 workflow). Tools: mrconvert, mrstats, ImageMath, fslmaths, fslstats, antsApplyTransforms, dwi2tensor. Ships fixed MNI ROI niftis (MNI_ROI_1_L/R.nii.gz, MNI_ROI_2_L/R.nii.gz) as data.

### Misc utility entry points
- **KUL_bids_summary.sh** — generates BIDS_info.tsv summary. No getopts; `source KUL_main_functions.sh` commented out (line 22). Tools: mrinfo.
- **KUL_linux_givebackmyfiles.sh** — one-liner sudo chown utility for docker-root-owned output dirs.
- **KUL_conn_make_nets.sh** — hardcoded-path (conn_dir=CONN/conn_project01/...) network-map extraction from CONN toolbox; positional $1, no getopts/Usage/main_functions source. Functions: KUL_antsApply_Transform, average_network. Calls out: KUL_mrview_figure.sh (bare). Tools: mrcalc, mrmath, antsApplyTransforms. Classify dev/one-off.
- **KUL_reg_pwi_2_T1.sh** — hardcoded-path (commented-out `/Users/xm52195/data/Laura`) one-off; no Usage/getopts/main_functions. Tools: mrresize, bet, mrconvert, fslmaths, antsRegistration, antsApplyTransforms, mrfilter. Classify dev/one-off.
- **tools/send_2_orthanc.sh** — sends extracted DICOM zips to Orthanc PACS via dcmsend; placeholder credentials need manual editing. `source ~/.bashrc`. Tools: 7z, dcmsend (DCMTK, new tool). Classify entry point (manual utility), flag credential placeholders.
- **VSC/Env_T1T2FLAIRMTR_cpu.sh**, **VSC/Env_T1T2FLAIRMTR_gpu.sh** — meant to be *sourced* to set up VSC/HPC environment: FreeSurfer env vars, `source $FREESURFER_HOME/SetUpFreeSurfer.sh`, adds KUL_NIS to PATH (`export PATH=${VSC_DATA}/apps/KUL_NeuroImaging_Tools:$PATH` — the actual PATH-injection mechanism for the VSC/HPC deployment target), `module load MRtrix/... ANTs/...`. Classify environment/library, not a runnable pipeline stage.
- **KUL_VSC_prepare_dwiprep.sh** — broken/incomplete fragment: malformed shebang (leading whitespace), references undefined `$conf`/`$silent`/`$kul_main_dir`/`$task_command`, copies a nonexistent `VSC/master_dwiprep.pbs` template. Classify dev/deprecated (unfinished HPC/PBS job-prep, v0.1 2020).

### rsfmri_pipeline entry points (share/rsfmri_pipeline/src/)
- **step0_synthseg.sh** — runs mri_synthseg, 5ttgen, MNI warp, tissue-map union, subject Yeo17 atlas per subject. Invoked via `bash $pipeline_dir/src/step0_synthseg.sh --subjects <ID>` from KUL_run_rsfMRI_networks.sh. Reads `RSFMRI_VBG_DIR` env var (default `${BASE_DIR}/KUL_VBG`) — data dependency on KUL_VBG output. Tools: mri_synthseg, 5ttgen, flirt, mrconvert, mrcalc, mrmath, mrinfo, mrstats, ImageMath, antsApplyTransforms, mri_convert.
- **run_pipeline.py** — top-level Python orchestrator for steps 1-4; **imports step1-4 as in-process function calls, not subprocesses**: `from step1_sba import main as run_step1` etc. — distinct edge type (in-process import-call) vs subprocess/shell. Invoked via `python3 $pipeline_dir/src/run_pipeline.py --steps 1 2 3` by KUL_run_rsfMRI_networks.sh (note: `--steps 4` i.e. step4_compare is never invoked from that caller — reachable only via manual use).
- **step1_sba.py** (seed-based analysis), **step2_rsn_fc.py** (RSN-level FC matrix + whole-brain maps), **step3_masked_ica.py** (RSN-masked ICA) — dual-natured: importable module and independently runnable. All `from config import (...)` and `from utils import (...)`.
- **step3b_whole_brain_ica.py** — whole-brain unconstrained ICA; NOT imported by run_pipeline.py — standalone-only, manual invocation.
- **step4_compare.py** — normative z-score comparison; imported by run_pipeline.py but not exercised by KUL_run_rsfMRI_networks.sh's call (steps 1-3 only).
- **step5_report.py** — full normative PDF report (needs step4 output); standalone entry, and a library for step5_lite_report.py (`from step5_report import (_mni_bg, _patient_bg, _peak_mm, _mm_to_vox, _plot_ortho, _plot_ortho_and_axial_montage, _fig_to_buf, _add_section_divider, _add_lr_labels)`) — in-repo Python-to-Python import edge between two "step" scripts.
- **step5_lite_report.py** — patient-own-data PDF/HTML report not requiring step4's normative baseline. Invoked via `python3 $pipeline_dir/src/step5_lite_report.py` by KUL_run_rsfMRI_networks.sh. Imports step5_report and config/utils.
- **config.py** — library, not runnable; defines CONDITION_PROFILES, SEED_CATALOG, get_profile, path constants (overridable via RSFMRI_* env vars), `_resolve_fsldir()` shells out to `shutil.which("flirt")` if $FSLDIR unset.
- **utils.py** — library, not runnable; ~45 functions imported by every step. Uses `subprocess.run` once (line 316) — worth checking which binary at extraction time.

### Other Python entry points (top level)
- **KUL_EDs_b2masks.py** — standalone argparse CLI (distance tool for binary NIfTI masks: min-Euclidean/Hausdorff/95th-pct-Hausdorff/ASSD, multi-class, parallel via ProcessPoolExecutor/ThreadPoolExecutor). ~20 functions. Calls `mrview` as subprocess (via `_make_mrview_snapshot`); imports optional vtk, subprocess, shutil lazily.
- **KUL_FAT1w.py** — argparse CLI computing FAT1w (sqrt(FA)×T1w) via MRtrix3 subprocess calls (mrgrid, mrfilter, mrcalc — list-form subprocess.run). Called (explicit path) by KUL_karawun_prepare.sh.
- **KUL_nii2dcm.py** — NIfTI→DICOM conversion (PACS/Karawun export) built on SimpleITK. Functions: _resolve_codec, _dcm_str, _axis_offset_and_dir, compute_slice_geometry, _attach_modality_lut, _ds16, _ds, writeSlices (+more). Called (explicit path via `_nii2dcm_script`) by KUL_clinical_fmridti.sh's `-R` flag. Uses `share/envs/KUL_dicom.yml` conda env (`KUL_dicom`, referenced from KUL_main_functions.sh's `KUL_DICOM_ENV` variable).
- **KUL_BIDS_clean.py** — standalone (no argparse, hardcoded `bidsdir = './BIDS'`) dedup of multiple T1w/T2w/FLAIR per subject via JSON sidecars. Orphan: not invoked by any other script.
- **KUL_eddy_squad.py** — standalone QC viz for eddy-squad JSON output (violin plots via seaborn/matplotlib), invoked via sys.argv not argparse. Functions: read_json_files, create_combined_violin_plot, write_to_text_file. Orphan: not invoked by any .sh; manual QC tool.

## 2. Library / helper files

- **KUL_main_functions.sh** — sourced by ~40 of the 45 top-level entry points; central shared library. Functions: `KUL_task_exec` (parallel task runner with per-task logging, the near-universal execution wrapper — most cross-script/cross-project calls flow through `task_in="..."` + `KUL_task_exec`), `find_first_match`, `is_conda_env_activated`, `KUL_conda_bootstrap`, `KUL_activate_conda_env`, `kul_echo`, `kul_e2cl`, `KUL_check_participant`. Sets globals on source: `kul_main_dir`, `cwd`, `script_start_time`, `KUL_DEBUG`, `KUL_PYFMRI_ENV`(default pyfMRI), `KUL_SCILPY_ENV`(default scilpy), `KUL_LORESD_ENV`(default lore_sd), `KUL_DICOM_ENV`(default KUL_dicom), `log_dir`, `log`. Does an mrtrix3-version compatibility check (shells out to mrconvert/dwi2mask on load) — every sourcing script indirectly touches these two binaries at startup, worth a special-cased edge.
- **share/rsfmri_pipeline/src/config.py** and **utils.py** — pure Python libraries, imported never run directly.
- **share/dsc/KUL_dsc_fit.py** — library from extractor's perspective (has main()/argparse but only ever reached via KUL_dsc_perfusion.sh's subprocess call).
- **share/nilearn/KUL_nilearn_glm.py** — subprocess-only worker for KUL_fmriproc_nilearn_new.sh.
- **VSC/Env_T1T2FLAIRMTR_cpu.sh / _gpu.sh** — meant-to-be-sourced HPC environment setup, not pipeline logic.
- **share/spm12/*.m** (13 files, light treatment): `spm12_fmri_stats_{1,2,3}run.m` + `_job.m` variants, `spm12_new_fmri_stats_{1,2,3}run.m` + `_job.m` variants, `spm12_threshold_Bizzi.m`. Invoked by KUL_fmriproc_spm_new.sh via a `matlab -r` call selecting one of these 6 stats scripts by run-count/algorithm flag — flag as unresolved/coarse edge: `KUL_fmriproc_spm_new.sh → share/spm12/<one of 6 stats scripts>`. `_job.m` files are SPM batch parameter files loaded by non-_job counterparts (.m→.m load, not a call). `spm12_threshold_Bizzi.m` implements KUL_threshold_SPM_Bizzi's MATLAB-side thresholding.

## 3. Dev / deprecated / backup

- **KUL_dwiprep_group_fba_bkup.sh** — backup/superseded by KUL_dwiprep_group_fba.sh.
- **KUL_lesion_fs_recall.sh** — "dev Alpha" header; commented-out source; superseded by KUL_VBG.
- **KUL_radsyndisco.sh** — TODO-laden header, ad hoc task_exec, undefined `$sbzd_p2` path.
- **KUL_VSC_prepare_dwiprep.sh** — broken fragment (undefined vars, malformed shebang, missing template), abandoned 2020 HPC/PBS script.
- **KUL_reg_pwi_2_T1.sh** — hardcoded personal path, no Usage/getopts.
- **KUL_conn_make_nets.sh** — hardcoded CONN/conn_project01 paths, no Usage/getopts.
- **KUL_karawun2brainlab.sh** — earliest Karawun exporter (v0.1, 2020), superseded by KUL_karawun_prepare.sh (v0.3, 2021, actively called).
- **tools/KUL_DSC_analysis/DSC_proc_script_WIP3.sh** and **Good_DSCLC_fit5.py** — WIP prototype pair for DSC perfusion, superseded by KUL_dsc_perfusion.sh + share/dsc/KUL_dsc_fit.py (the latter's docstring: "Derived from tools/KUL_DSC_analysis/Good_DSCLC_fit5.py"). DSC_proc_script_WIP3.sh calls Good_DSCLC_fit5.py via relative path `python ./Good_DSCLC_fit5.py ...` (cwd-dependent — only resolves if invoked from within tools/KUL_DSC_analysis/).
- **share/nilearn/KUL_fmriproc_nilearn_new.sh** — stale duplicate (515 lines) of current top-level 713-line version.
- **tools/setup_scripts_new/** — contains only a README.md (no code); documents that setup_environment.sh moved to an external repo KUL_Linux_setup (github.com/Rad-dude/KUL_Linux_setup) at KUL_NIS commit e9bcf40. Relevant context for the install-graph/architecture diagram — the installer is no longer inside this repo (it's now the top-level KUL_software checkout itself).

## 4. Data-only directories (noted, not deep-dived)

- **atlases/** — atlas/template data (Ganzetti2014 MNI templates+masks, Fedorenko2010, glasser HCP-MMP1 annot files, lausanne2008 LUTs) plus 3 small Python LUT-generation utilities (generate_msbp_luts.py, make_readable_lut.py, remap_lausanne_to_msbp.py) building label-conversion tables consumed by KUL_FS_multiparc.sh/KUL_dwiprep_anat.sh's labelconvert step.
- **study_config/** — per-study config templates (sequence definitions, fmriprep/dwiprep/freesurfer run-config text files, tractography ROI/tract CSVs, task event TSVs), pure data/config.
- **docs/** — per-script markdown documentation (KUL_clinical_fmridti, KUL_dcm2bids, KUL_dsc_perfusion, KUL_EDs_b2masks, KUL_karawun_prepare, KUL_nii2dcm, KUL_T1T2FLAIRMTR_ratio, KUL_anat_segment_tumor, KUL_tumour_workup) — reference material only.
- **studies/cappelle2021/** (convert2bids.sh, convert_extra2bids.sh, KUL_samseg_longitudinal.py, KUL_warp_lesions2mni.py, KUL_plot_histograms.m, KUL_plot_stats.m) and **studies/verhaaren2022/KUL_DRT_determine_position.py** — one-off named-study scripts, not part of general pipeline.

## 5. Cross-project calls into KUL_VBG / KUL_FWT (consolidated)

| Caller | Target | Invocation |
|---|---|---|
| KUL_clinical_fmridti.sh (KUL_run_VBG) | KUL_VBG.sh | bare name, via task_in+KUL_task_exec |
| KUL_clinical_fmridti.sh (KUL_run_FWT) | KUL_FWT_make_VOIs.sh, KUL_FWT_make_TCKs.sh | bare name, via task_in+KUL_task_exec |
| KUL_DRT.sh (KUL_run_FWT) | KUL_FWT_make_VOIs.sh, KUL_FWT_make_TCKs.sh | bare name, via task_in+KUL_task_exec |
| KUL_tracts_ocd.sh | KUL_FWT_FBC_4TCKs.py | bare name, via cmd= |
| KUL_dsc_perfusion.sh, KUL_karawun_prepare.sh | KUL_VBG *output tree* | data dependency, not a call |
| share/rsfmri_pipeline/src/step0_synthseg.sh | KUL_VBG *output tree* (RSFMRI_VBG_DIR) | data dependency, not a call |
| KUL_FS_multiparc.sh (header comment only) | "sibling KUL_VBG_latest repo" | **misleading comment** — actual code reads local KUL_NIS/atlases/, no real call |

No file in KUL_NIS sources/imports KUL_VBG or KUL_FWT bash libraries directly (no `source .../KUL_VBG/*.sh`) — all cross-project edges are subprocess-style invocations of standalone scripts, resolved via PATH at runtime, confirming the hub-and-spoke shape in PLAN.md.

## 6. Consolidated external-tool → calling-files table

(Counts from files-touched, not call-sites — extractor should regenerate programmatically, but this tool vocabulary is a validated starting allowlist.)

| Tool family | Binaries seen | Representative high-usage callers |
|---|---|---|
| fMRIPrep | fmriprep (28 files) | KUL_preproc_all.sh, nearly every entry point reads its outputs |
| ANTs | antsApplyTransforms(23), antsRegistration(6), antsRegistrationSyN(4), N4BiasFieldCorrection(5), antsBrainExtraction, ImageMath, antsMotionCorr, ConvertTransformFile, N4 | KUL_anat_register.sh, KUL_dsc_perfusion.sh, KUL_T1T2FLAIRMTR_ratio.sh, KUL_tracts_ocd.sh, KUL_dwiprep_anat.sh |
| MRtrix3 | mrconvert(19), mrinfo(18), mrcalc(17), mrgrid(15), mrstats(9), mrmath(8), mrview(7), mrtransform, mrcat, mrthreshold, mrfilter, mrresize, dwifslpreproc, dwi2mask, dwi2response, dwi2fod, dwiextract, dwidenoise, dwibiascorrect, mrdegibbs, dwi2tensor(5), tensor2metric(4), tckgen(6), tcksift/tcksift2, tckedit, tckmap, tckstats, labelconvert, 5ttgen(4), mtnormalise, population_template, responsemean, voxel2fixel, warpinit, dwigradcheck | KUL_dwiprep.sh, KUL_dwiprep_anat.sh, KUL_dwiprep_group_fba.sh, KUL_dwiprep_fibertract.sh/FT.sh, KUL_main_functions.sh (version check) |
| FSL | fslmaths(12), bet(7), fslstats(6), topup(5), susan(4), flirt, fslmerge, fsl_glm, slicer | KUL_fmri_denoise.sh, KUL_synb0.sh, KUL_reg_pwi_2_T1.sh, share/rsfmri_pipeline |
| FreeSurfer | recon-all(4), mri_convert(4), mri_synthseg/SynthSeg(4 each), mri_synthstrip(3), mri_annotation2label(3), mri_vol2vol, mri_surf2surf, samseg/run_samseg, segment_subregions | KUL_clinical_fmridti.sh, KUL_FS_multiparc.sh, KUL_T1T2FLAIRMTR_ratio.sh, KUL_MS_lesion_stats.sh, share/rsfmri_pipeline/src/step0_synthseg.sh |
| DICOM/BIDS | dcm2niix(3), dcm2bids(3), dcmsend(tools/send_2_orthanc.sh, DCMTK — new) | KUL_dcm2bids.sh, KUL_dcm2bids_new.sh, KUL_preproc_all.sh |
| AI segmentation | hd-bet/HD-BET(5+2), fastsurfer/run_fastsurfer(4 each), resseg, hd-glio-auto(via docker) | KUL_anat_segment_tumor.sh, KUL_clinical_fmridti.sh, KUL_T1T2FLAIRMTR_ratio.sh |
| Containers | docker(11), singularity(2) | KUL_preproc_all.sh, KUL_qsiprep.sh, KUL_MRtrix3_connectome.sh, KUL_DRT.sh(MSBP), KUL_dcm2bids*.sh |
| MATLAB/SPM | matlab(7), spm12 | KUL_fmriproc_spm_new.sh, KUL_dcm2bids*.sh(tag reading), share/spm12/*.m |
| Distortion correction | synb0(6) | KUL_synb0.sh, KUL_dwiprep.sh, KUL_qsiprep.sh, KUL_MRtrix3_connectome.sh, KUL_preproc_all.sh |
| Connectome/pipelines | mrtrix_connectome(2), qsiprep(2), mriqc(2), tedana(3) | KUL_MRtrix3_connectome.sh, KUL_qsiprep.sh, KUL_preproc_all.sh, KUL_fmriproc_nilearn_new.sh |
| Export/PACS | karawun(3), 7z(2), dcmsend(via tools/send_2_orthanc.sh) | KUL_karawun_prepare.sh, KUL_clinical_fmridti.sh, tools/send_2_orthanc.sh |
| Group ICA/misc | csvkit(1, KUL_fmri_scrubbing.sh) | — |

New tool names beyond the example list, worth adding to the extractor's curated vocabulary: `mrtrix_connectome`, `mri_synthseg`/`SynthSeg`, `resseg`, `hd-glio-auto`/`hd-glio-predict` (docker image name, not bare binary), `karawun`, `tedana`, `csvkit`, `dcmsend`(DCMTK), `7z`, `dcm2bids`(Python package/CLI, distinct from this repo's own KUL_dcm2bids.sh), `mrtrix3_connectome` docker image, `sebastientourbier/multiscalebrainparcellator`(MSBP, docker image used in KUL_DRT.sh's KUL_run_msbp).
