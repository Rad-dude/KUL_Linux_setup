# Inventory Report: src/KUL_VBG

(Produced by inventory subagent; saved verbatim for use by the extractor and diagram phases. See PLAN.md for context.)

Confirmed: `KUL_VBG.sh` only *mentions* the sibling scripts in usage text/comments — it never programmatically invokes `KUL_VBG_cook_template.sh`, `KUL_VBG_multiparc.sh`, or `KUL_synth_pats_4VBG.sh`. These are separate, independently-run entry points.

## Key cross-cutting pattern for the extractor (read this first)

Every `.sh` file in this project (except `KUL_VBG_multiparc.sh`, which uses its own `run()`/`run_soft()` wrappers around the same idea) funnels **all** external-tool and cross-file invocations through a two-step idiom:

```bash
task_in="<command and args, often multi-line with && continuations>"
task_exec        # or task_exec_soft
```

`task_exec`/`task_exec_soft` (defined once each in `KUL_VBG.sh`; `KUL_VBG_cook_template.sh` and `KUL_synth_pats_4VBG.sh` each define their own local copy of `task_exec`) do `eval ${task_in}`. **A regex extractor must treat `task_in="..."` assignments as the actual command line**, not the literal `task_exec`/`task_in` tokens — a naive scan for `^\s*<toolname>` at line-start will miss almost every external-tool call in this project, since the real invocation text lives inside a quoted (often multi-line, `\`-continued) variable assignment. Recommended heuristic: scan the *content* of `task_in="..."` blocks (matching from `task_in="` to the closing unescaped `"`) for tool binary names, in addition to normal line-start scanning.

A second indirection pattern, used only in `KUL_VBG.sh`: it resolves its own install directory at runtime via `function_path=$(which KUL_VBG.sh | rev | cut -d"/" -f2- | rev)`, then builds all its self-referential paths (`${function_path}/KUL_lesion_overlap.py`, `${function_path}/KUL_VBG_QC.py`, `${function_path}/share/luts/*.txt`, `${function_path}/atlasses/...`) off that variable. Similarly `mrtrix_path=$(which mrmath | rev | cut -d"/" -f3- | rev)` and `FS_path1=$(which recon-all | rev | cut -d"/" -f3- | rev)` resolve the mrtrix3 and FreeSurfer install roots for locating *their* shipped LUT files (`${mrtrix_path}/share/mrtrix3/labelconvert/fs_default.txt`, `${FS_path1}/FreeSurferColorLUT.txt`) — these are edges to external-tool data files, not to KUL_VBG code. Since `function_path` at runtime is always "the directory KUL_VBG.sh lives in," the extractor can safely special-case this one variable as resolving to the KUL_VBG project root rather than marking it fully "unresolved."

## Entry points

### KUL_VBG.sh (4072 lines) — the main driver
- Classification: entry-point (run directly; also the primary target invoked from outside the project).
- Purpose: Virtual Brain Grafting — excises a brain lesion from a T1 image, fills the defect with synthetic/donor tissue derived from templates and the patient's own contralateral hemisphere, then runs FreeSurfer/FastSurfer/SynthSeg parcellation on the "grafted" image and (optionally) multi-scale sub-parcellation and lesion-overlap reporting.
- Version: `v="2.0_dev_$(date +%Y%m%d)"`.
- CLI flags: `-S -a -l -z -b -s -t -E -B -P -p -H -M -O -m -o -n -v -h` (Usage() at line 75).
- Local calls out:
  - `python3 "${function_path}/KUL_lesion_overlap.py" ...` from `KUL_lesion_overlap_report` (line 1374) when `-O` set.
  - `python3 "${function_path}/KUL_VBG_QC.py" ...` (line 4049), end of run, best-effort (failure only warns).
  - `python3 "${_lausanne_dir}/remap_lausanne_to_msbp.py"` (~line 3848, `-M` block) — lives under `atlasses/New/atlases/lausanne2008/` (code-in-data-tree exception).
  - No `source`/`.` of any other KUL_VBG file. Does NOT call `KUL_VBG_cook_template.sh`, `KUL_VBG_multiparc.sh`, or `KUL_synth_pats_4VBG.sh` programmatically. The `-M` multi-scale-parcellation logic is duplicated inline (lines 3784-4037), not delegated to `KUL_VBG_multiparc.sh`.
- Functions defined (single-file-scoped): `Usage`, `KUL_shorten_SUBJECTS_DIR`, `KUL_check_FS_path_length`, `task_exec`, `task_exec_soft`, `KUL_antsRegSyN_Def`, `KUL_antsReg_SyNonly`, `KUL_lesion_overlap_report`, `KUL_E_warpback`, `KUL_antsBETp`, `KUL_synthstrip`, `KUL_Lmask_part2`, `KUL_flip_ims`, `KUL_antsAtropos`, `KUL_antsAtropos_fast`.
- External tool calls: largest surface in the project — see consolidated table. FreeSurfer (`recon-all`, `mri_convert`, `mri_synthstrip`, `mri_synthseg`, `mri_segment_hypothalamic_subunits`, `mri_surf2surf`, `mri_annotation2label`, `mri_mask`), FastSurfer (`run_fastsurfer`/`fastsurfer`), ANTs (`antsRegistration`, `antsRegistrationSyN.sh`, `antsApplyTransforms`, `antsBrainExtraction.sh`, `antsAtroposN4.sh`, `Atropos`, `ImageMath`, `WarpImageMultiTransform`), FSL (`fslmaths`, `fslstats`, `fslreorient2std`, `fslswapdim`, `fslorient`), mrtrix3 (`mrcalc`, `mrstats`, `mrthreshold`, `maskfilter`, `mrfilter`, `labelconvert`).
- Notably removed: HD-BET only in changelog/comments ("HD-BET code paths removed") — not actually invoked in this file (grep-confirmed). `mris_register`/FSL `fast` discussed in comments (FS 8.2.0 crash workaround) but run internally inside `recon-all`/`run_fastsurfer`, never called directly.
- Inferred external caller: line 544 comment names `KUL_clinical_fmridti.sh` (KUL_NIS) as a caller that always passes `-o` explicitly. No other caller named in this file.

### KUL_VBG_multiparc.sh (450 lines) — standalone multi-scale parcellation
- Classification: entry-point (independently runnable on any completed FreeSurfer SUBJECTS_DIR, not just VBG's).
- Purpose: same atlas set as `KUL_VBG.sh -M` — Lausanne2018 scales 1-5, Glasser HCP-MMP1, thalamic nuclei, brainstem substructures, hippocampus/amygdala subregions, hypothalamic subunits — plus optional lesion-overlap reporting.
- CLI: `-S <subject_id> -f <fs_subjects_dir> [-n <threads>] [-v] [-O -l <lesion_mask>]`.
- Version: `0.3 — 2026-07-01`.
- Local calls out: `python3 "${script_dir}/KUL_lesion_overlap.py" ...` (line 206, `-O`); `python3 ${remap_py} ...` (line 281, `remap_py="${lausanne_dir}/remap_lausanne_to_msbp.py"`). Resolves own dir via `script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` (robust, non-`which`-based — different pattern from KUL_VBG.sh, extractor should normalize both to "resolves to project root"). Reads `${script_dir}/share/luts/<atlas>_lut.txt` for 6 atlases. Does not call `KUL_VBG.sh` or any other top-level script.
- Functions defined: `usage()`(40), `log()`(139), `run()`(143), `run_soft()`(164), `overlap_report()`(187) — `run`/`run_soft` are this file's local equivalent of `task_exec`/`task_exec_soft` (extractor should treat both name pairs as the same pattern).
- External tool calls: `recon-all`, `mri_convert`, `mri_surf2surf`, `mri_segment_hypothalamic_subunits`, plus FS8+ `segment_subregions` (thalamus/brainstem/hippo-amygdala, named in header comment — not in the standard grep tool list, verify binary name).
- Inferred caller: none named; header states standalone use, plausible KUL_NIS calls it but unconfirmed from this file.

### KUL_VBG_cook_template.sh (279 lines) — template-cooking utility
- Classification: entry-point, manual/one-off (header says "Edit input lines in this script to specify input images," hardcodes example subject paths at lines 53/55 under `/NI_apps/KUL_VBG/share/Test_data/...`). `set -x` always on.
- Purpose: cooks a population/scanner-specific VBG template from two patients with contralateral focal lesions, for use by `KUL_VBG.sh -t`. Run once per study/scanner.
- Version: `v=0.1` (text only).
- Local calls out: none.
- Functions defined: own local `task_exec` (line 145).
- External tool calls: `hd-bet` (actively used, unlike KUL_VBG.sh), `antsBrainExtraction.sh` (alternative per comment), `mrcalc`, `WarpImageMultiTransform`, `ImageMath`, ANTs registration idioms similar to but not shared with KUL_VBG.sh.

### KUL_synth_pats_4VBG.sh (730 lines) — synthetic-patient cohort generator
- Classification: entry-point, research/dev utility. `set -x` always on.
- Purpose: generates synthetic lesioned brains for validation (combining real patients' lesions/VBG-filled images with healthy-volunteer T1s). Header text is stale/copy-pasted ("Runs whole brain TCK segmentation..."); actual Purpose block describes the synthetic-patient generation. Internal historical name in comment: `KUL_synth_cohort_gen.sh` (line 7) — treat as alias, not a separate node.
- CLI: `-P <patients_dir> -H <healthy_controls_dir> -M <lesion_masks_dir> -c <config_file> -o <output_dir> -n <ncpu> -R <registration approach 1|2|3>`.
- Version: `v=0.25 - 11092021`.
- Local calls out: none.
- Functions defined: `Usage`(14), own local `task_exec`(356).
- External tool calls: `hd-bet` (CPU/CUDA branches), `recon-all`, `mri_convert`, `fslreorient2std`, `fslmaths`, `mrstats`, `mrcalc`, `antsApplyTransforms`, `antsRegistration`.
- Config data: `share/example_synth_pats_config.txt` format consumed via `-c`.

## Library/helper files

### KUL_lesion_overlap.py (328 lines)
- Classification: dual-mode (argparse CLI + subprocess-callable). Docstring: "Standalone — can be called directly or from KUL_VBG.sh via KUL_lesion_overlap_report()."
- Purpose: per-label volumetric overlap between a parcellation image and a binary lesion mask; TSV report + optional HTML section append.
- Local calls out: none.
- External calls: pure Python/NumPy/Nibabel; `nibabel.processing.resample_from_to` in-process (no shelling to mrconvert/flirt).
- Functions: `load_lut`, `vox_vol_mm3`, `_html_header`, `_html_section`, `append_html_section`, `main`. (Grep hit `function sortTable` at line 91 is inside embedded HTML/JS, not Python — ignore.)
- Called by: `KUL_VBG.sh`, `KUL_VBG_multiparc.sh`.

### KUL_VBG_QC.py (1213 lines)
- Classification: dual-mode, designed to be invoked from `KUL_VBG.sh` at end of run.
- Purpose: QC HTML report for VBG inpainting result — overview PNGs, gradient-magnitude maps, cross-stage similarity metrics (NCC, SSIM proxy), artifact report (dark-voxel fraction, boundary sharpness, WM-intensity mismatch, stitch score) vs fixed thresholds (`_ARTIFACT_THRESHOLDS`, lines 47-53).
- Local calls out: none (consumes files KUL_VBG.sh produces via `-p <proc_VBG dir>`).
- External calls: none to binaries — matplotlib(Agg)/numpy/nibabel/scipy.ndimage in-process only.
- Functions: `_artifact_threshold`, `_artifact_is_warn_only`, `load_can`, `resample_to`, `gradient_magnitude`, `ncc`, `ssim_simple`, `percentile_nz`, `mean_nz`, `std_nz`, `norm_display`, `hex6`, `lesion_com`, `find_file`, `find_mni_template`, `render_panel`, `render_artifact_panel`, `render_metrics_summary`, `_match_mask`, `compute_per_stage_metrics`, `compute_similarity`, `compute_artifacts`, `_png_b64`, `_badge`, `write_qc_html`, `main`.
- Called by: `KUL_VBG.sh` only (line 4049), non-fatal/best-effort.

### atlasses/New/atlases/lausanne2008/remap_lausanne_to_msbp.py and siblings
- Inside the `atlasses/` data tree but `remap_lausanne_to_msbp.py` is executable code called by both `KUL_VBG.sh` (inline `-M` block) and `KUL_VBG_multiparc.sh` — worth a graph node unlike sibling `.mat`/`.nii.gz`/LUT data files. `generate_msbp_luts.py`/`make_readable_lut.py` appear to be one-off LUT-generation utilities, not invoked at runtime by any top-level script — likely dev/one-off.

## Docker/ — packaging, not call-graph

- `Docker/Dockerfile` (608 lines): multi-stage build. Vendors ANTs (`ANTS_COMMIT=40ee2d22`, `ANTsX/ANTs`), mrtrix3 (fork `Rad-dude/mrtrix3`, branch `fix/mrconvert-direct-io-arg-binding`, pinned commit), FSL (`FSL_FLAVOUR=subset`). Final stage: FreeSurfer 8.2.0 (.deb), FastSurfer (`Deep-MI/FastSurfer`, `FASTSURFER_COMMIT=700cfdc`, PyTorch `TORCH_BACKEND=cu126`), bakes in KUL_VBG from `VBG_REPO=.../KUL_VBG.git` at `VBG_BRANCH=KUL_VBG_2.0`, `VBG_COMMIT=56dc02a`. Base image `ubuntu:24.04`.
- `Docker/entrypoint.sh` (163 lines): runtime shim — locates FreeSurfer licence, exports `FREESURFER_HOME`/`FSLDIR`/`ANTSPATH`/`PATH`, checks `/tmp` writable (for `KUL_shorten_SUBJECTS_DIR`), reports GPU visibility, `exec`s the user's command (opaque — no fixed call edge to a specific KUL_VBG script).
- `Docker/build.sh` (442 lines): build-helper CLI (`--sif`, `--sif-only`, `--torch-backend`, `--fsl full|subset`, `--push`) wrapping `docker build`/`apptainer build`.
- `Docker/KUL_VBG.def`: Apptainer def, explicitly "a THIN WRAPPER over the Docker image" — `Bootstrap: docker-daemon`, `From: kul_vbg:2.0`, `%runscript` = `exec /entrypoint.sh "$@"`. Cites VBG paper (NeuroImage 2021, doi 10.1016/j.neuroimage.2021.117731).

Assessment: all four Docker files are install/packaging metadata nodes only — not part of the runtime call/dependency graph between KUL_VBG's own scripts.

## share/ — data, not code

`share/example_synth_pats_config.txt`, `share/fs2behrens_thalamus_seg_{left,right}.txt`, `share/fs2thalamus_seg_convert.txt`, `share/labelconvert/{FreeSurferColorLUT+lesion.txt, fs_default+lesion.txt}` (consumed by mrtrix3 `labelconvert` calls), `share/luts/*.txt` (11 files: brainstem, glasser×2, hippo_amygdala, hypothalamic_subunits, lausanne scale1-5, lobes, synthseg, thalamic_nuclei) consumed by `KUL_lesion_overlap.py --lut` and `KUL_VBG_multiparc.sh overlap_report()`.

`atlasses/Local/`, `atlasses/Templates_update/`, `atlasses/Thalamic_DBS_Connectivity_atlas_Akram_2018/` — template/atlas NIfTI data, referenced by path from `KUL_VBG.sh` template-selection logic (~lines 795-861). `figs4readme/` — two JPGs for README, no code relevance.

## Consolidated external-tool table

| Tool / binary | Toolkit | Called from |
|---|---|---|
| recon-all | FreeSurfer | KUL_VBG.sh, KUL_VBG_multiparc.sh, KUL_synth_pats_4VBG.sh |
| mri_convert | FreeSurfer | KUL_VBG.sh, KUL_VBG_multiparc.sh, KUL_synth_pats_4VBG.sh |
| mri_synthstrip | FreeSurfer (≥7.3) | KUL_VBG.sh (KUL_synthstrip, default BET method -B 1) |
| mri_synthseg | FreeSurfer (≥7.3) | KUL_VBG.sh (-P 4 path) |
| mri_segment_hypothalamic_subunits | FreeSurfer (≥7.2) | KUL_VBG.sh (-M block), KUL_VBG_multiparc.sh |
| mri_surf2surf | FreeSurfer | KUL_VBG.sh (-M block), KUL_VBG_multiparc.sh |
| mri_annotation2label | FreeSurfer | KUL_VBG.sh |
| mri_mask | FreeSurfer | KUL_VBG.sh |
| segment_subregions (thalamus/brainstem/hippo-amygdala) | FreeSurfer 8+ | KUL_VBG_multiparc.sh (header comment; verify binary name) |
| mris_register | FreeSurfer | not directly invoked — runs inside recon-all/run_fastsurfer |
| run_fastsurfer / fastsurfer | FastSurfer | KUL_VBG.sh (-P 2/-P 3), KUL_VBG_multiparc.sh |
| antsRegistration | ANTs | KUL_VBG.sh (KUL_antsReg_SyNonly), KUL_synth_pats_4VBG.sh |
| antsRegistrationSyN.sh | ANTs | KUL_VBG.sh (KUL_antsRegSyN_Def, KUL_antsBETp), KUL_VBG_cook_template.sh |
| antsApplyTransforms | ANTs | KUL_VBG.sh (pervasive), KUL_synth_pats_4VBG.sh |
| antsBrainExtraction.sh | ANTs | KUL_VBG.sh (-B 2 fallback), KUL_VBG_cook_template.sh |
| antsAtroposN4.sh | ANTs | KUL_VBG.sh (KUL_antsAtropos, KUL_antsAtropos_fast) |
| Atropos | ANTs | KUL_VBG.sh |
| ImageMath | ANTs | KUL_VBG.sh, KUL_VBG_cook_template.sh |
| WarpImageMultiTransform | ANTs | KUL_VBG.sh, KUL_VBG_cook_template.sh |
| fslmaths | FSL | KUL_VBG.sh (pervasive), KUL_VBG_cook_template.sh (verify), KUL_synth_pats_4VBG.sh |
| fslstats | FSL | KUL_VBG.sh |
| fslreorient2std | FSL | KUL_VBG.sh, KUL_synth_pats_4VBG.sh |
| fslswapdim | FSL | KUL_VBG.sh (KUL_flip_ims) |
| fslorient | FSL | KUL_VBG.sh (KUL_flip_ims) |
| fast (FSL FAST) | FSL | not actually invoked — only the English word in comments |
| mrcalc | mrtrix3 | KUL_VBG.sh, KUL_VBG_cook_template.sh, KUL_synth_pats_4VBG.sh |
| mrstats | mrtrix3 | KUL_VBG.sh, KUL_synth_pats_4VBG.sh |
| mrthreshold | mrtrix3 | KUL_VBG.sh |
| maskfilter | mrtrix3 | KUL_VBG.sh |
| mrfilter | mrtrix3 | KUL_VBG.sh |
| labelconvert | mrtrix3 | KUL_VBG.sh (-P parcellation-relabeling block) |
| mrmath | mrtrix3 | KUL_VBG.sh — only via `which mrmath` to resolve mrtrix_path, not actually run |
| hd-bet | HD-BET | KUL_VBG_cook_template.sh, KUL_synth_pats_4VBG.sh — actively used here even though KUL_VBG.sh removed HD-BET support |
| mrconvert, dcm2niix | mrtrix3 / dcm2niix | not used anywhere in this project (grep-confirmed) |

Not caught by the standard tool list but genuinely called: `remap_lausanne_to_msbp.py` (project-local Python), `python3` itself as dispatcher for `KUL_lesion_overlap.py`/`KUL_VBG_QC.py`.

## Summary: KUL_VBG → KUL_NIS relationship (as observed from inside KUL_VBG)

Nothing in KUL_VBG's own source calls back into KUL_NIS or KUL_FWT — consistent with the hub-and-spoke shape in PLAN.md. Only direct textual evidence of an external caller: `KUL_VBG.sh` line 544 comment naming `KUL_clinical_fmridti.sh` (KUL_NIS) as a caller that always passes `-o` explicitly. Other entry points (`KUL_VBG_cook_template.sh`, `KUL_VBG_multiparc.sh`, `KUL_synth_pats_4VBG.sh`) show no comments indicating an external caller — read as standalone/manually-run utilities. `KUL_VBG.sh`'s `-b`/BIDS-discovery mode (auto-finding `${cwd}/BIDS/${subj}/.../anat/*_T1w.nii.gz`) suggests it's designed to run inside a BIDS derivatives tree an orchestrator (KUL_NIS) has already populated — an inference from data-layout conventions, not a literal call reference.
