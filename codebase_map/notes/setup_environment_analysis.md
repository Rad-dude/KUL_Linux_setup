# setup_environment.sh analysis (install graph)

Source: `/mnt/DATA1/aradwa0/KUL_software/setup_environment.sh` (3188 lines).
This is my own analysis (not from a subagent) — feeds Phase 2 (extractor) and
the architecture diagram.

## Structure

Clean, uniform shape: one `section_<name>()` function per install unit, run in
the fixed order given by `SCRIPT_SECTIONS` (line 281), each gated through
`section_enabled()` (checks `--only`/`--skip`). No section-to-section function
calls — ordering is the only inter-section dependency, and it's implicit
(e.g. `repos` at position 18 must run before anything that expects
`$SOFTWARE_ROOT/src/KUL_NIS` to exist, but nothing enforces that in code).

33 sections in order, with the function line number and what each provides:

| order | section | line | provides |
|---|---|---|---|
| 1 | apt | 735 | build deps (system) |
| 2 | docker | 801 | Docker engine |
| 3 | nvidia | 864 | NVIDIA/CUDA driver |
| 4 | apptainer | 1021 | Apptainer/Singularity |
| 5 | vscode | 1039 | VS Code |
| 6 | miniforge | 1066 | conda/mamba base — everything after this can assume `mamba_bin`/`env_bin` helpers work |
| 7 | env-dcm2bids | 1116 | dcm2niix + dcm2bids>=3.1, installed into **base** env (deliberate — see note below) |
| 8 | clinical-pydeps | 1147 | SimpleITK/PIL/numpy/nibabel/scipy/matplotlib into **base** (for KUL_nii2dcm.py, KUL_EDs_b2masks.py) |
| 9 | env-scilpy | 1161 | conda env `scilpy`, python 3.12 |
| 10 | env-hdbet | 1197 | conda env `hd-bet-env`, python 3.10 |
| 11 | env-resseg | 1526 | conda env `resseg`, python 3.8 |
| 12 | env-hdglio | 1413 | conda env `hdglio`, python 3.9 |
| 13 | env-karawun | 1546 | conda env `KarawunDev` (KUL fork, py3.14) or `KarawunEnv` (stock, py3.8) — see `--karawun-stock` flag |
| 14 | env-fastsurfer | 1593 | FastSurfer via `uv venv` + `.venv` (NOT conda — upstream moved off conda envs) |
| 15 | env-pyfmri | 1675 | conda env `pyfMRI` (or cloned from `rsfmri_env`) |
| 16 | env-lore-sd | 1753 | conda env `lore_sd`, python 3.10, editable pip install of LoRE-SD |
| 17 | env-dicom | 1699 | conda env `KUL_dicom`, python>=3.10, simpleitk>=2.2 |
| 18 | repos | 1722 | **clones KUL_NIS / KUL_VBG / KUL_FWT at pinned branches** into `$SOFTWARE_ROOT/src/` — the repo boundary this whole mapping project cares about |
| 19 | mrtrix3 | 1771 | builds KUL fork of mrtrix3 from source (pinned commit, see README) |
| 20 | shard-recon | 1939 | mrtrix3-adjacent |
| 21 | ants | 1967 | ANTs build |
| 22 | fsl | 2017 | FSL install |
| 23 | freesurfer | 2074 | FreeSurfer (real system install, not under SOFTWARE_ROOT — symlinked) |
| 24 | leaddbs-atlases | 2246 | Lead-DBS atlases |
| 25 | spm12 | 2285 | SPM12 (MATLAB toolbox) |
| 26 | itksnap | 2327 | ITK-SNAP |
| 27 | psychopy | 2373 | PsychoPy (extra, not a KUL_NIS dependency) |
| 28 | datalad | 2412 | extra |
| 29 | awscli | 2430 | extra |
| 30 | r | 2464 | extra |
| 31 | rstudio | 2491 | extra |
| 32 | afni | 2534 | extra |
| 33 | docker-images | 2587 | builds/pulls Docker images (KUL_VBG has a Docker/Apptainer build) |
| — | bashrc | 2613 | writes the managed `~/.bashrc` block (all `PATH`/env-var exports) |
| — | verify | 2811 | pass over installed sections |

## Conda/venv environment name → consumer mapping

This is the key data for linking install sections to pipeline runtime code
(KUL_NIS/VBG/FWT scripts don't call `setup_environment.sh` sections directly —
they assume a named env already exists and `conda activate <name>` it, or
locate a binary already on `PATH`). Confirmed env names created by the
installer:

| env name | created by section | consumed by (per README/script comments) |
|---|---|---|
| `scilpy` | env-scilpy | scilpy-based DWI processing steps in KUL_NIS/KUL_FWT |
| `hd-bet-env` | env-hdbet | HD-BET skull-stripping calls |
| `hdglio` | env-hdglio | HD-GLIO-AUTO tumor segmentation |
| `resseg` | env-resseg | lesion resection segmentation |
| `KarawunDev` / `KarawunEnv` | env-karawun | `KUL_karawun_prepare.sh`, `KUL_karawun2brainlab.sh` |
| FastSurfer `.venv` (not a conda env) | env-fastsurfer | `KUL_FS_multiparc.sh`-adjacent / FastSurfer calls |
| `pyfMRI` | env-pyfmri | fMRI processing (`KUL_fmriproc_*`, `share/rsfmri_pipeline`) |
| `lore_sd` | env-lore-sd | `lore_dwi2decomposition`/`lore_decomposition2contrast`, used by `KUL_dwiprep -D run_dwiprep_lore_sd.txt` (explicit in script comment) |
| `KUL_dicom` | env-dicom | DICOM handling (SimpleITK-based) |
| miniforge **base** | env-dcm2bids, clinical-pydeps | `KUL_dcm2bids.sh`, `KUL_dcm2bids_new.sh`, `KUL_multisubjects_dcm2bids.sh`, `KUL_nii2dcm.py`, `KUL_EDs_b2masks.py` — deliberately NOT env-scoped |

Also found a **dynamic env-activation mechanism**: `KUL_main_functions.sh`
(KUL_NIS) has a `KUL_conda_bootstrap` function and an `ENV_TO_ACTIVATE`
variable (`conda activate "$ENV_TO_ACTIVATE"`, `setup_environment.sh:2444`
region and inside KUL_NIS) — i.e. some stage scripts pick their conda env at
runtime via a variable rather than a hardcoded name. This is exactly the kind
of indirection the extractor should surface as an "unresolved/dynamic" edge
(env name resolved at runtime), not silently resolve or drop.

## Invocation model for the three pipelines (important for the extractor)

`section_repos()` clones KUL_NIS/KUL_VBG/KUL_FWT into `$SOFTWARE_ROOT/src/`
and its own warning is the key fact: **the pipelines call each other and their
own sibling scripts by bare name resolved via `PATH`**, not by relative or
absolute path — `$src/KUL_NIS`, `$src/KUL_VBG`, `$src/KUL_FWT` are meant to
all be on `PATH` (per the `~/.bashrc` block `section_bashrc` writes). The
script explicitly flags one sharp edge: *"KUL_FWT's own scripts must resolve
on PATH before running KUL_clinical_fmridti.sh — it no longer auto-prepends a
sibling `../KUL_FWT` folder."* So:

- Cross-project and even many intra-project script-to-script calls in KUL_NIS
  will show up as a bare `KUL_VBG.sh ...` / `KUL_FWT_make_TCKs.sh ...` token,
  not a path — the extractor needs to treat any bare `KUL_[A-Za-z0-9_]+\.(sh|py)`
  token in command position as a call edge, resolved against the full node set
  of all three projects by filename, not by literal path matching.
- This also means correctness of the whole call graph depends on PATH being
  set up as documented — worth a callout in MAP.md as a "how this actually
  runs" note, since it's non-obvious from reading any single pipeline repo in
  isolation.

## Third-party tool → install section (for the architecture diagram's external-tool layer)

mrtrix3→`mrtrix3`, FSL commands→`fsl`, ANTs commands→`ants`, FreeSurfer
(`recon-all`, `mri_*`)→`freesurfer`, HD-BET→`env-hdbet`, HD-GLIO-AUTO→
`env-hdglio`, FastSurfer→`env-fastsurfer`, LoRE-SD→`env-lore-sd`, dcm2niix/
dcm2bids→`env-dcm2bids`, karawun→`env-karawun`, SPM12/MATLAB→`spm12`,
ITK-SNAP→`itksnap`, AFNI→`afni`, PsychoPy→`psychopy`. `shard-recon`,
`leaddbs-atlases`, `docker-images` are secondary/support sections with no
direct pipeline-script callers found yet (to confirm once the three
inventories are back).

## Open item to reconcile against the three project inventories

Cross-check the "consumed by" column above against what the KUL_NIS/VBG/FWT
inventory agents actually find when grepping for `conda activate <name>` and
tool-binary calls in each project — this table is built from installer-side
comments/docs, not yet verified against the consumer side.
