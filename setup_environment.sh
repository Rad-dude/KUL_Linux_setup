#!/usr/bin/env bash
#
# setup_environment.sh — set up a fresh Ubuntu/Linux Mint box to run
# KUL_NIS + KUL_VBG + KUL_FWT.
#
# Sources this script is built from (all in this same directory):
#   - KUL_NIS/README.md          (authoritative "Requirements" table)
#   - KUL_VBG/README.md          ("Updated Dependencies" section)
#   - KUL_FWT/README.md          ("Prerequisites" section)
#   - SOFTWARE_ROOT_SETUP.md     (exact pinned commits/versions currently in use)
#   - MIGRATION_GUIDE.md         (per-conda-env install recipes)
#
# This script is idempotent where practical (safe to re-run; skips what's
# already present) but it DOES modify the system: it installs apt packages,
# Docker, CUDA/NVIDIA driver bits, and writes a managed environment block to
# ~/.bashrc (user mode) or to /etc/profile.d/kul_nis_env.sh with a one-line
# source shim in /etc/bash.bashrc (shared mode). The bashrc section owns that
# block: it detects which mode a box is already in from what is on disk,
# refreshes a stale block in place rather than skipping it, and removes copies
# left in the other mode's locations -- exactly one live copy of the body is
# the invariant, since a second one makes every shell source FreeSurfer and
# FSL twice and duplicates PATH. Backups are left as <file>.kulbak.<stamp>.
# Read section toggles
# below before running on a machine you care about. Everything under
# $SOFTWARE_ROOT is self-contained and easy to delete if you want to start
# over -- with one exception: FreeSurfer (current upstream packaging is
# .deb/.rpm only, no relocatable install option since the 8.0 release) is a
# real system install, with $SOFTWARE_ROOT/src/freesurfer just a symlink to
# wherever apt actually put it.
#
# Usage:
#   ./setup_environment.sh                 # no flags + a real terminal: short wizard asks mode/root/group
#   ./setup_environment.sh --mode user                     # isolated install for just this account (default root: $HOME/software)
#   ./setup_environment.sh --mode shared --group kulusers  # shared install other accounts on this box can use (default root: /opt/kul_software)
#   ./setup_environment.sh --root /some/other/path         # override the mode's default root, either mode
#   ./setup_environment.sh -y                              # skip the confirmation prompt (automation)
#   ./setup_environment.sh --list          # show section names and exit
#   ./setup_environment.sh --only mrtrix3,ants   # run just these sections
#   ./setup_environment.sh --skip docker,fsl     # run everything except these
#   ./setup_environment.sh --karawun-stock # conda-forge karawun instead of the KUL fork (see below)
#   ./setup_environment.sh --dry-run       # print what would run, do nothing
#   ./setup_environment.sh --force-rebuild-mismatched  # non-interactive: auto-build the pinned
#                                           # version instead of keeping one that doesn't match
#                                           # (see "Version-pin drift" below)
#   ./setup_environment.sh --fresh-bashrc  # user mode only: back up ~/.bashrc, then rebuild it
#                                           # from the distro's stock skeleton (/etc/skel/.bashrc)
#                                           # plus this script's own managed block, instead of
#                                           # appending onto whatever ~/.bashrc already has. For a
#                                           # machine with an unrelated, pre-existing shell config
#                                           # (a different conda/mamba setup, a different software
#                                           # root) already sourced in ~/.bashrc -- appending onto
#                                           # that leaves BOTH active at once, which is exactly the
#                                           # class of bug this project hit repeatedly during its
#                                           # own migration (PATH-shadowed compilers/linkers, wrong
#                                           # tool versions silently picked up). The stock skeleton
#                                           # is a reasonable starting point for the "cool stuff"
#                                           # (prompt, aliases, .bash_aliases, completion) most
#                                           # unmodified ~/.bashrc files still have, but it can't
#                                           # know about anything YOU specifically added beyond
#                                           # that -- review the backup and port anything else back
#                                           # in by hand.
#
# Re-run safely after fixing a failure partway through — completed sections
# are cheap to skip (they check for existing output first).
#
# Version-pin drift: every pinned tool this script builds (mrtrix3, ANTs, FSL,
# scilpy, HD-BET, karawun, hd-glio, ITK-SNAP, PsychoPy, RStudio) is checked
# against what's ALREADY present, not just whether something with that name
# exists — a prior install (e.g. a shared /usr/local one already on PATH) that
# doesn't match the version this script pins is reported, not silently
# treated as good enough. In a real terminal you're asked keep/build per
# tool; non-interactively (-y, or run through something that isn't a TTY)
# the default is to keep what's there and warn loudly, unless
# --force-rebuild-mismatched says to build the pinned version automatically.
# Either way, "build" only ever creates a fresh, separate copy under
# $SOFTWARE_ROOT — the existing install, wherever it lives and whoever owns
# it, is never deleted or modified.
#
# Notable, non-obvious choices this script makes:
#
#   * mrtrix3 and karawun are built from KUL FORKS, not upstream, and both are
#     required rather than preferential:
#       - Rad-dude/mrtrix3 @ fix/mrconvert-direct-io-arg-binding carries a
#         one-line fix for a missing f-string prefix in dwifslpreproc, without
#         which every run that crops the eddy field map fails immediately.
#       - Rad-dude/karawun @ kul-extended-palette widens the colour palette from
#         31 to 64 entries (append-only; 0-30 unchanged). Stock karawun clamps
#         every label index above 30, so all fMRI activations would render in
#         one colour and collide with the tracts.
#     Both are pinned to explicit commits; see MRTRIX3_* / KARAWUN_* below.
#
#   * mrview is built against Qt6 when the system provides it and Qt5 otherwise
#     (mrtrix3's own -DMRTRIX_USE_QT5=ON), detected by probing for the CMake
#     config rather than by distro version -- this is what makes older bases
#     such as Linux Mint 20/21 work. Headless screenshots via xvfb-run behave
#     identically either way; what matters is the Qt xcb platform plugin, which
#     the mrtrix3 section checks for explicitly.
#
#   * SPM12 is installed to $SOFTWARE_ROOT/src/matlab_apps/spm12 and pointed at
#     by $KUL_MATLAB_APPS. MATLAB itself is NOT installed (commercial, licensed
#     separately); without it the SPM GLM engine is unavailable, and
#     KUL_clinical_fmridti.sh -E nilearn is the MATLAB-free alternative.

set -euo pipefail

# ── Configuration — edit these before running ────────────────────────────────

# INSTALL_MODE is "user" (isolated, this account only) or "shared" (multiple
# accounts on this box, via a shared group). Resolved from --mode/--root/
# --group flags, or an interactive wizard if none were given and stdin is a
# TTY — see the argument-parsing block below. Do not hardcode a root here;
# the wizard/flags below are the supported way to set it.
INSTALL_MODE="${INSTALL_MODE:-user}"
GROUP_NAME="${GROUP_NAME:-kulusers}"
ASSUME_YES=0
FORCE_REBUILD_MISMATCHED=0
FRESH_BASHRC=0
ROOT_OVERRIDE=""
CACHE_ROOT_OVERRIDE=""
NCPU="${NCPU:-$(nproc)}"

# Pinned versions/commits — see SOFTWARE_ROOT_SETUP.md for how these were
# determined. These are the versions this pipeline is actually validated
# against, not necessarily the latest upstream.
MRTRIX3_REPO="https://github.com/Rad-dude/mrtrix3.git"
MRTRIX3_BRANCH="fix/mrconvert-direct-io-arg-binding"
MRTRIX3_COMMIT="5a643594b0c0dae60f09e62cd6b1c56314a19354"
                                           # KUL fork of the dev branch. The branch carries one fix on
                                           # top of upstream dev: dwifslpreproc built the mrconvert call
                                           # that crops the eddy-derived field map as a plain string
                                           # instead of an f-string, so the {} placeholders were never
                                           # interpolated and mrconvert received three positional
                                           # arguments instead of two -- an immediate hard failure on
                                           # every run that reaches that path.
                                           # Set MRTRIX3_REPO/MRTRIX3_BRANCH back to
                                           # https://github.com/MRtrix3/mrtrix3.git / dev to build
                                           # stock upstream once the fix is merged.
                                           # Previous pin: 99963980d (3.0.8-2097, upstream dev, Aug 2026).
                                           # Bumped from the old 86eb1ea8 (3.0.4, July 2023) pin
                                           # deliberately: as of MRtrix3's Oct 2023 CMake migration
                                           # (commit 06e8e4cde removed the classic ./configure &&
                                           # ./build scripts entirely), the dev branch only builds
                                           # with CMake -- see section_mrtrix3 below. The old pin
                                           # predated that migration and used the now-gone build
                                           # system; this one requires it. If this commit fails to
                                           # build, re-run with MRTRIX3_COMMIT=<hash> pointing at
                                           # another dev commit -- do not fall back to a
                                           # pre-Oct-2023 commit without also reverting
                                           # section_mrtrix3 to the classic ./configure && ./build
                                           # invocation.
ANTS_COMMIT="40ee2d22"                    # v2.4.4.post20
FSL_VERSION="6.0.7.23"                    # Latest as of July 2026 (was 6.0.6.5). Bumped for a
                                           # real eddy correctness fix in 6.0.7.8 (bad outlier
                                           # propagation near steep off-resonance gradients; wrong
                                           # CNR formula) and topup boundary-slice improvements in
                                           # 6.0.7.12. Caveat: 6.0.7.8 also switched eddy_cpu from
                                           # OpenMP to native C++ threads and made it default to
                                           # SINGLE-THREADED (confirmed: FSL maintainers on
                                           # Neurostars say it "does not honour OMP_NUM_THREADS",
                                           # you must pass --nthr explicitly) -- this is why
                                           # kul_dwifslpreproc now passes --nthr explicitly on the
                                           # CPU eddy path (see its own comments), independent of
                                           # this version pin.
SCILPY_REPO="https://github.com/Rad-dude/scilpy.git"       # KUL fork of scilus/scilpy
SCILPY_BRANCH="kul-fixes"
SCILPY_COMMIT="77246ca256e6b55927a8d9512f7e605ec0eb5bd5"   # b2bf4ac9 (176 past tag 2.2.2) + 3 fixes
                                                          # Three upstream bugs, branched off the
                                                          # commit previously pinned here:
                                                          #   - scil_bundle_filter_by_occurrence: crash
                                                          #     when --ratio_voxels is omitted, and its
                                                          #     streamlines output was never written
                                                          #   - scil_tractogram_filter_by_anatomy: CSF
                                                          #     rejection used 'any' (whole-path) rather
                                                          #     than 'either_end', discarding most valid
                                                          #     streamlines for grazing sulcal CSF
                                                          #   - scil_viz_bundle_screenshot_mni:
                                                          #     --local_coloring rendered one flat colour
                                                          #     whenever streamlines shared a point count
                                                          # All three are general (not KUL-specific), so
                                                          # if upstream merges them this can go back to a
                                                          # plain scilus/scilpy commit pin.
HDBET_COMMIT="678e44d546a84de0f2a7fc245f176b82b7d912fd"    # 4 commits past tag v2.0.1
KARAWUN_REPO="https://github.com/Rad-dude/karawun.git"
KARAWUN_BRANCH="kul-extended-palette"
KARAWUN_COMMIT="72bbc9558c139678a423b2ee43fbb134d656328c"
KARAWUN_STOCK_VERSION="0.2.5.4"           # --karawun-stock: plain conda-forge package, no git clone
                                                             # KUL fork of DevelopmentalImagingMCRI/karawun
                                                             # (the real upstream -- NOT treanus/karawun,
                                                             # a stale personal fork frozen since 2021 that
                                                             # upstream has long since superseded).
                                                             # The branch extends the colour palette from 31
                                                             # to 64 entries, append-only: indices 0-30 stay
                                                             # byte-identical, so previously exported scenes
                                                             # are unaffected. This is REQUIRED, not optional
                                                             # -- stock karawun's lookup_cie() clamps every
                                                             # label above index 30 to the last palette entry,
                                                             # so with the ~43 tracts and 50/51-63 lesion and
                                                             # fMRI slots KUL_karawun_prepare.sh assigns, all
                                                             # activations render in one colour and collide
                                                             # with the tracts (see the palette comment in
                                                             # KUL_clinical_fmridti.sh).
                                                             # Previous pin: 9ecbf8e6d6ff (upstream v0.2.6.0).
                                                             # Needs Python >=3.14 + pydicom==3.0.2 (see
                                                             # section_env_karawun below).
HDGLIOAUTO_COMMIT="6acaad8"      # NeuroAI-HD/HD-GLIO-AUTO, May 2022. Newer than the code baked into
                                 # the jenspetersen/hd-glio-auto docker image, and fixes a real bug in
                                 # it: volumes.txt reported tumour volumes in *voxels*, because
                                 # np.sum(data == label) was never multiplied by the voxel volume.
HDBET_V1_COMMIT="5f636017b067e5311d2288a2308a326bdfeca150"   # HD-BET 1.0, Mar 2020.
                                 # Deliberately NOT $HDBET_COMMIT (2.0.1). HD-GLIO-AUTO's run.py calls
                                 # 'hd-bet -i <file> -device 0'; in v2 the -device argument takes
                                 # 'cuda'/'cpu'/'mps' and rejects '0', so the two are not
                                 # interchangeable. This one lives in its own env and its own checkout;
                                 # hd-bet-env (v2.0.1, used by KUL_dwiprep and KUL_anat_register) is
                                 # untouched.
FMRIPREP_VERSION="25.1.4"
PSYCHOPY_VERSION="${PSYCHOPY_VERSION:-2026.2.0}" # override with --psychopy-version, or the wizard prompt
PSYCHOPY_VERSION_EXPLICIT=0

KUL_NIS_BRANCH="KUL_NIS_v2.0_20260701"
KUL_VBG_BRANCH="KUL_VBG_2.0"
KUL_FWT_BRANCH="KUL_FWT_v2.0"

# Section toggles — set any of these to 0 to skip by default, or use
# --only/--skip on the command line instead of editing this file.
DO_APT=1
DO_DOCKER=1
DO_NVIDIA=1              # driver/CUDA/Container Toolkit — fully gated on what's already
                         # present; safe to leave on even with no GPU (no-ops immediately)
DO_APPTAINER=1           # VSC/HPC docker alternative — KUL_preproc_all.sh singularity options
DO_VSCODE=1              # editor, not a KUL_NIS dependency -- requested directly
DO_MINIFORGE=1
DO_ENV_DCM2BIDS=1        # dcm2niix + dcm2bids — core dependency, used by most dcm2bids scripts
DO_CLINICAL_PYDEPS=1     # SimpleITK/Pillow/numpy/nibabel/scipy/matplotlib for KUL_nii2dcm.py/KUL_EDs_b2masks.py
DO_ENV_SCILPY=1          # required — KUL_FWT's own filtering/RecoBundles step
DO_ENV_HDBET=1           # brain extraction, used by KUL_dwiprep/KUL_anat_register
DO_ENV_RESSEG=1          # resection-cavity segmentation
DO_ENV_HDGLIO=1          # HD-GLIO-AUTO tumour segmentation, native (no docker)
DO_ENV_KARAWUN=1         # Brainlab export. Builds KarawunDev from the KUL fork by default
                         # (see USE_KARAWUN_DEV below). The conda-forge alternative,
                         # KarawunEnv (--karawun-stock), is frozen at v0.2.5.4 (2021) and
                         # will silently corrupt output DICOMs when the donor is a Philips
                         # (or any) Enhanced/multi-frame DICOM: leftover NumberOfFrames /
                         # PerFrameFunctionalGroupsSequence tags survive into what should be
                         # single-frame slices. Confirmed on real patient data. It also
                         # lacks the extended colour palette the fMRI labels need.
DO_ENV_FASTSURFER=1      # needs a GPU to be useful; safe to leave on, just slow/CPU-only without one
DO_ENV_PYFMRI=1          # KUL_NIS/share/rsfmri_pipeline + KUL_fmriproc_nilearn_new.sh (both hardcode the 'pyfMRI' env)
DO_REPOS=1               # clone KUL_NIS/KUL_VBG/KUL_FWT at pinned branches
DO_ENV_LORE_SD=1         # LoRE-SD (KUL_dwiprep -D run_dwiprep_lore_sd.txt) — regular pip package
DO_ENV_DICOM=1           # KUL_nii2dcm.py — the NIfTI/PNG -> DICOM step behind KUL_clinical_fmridti.sh -R.
                         # Without this env the pipeline falls back to plain python3 with a
                         # warning, which silently breaks the measurable (-q) PACS series: GDCM
                         # refuses non-integer RescaleSlope/Intercept, so pydicom is required.
                         # Mirrors KUL_NIS/share/envs/KUL_dicom.yml (the by-hand equivalent).
DO_MRTRIX3=1
DO_SHARD_RECON=0         # dwimotioncorrect/mssh2amp — KUL_dwiprep.sh's shard_recon: 1 config
                         # option (motion correction alternative to eddy). External MRtrix3
                         # module, built against the mrtrix3 source tree above; not required
                         # for any default config (shard_recon: 0 everywhere out of the box).
                         # Defaults OFF: currently incompatible with the mrtrix3 dev/CMake pin
                         # above (see section_shard_recon's comment) -- shard-recon has no
                         # CMake-based build of its own yet. Set to 1 if that changes upstream.
DO_ANTS=1
DO_FSL=1
DO_FREESURFER=1          # auto-downloads FreeSurfer 8.2.0 itself; only license.txt stays manual
DO_LEADDBS_ATLASES=1     # KUL_tracts_ocd.sh's CIT168/ABGT atlas data (not the full MATLAB toolbox)
DO_SPM12=1               # SPM12 into src/matlab_apps/ for KUL_fmriproc_spm_new.sh's task-fMRI GLM.
                         # Downloads freely; MATLAB itself is the commercial part and is NOT
                         # installed here. Harmless to leave on without MATLAB -- see section_spm12.
DO_ITKSNAP=1             # segmentation/viewer, not a KUL_NIS dependency -- requested directly
DO_PSYCHOPY=1            # experiment builder, not a KUL_NIS dependency -- requested directly
DO_DATALAD=1             # dataset version control, not a KUL_NIS dependency -- requested directly
DO_R=1                   # not a KUL_NIS dependency -- requested directly
DO_RSTUDIO=1             # not a KUL_NIS dependency -- requested directly
DO_AFNI=1                # not a KUL_NIS dependency -- requested directly
DO_AWSCLI=1              # not a KUL_NIS dependency -- requested directly, for pulling S3-hosted data
DO_DOCKER_IMAGES=1       # pulls fmriprep/mriqc/synb0-disco/MSBP/hd-glio-auto images
DO_BASHRC=1
DO_VERIFY=1              # final read-only health check + summary table; safe to
                         # run on its own any time, doesn't modify anything

USE_KARAWUN_DEV=1        # 1 = editable git install (KarawunDev) from $KARAWUN_REPO, instead
                         # of the plain conda-forge package (KarawunEnv, --karawun-stock).
                         # Now the DEFAULT, for two independent reasons:
                         #   * KarawunEnv (v0.2.5.4) silently corrupts output DICOMs given an
                         #     Enhanced/multi-frame donor (e.g. Philips), and there is no newer
                         #     conda-forge release to switch to.
                         #   * the conda-forge package is stock karawun, whose 31-entry palette
                         #     clamps every label index above 30 -- so all fMRI activation
                         #     labels render in one colour and collide with the tracts. The
                         #     extended palette only exists on $KARAWUN_BRANCH.
                         # Despite the name this was never just for developing karawun itself.
                         # Set to 0 (or pass --karawun-stock) for the old conda-forge behaviour.
INCLUDE_HDGLIOAUTO=1     # pulls jenspetersen/hd-glio-auto (verified live on Docker Hub, confirmed
                         # against HD-GLIO-AUTO's own README) alongside the other docker-images.
                         # Narrower use (tumor auto-seg) and GPU-heavy at run time, but the pull
                         # itself is no different from the others -- set to 0 to skip just this one.

DRY_RUN=0
NVIDIA_DRIVER_JUST_CHANGED=0

# ── End configuration ─────────────────────────────────────────────────────────

SCRIPT_SECTIONS="apt docker nvidia apptainer vscode miniforge env-dcm2bids clinical-pydeps env-scilpy env-hdbet env-resseg env-hdglio env-karawun env-fastsurfer env-pyfmri env-lore-sd env-dicom repos mrtrix3 shard-recon ants fsl freesurfer leaddbs-atlases spm12 itksnap psychopy datalad awscli r rstudio afni docker-images bashrc verify"

# ── Helpers ────────────────────────────────────────────────────────────────────

c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_reset=$'\033[0m'

log()   { echo "${c_blue}==>${c_reset} $*"; }
ok()    { echo "${c_green}  ✓${c_reset} $*"; }
warn()  { echo "${c_yellow}  !${c_reset} $*"; }
fail()  { echo "${c_red}  ✗${c_reset} $*" >&2; }
run()   { if [ "$DRY_RUN" -eq 1 ]; then echo "    [dry-run] $*"; else eval "$@"; fi; }

have()  { command -v "$1" >/dev/null 2>&1; }

# Stricter than 'have nvidia-smi': the binary can be present but non-functional
# (confirmed in practice: "Failed to initialize NVML: Driver/library version
# mismatch", the classic symptom of a driver package upgrade whose kernel
# module hasn't been reloaded yet, e.g. no reboot since). Anything that acts
# on driver state should check this, not just binary presence, or it'll
# misreport a broken driver as a working one.
nvidia_smi_ok() { have nvidia-smi && nvidia-smi >/dev/null 2>&1; }

# Underlying Ubuntu release as "24.04"-style, even on derivatives like Linux
# Mint whose own /etc/os-release ID isn't "ubuntu" -- those expose the real
# upstream base via /etc/upstream-release/lsb-release instead. Shared by
# anything that needs to pick a distro-specific download (CUDA repo tag,
# FreeSurfer's per-Ubuntu-version .deb).
ubuntu_release() {
    if [ -f /etc/upstream-release/lsb-release ]; then
        ( . /etc/upstream-release/lsb-release; echo "$DISTRIB_RELEASE" )
    else
        ( . /etc/os-release; echo "$VERSION_ID" )
    fi
}

# Codename form (e.g. "noble"), needed for CRAN's apt repo path. Same
# Mint/derivative handling as ubuntu_release().
ubuntu_codename() {
    if [ -f /etc/upstream-release/lsb-release ]; then
        ( . /etc/upstream-release/lsb-release; echo "$DISTRIB_CODENAME" )
    else
        ( . /etc/os-release; echo "$VERSION_CODENAME" )
    fi
}

# True if $1 is $2 itself or a path underneath it. Used to tell whether
# CACHE_ROOT needs its own separate shared-mode permission setup, or is
# already covered by SOFTWARE_ROOT's.
_is_under() {
    case "$1" in
        "$2"|"$2"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# True if $1 (a git commit/short-hash actually found installed) and $2 (the
# pinned commit constant, which is sometimes stored short and sometimes full
# in this file) agree once compared as a prefix either direction -- e.g. a
# 7-char git-describe hash "40ee2d2" found on a binary should match the
# 8-char pin "40ee2d22" it was built from, and a full 40-char pin should
# match a full 40-char `git rev-parse HEAD`.
_git_short_matches() {
    local installed="$1" pinned="$2"
    [ -n "$installed" ] && [ -n "$pinned" ] && \
        { [[ "$pinned" == "$installed"* ]] || [[ "$installed" == "$pinned"* ]]; }
}

# ── Version-pin drift gate ──────────────────────────────────────────────────
# Every section that only checks "does X already exist" (have X on PATH,
# env_exists X, a version-marker file, a binary sitting at a fixed path)
# shares the same blind spot: it treats ANY prior install as good enough,
# even one that predates this script or came from a shared /usr/local
# install elsewhere on PATH. Confirmed live on a real machine: shared
# mrtrix3 resolves to 3.0.4-537-g5a3a8bf6, six pins behind the KUL-fork
# commit (5a643594) this script actually requires -- and the fix
# dwifslpreproc needs simply isn't in that build. version_gate() is the one
# place that decides what to do about a mismatch; every pinned section calls
# it instead of returning straight from its own "already present" check.
#
# $1 label, $2 installed version/commit (already normalized by the caller to
# something directly comparable to $3), $3 the pinned version/commit.
# Returns 0 -> caller should treat this as "keep what's there" (return/skip
# the build). Returns 1 -> caller should fall through and build the pinned
# version. Either way this function only ever recommends building a fresh,
# separate copy under $SOFTWARE_ROOT (always yours) -- it never deletes or
# modifies anything at the path where the mismatched version was found,
# regardless of who owns it. A caller that then recreates one of ITS OWN
# $SOFTWARE_ROOT conda envs/dirs to do that build (e.g. `mamba create -n X
# -y` replacing an existing $SOFTWARE_ROOT/miniforge3/envs/X) is not an
# exception to that -- it's still entirely inside $SOFTWARE_ROOT.
version_gate() {
    local label="$1" installed="$2" pinned="$3"
    if [ "$installed" = "$pinned" ]; then
        ok "$label already at the pinned version ($pinned)"
        return 0
    fi
    warn "$label installed ($installed) does not match the pinned version ($pinned) this \
script builds. This never deletes or modifies the existing install -- 'build' below only ever \
means a fresh, separate copy under \$SOFTWARE_ROOT (always yours); anything found outside of it \
is left exactly where it is, untouched, no matter who owns it."
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would ask whether to keep $label $installed or build the pinned $pinned under \$SOFTWARE_ROOT"
        return 0
    fi
    if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
        local _vg_choice
        read -r -p "  Keep installed $label ($installed), or build the pinned $pinned under \$SOFTWARE_ROOT? [keep/build] " _vg_choice
        case "${_vg_choice:-keep}" in
            build|Build|b|B) return 1 ;;
            *) ok "Keeping existing $label ($installed) — pinned build skipped"; return 0 ;;
        esac
    fi
    if [ "$FORCE_REBUILD_MISMATCHED" -eq 1 ]; then
        warn "Non-interactive with --force-rebuild-mismatched: building pinned $label $pinned \
(existing $installed left untouched at its own location)"
        return 1
    fi
    warn "Non-interactive: keeping existing $label ($installed) despite the mismatch with the \
pinned $pinned. Pass --force-rebuild-mismatched to build the pinned version automatically \
instead, or re-run interactively to choose per tool."
    return 0
}

# Version-marker convention for tools where live 'X --version' probing is
# risky (GUI/Electron apps can hang trying to open a window instead of
# printing text and exiting) or unreliable (some Electron apps report their
# bundled Chromium/Electron version instead of the app's own). Since we
# already know the exact version we installed at install time, just record
# it -- verify then reads this back instead of probing the binary.
record_version() { mkdir -p "$SOFTWARE_ROOT/.installed_versions"; echo "$2" > "$SOFTWARE_ROOT/.installed_versions/$1"; }
read_version() { cat "$SOFTWARE_ROOT/.installed_versions/$1" 2>/dev/null; }

# Confirmed bug (found live, repeatedly): writing new PATH exports to
# ~/.bashrc / /etc/bash.bashrc / /etc/profile.d never updates the CURRENTLY
# RUNNING script's own PATH -- only a genuinely new shell picks that up. Since
# 'verify' runs as the last step of this same process, it was checking its
# own stale launch-time PATH and reporting perfectly-installed tools as
# missing. Fix: pull just the managed block's exports out of whichever file
# has them and eval it into the current shell before checking anything --
# deliberately NOT sourcing the whole file (a plain ~/.bashrc has an
# interactive-only guard near the top on stock Ubuntu that would bail out
# immediately in this non-interactive context, before ever reaching our
# appended block).
_refresh_env_for_verify() {
    # Derived from what is actually on disk rather than from INSTALL_MODE, so
    # this still finds the block when the mode was mis-detected or overridden.
    # Order matters: KUL_BLOCK_ALL_DESTS lists the user location first and
    # /etc/bash.bashrc last, so in shared mode this picks the real body in
    # /etc/profile.d rather than the one-line shim that sources it.
    local f=""
    local c
    for c in "${KUL_BLOCK_ALL_DESTS[@]}"; do
        if kul_block_present_in "$c"; then f="$c"; break; fi
    done
    [ -n "$f" ] && [ -f "$f" ] || return 0
    local block
    block=$(sed -n '/# >>> KUL_NIS\/KUL_VBG\/KUL_FWT environment (managed block) >>>/,/# <<< KUL_NIS\/KUL_VBG\/KUL_FWT environment (managed block) <<</p' "$f")
    if [ -n "$block" ]; then
        # Confirmed bug (found live): eval inherits the caller's shell
        # options, including -u (nounset). The block does e.g.
        # 'export PYTHONPATH="...:$PYTHONPATH"' with no default-value guard
        # -- fine for a real login shell where PYTHONPATH usually exists (even
        # if empty), but an immediate "unbound variable" abort here under -u,
        # with the error message swallowed by the 2>&1 redirect below, making
        # it look like the script just silently died with no explanation.
        # -e and pipefail have the same inheritance risk (a False test deep in
        # the block would otherwise kill the whole script), so suspend all
        # three for just this eval.
        set +eu
        set +o pipefail
        eval "$block" >/dev/null 2>&1
        set -eu
        set -o pipefail
    fi
    true
}

section_enabled() {
    local name="$1"
    if [ -n "${ONLY_SECTIONS:-}" ]; then
        [[ ",${ONLY_SECTIONS}," == *",${name},"* ]]
    elif [ -n "${SKIP_SECTIONS:-}" ]; then
        [[ ",${SKIP_SECTIONS}," != *",${name},"* ]]
    else
        return 0
    fi
}

# ── Managed shell-env block — markers, destinations, edit helpers ─────────────
# Every place the managed block can legitimately live. Kept in one list so the
# bashrc section, the mode detection below and verify all reason about the same
# set of files instead of each deriving its own from INSTALL_MODE.
KUL_BLOCK_MARKER="# >>> KUL_NIS/KUL_VBG/KUL_FWT environment (managed block) >>>"
KUL_BLOCK_MARKER_END="# <<< KUL_NIS/KUL_VBG/KUL_FWT environment (managed block) <<<"
KUL_BLOCK_USER_DESTS=("$HOME/.bashrc")
KUL_BLOCK_SHARED_DESTS=("/etc/profile.d/kul_nis_env.sh" "/etc/bash.bashrc")
KUL_BLOCK_ALL_DESTS=("${KUL_BLOCK_USER_DESTS[@]}" "${KUL_BLOCK_SHARED_DESTS[@]}")

kul_block_present_in() { grep -qF "$KUL_BLOCK_MARKER" "$1" 2>/dev/null; }

# Every file that currently carries the block, one per line.
kul_block_locations() {
    local f
    for f in "${KUL_BLOCK_ALL_DESTS[@]}"; do
        kul_block_present_in "$f" && echo "$f"
    done
    return 0
}

kul_in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

# Decided per-file rather than per-mode, so that a shared install driven by an
# unprivileged account and a user install both do the right thing without the
# caller having to know which files need root.
kul_write_cmd() {
    local f="$1"
    if [ -e "$f" ]; then
        [ -w "$f" ] && { echo ""; return 0; }
    else
        [ -w "$(dirname "$f")" ] && { echo ""; return 0; }
    fi
    echo "sudo"
}

# Delete the managed block (markers inclusive, plus any blank lines that
# immediately preceded it, so repeated remove/append cycles don't accumulate
# whitespace) from $1, in place, keeping a timestamped backup alongside.
kul_block_strip() {
    local f="$1" tmp sudo_
    sudo_=$(kul_write_cmd "$f")
    tmp=$(mktemp)
    awk -v s="$KUL_BLOCK_MARKER" -v e="$KUL_BLOCK_MARKER_END" '
        $0 == s              { inblk = 1; nb = 0; next }
        inblk                { if ($0 == e) inblk = 0; next }
        /^[[:space:]]*$/     { buf[nb++] = $0; next }
                             { for (i = 0; i < nb; i++) print buf[i]; nb = 0; print }
        END                  { for (i = 0; i < nb; i++) print buf[i] }
    ' "$f" > "$tmp"
    $sudo_ cp -a "$f" "$f.kulbak.$(date +%Y%m%d-%H%M%S)"
    # 'cp' onto the existing path rather than 'mv' so the file keeps its own
    # inode, owner and mode instead of inheriting mktemp's 0600 root-only ones.
    $sudo_ cp "$tmp" "$f"
    rm -f "$tmp"
}

kul_block_append() {
    local f="$1" content="$2" sudo_
    sudo_=$(kul_write_cmd "$f")
    if [ -n "$sudo_" ]; then
        printf '%s\n' "$content" | sudo tee -a "$f" >/dev/null
        sudo chmod 644 "$f"
    else
        printf '%s\n' "$content" >> "$f"
    fi
}

# ── Argument parsing ───────────────────────────────────────────────────────────

MODE_EXPLICIT=0
ROOT_EXPLICIT=0
CACHE_ROOT_EXPLICIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list)
            echo "$SCRIPT_SECTIONS" | tr ' ' '\n'
            exit 0
            ;;
        --only)      ONLY_SECTIONS="$2"; shift 2 ;;
        --skip)      SKIP_SECTIONS="$2"; shift 2 ;;
        --mode)      INSTALL_MODE="$2"; MODE_EXPLICIT=1; shift 2 ;;
        --root)      ROOT_OVERRIDE="$2"; ROOT_EXPLICIT=1; shift 2 ;;
        --cache-root) CACHE_ROOT_OVERRIDE="$2"; CACHE_ROOT_EXPLICIT=1; shift 2 ;;
        --psychopy-version) PSYCHOPY_VERSION="$2"; PSYCHOPY_VERSION_EXPLICIT=1; shift 2 ;;
        --group)     GROUP_NAME="$2"; shift 2 ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --force-rebuild-mismatched) FORCE_REBUILD_MISMATCHED=1; shift ;;
        --fresh-bashrc) FRESH_BASHRC=1; shift ;;
        --karawun-dev) USE_KARAWUN_DEV=1; shift ;;   # now the default; kept so existing invocations still work
        --karawun-stock) USE_KARAWUN_DEV=0; shift ;; # opt back out to the conda-forge package
        --with-hdglioauto) INCLUDE_HDGLIOAUTO=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1"; exit 1 ;;
    esac
done

case "$INSTALL_MODE" in
    user|shared) ;;
    *) fail "Unknown --mode: '$INSTALL_MODE' (expected 'user' or 'shared')"; exit 1 ;;
esac

# ── Resolve mode / root / group — wizard if run bare in a real terminal ──────

# Confirmed bug (found live): a completed *shared* install exports
# SOFTWARE_ROOT from the very block it just wrote, so on every subsequent run
# the "-z ${SOFTWARE_ROOT:-}" guard on the wizard below was false, the wizard
# never ran, and INSTALL_MODE silently fell back to its "user" default -- which
# appended a THIRD copy of the block to ~/.bashrc on a box that was already set
# up shared, with nothing in the output saying the mode had flipped. Infer the
# mode from where the block actually lives before falling back to anything.
KUL_DETECTED_MODE=""
if [ "$MODE_EXPLICIT" -eq 0 ]; then
    _found_user=0
    _found_shared=0
    for _f in "${KUL_BLOCK_USER_DESTS[@]}";   do kul_block_present_in "$_f" && _found_user=1; done
    for _f in "${KUL_BLOCK_SHARED_DESTS[@]}"; do kul_block_present_in "$_f" && _found_shared=1; done
    if [ "$_found_shared" -eq 1 ] && [ "$_found_user" -eq 1 ]; then
        KUL_DETECTED_MODE="shared"
        warn "Managed environment block found in BOTH user and shared locations:"
        kul_block_locations | sed 's/^/        /'
        warn "That is the mode-flip bug above: every shell sources FreeSurfer/FSL \
more than once and PATH carries duplicates. Assuming 'shared' -- pass '--mode user' \
to choose otherwise. The bashrc section will keep the shared copies and remove the stray one."
    elif [ "$_found_shared" -eq 1 ]; then
        KUL_DETECTED_MODE="shared"
    elif [ "$_found_user" -eq 1 ]; then
        KUL_DETECTED_MODE="user"
    fi
    if [ -n "$KUL_DETECTED_MODE" ]; then
        INSTALL_MODE="$KUL_DETECTED_MODE"
        log "Detected an existing '$INSTALL_MODE' install from the managed block on disk"
    fi
fi

WIZARD_RAN=0
if [ "$MODE_EXPLICIT" -eq 0 ] && [ "$ROOT_EXPLICIT" -eq 0 ] && [ -z "$KUL_DETECTED_MODE" ] \
   && [ -z "${SOFTWARE_ROOT:-}" ] && [ -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    WIZARD_RAN=1
    echo
    echo "  Who is this install for?"
    echo "    1) Just this account ($(whoami)) — installs under \$HOME, no group/sudo needed for the software itself"
    echo "    2) Shared — multiple accounts on this box, installed under /opt via a shared group"
    read -r -p "  Choose [1]: " _wizard_choice
    if [ "${_wizard_choice:-1}" = "2" ]; then
        INSTALL_MODE="shared"
        read -r -p "  Group name for shared access [$GROUP_NAME]: " _wizard_group
        [ -n "$_wizard_group" ] && GROUP_NAME="$_wizard_group"
    else
        INSTALL_MODE="user"
    fi
fi

if [ "$INSTALL_MODE" = "shared" ]; then
    DEFAULT_ROOT="/opt/kul_software"
else
    DEFAULT_ROOT="$HOME/software"
fi

if [ "$ROOT_EXPLICIT" -eq 1 ]; then
    SOFTWARE_ROOT="$ROOT_OVERRIDE"
elif [ -n "${SOFTWARE_ROOT:-}" ]; then
    : # explicitly pre-set via an exported SOFTWARE_ROOT env var — keep it
elif [ "$WIZARD_RAN" -eq 1 ]; then
    read -r -p "  Software root [$DEFAULT_ROOT]: " _wizard_root
    SOFTWARE_ROOT="${_wizard_root:-$DEFAULT_ROOT}"
else
    SOFTWARE_ROOT="$DEFAULT_ROOT"
fi

# Cache (pip/conda package downloads -- CONDA_PKGS_DIRS especially can grow to
# tens of GB over time, unlike the mostly-fixed-size installed tools) is
# resolved independently of SOFTWARE_ROOT on purpose: the right software root
# for a given machine isn't necessarily the right place for open-ended cache
# growth (e.g. a spacious-but-slow archive drive vs. a small-but-fast OS
# drive). Defaults to nested under SOFTWARE_ROOT either way -- override with
# --cache-root (or the wizard prompt) if you want it decoupled.
if [ "$CACHE_ROOT_EXPLICIT" -eq 1 ]; then
    CACHE_ROOT="$CACHE_ROOT_OVERRIDE"
elif [ -n "${CACHE_ROOT:-}" ]; then
    : # explicitly pre-set via an exported CACHE_ROOT env var — keep it
elif [ "$WIZARD_RAN" -eq 1 ]; then
    read -r -p "  Cache root, for pip/conda package downloads -- can grow large over time [$SOFTWARE_ROOT/cache]: " _wizard_cache
    CACHE_ROOT="${_wizard_cache:-$SOFTWARE_ROOT/cache}"
else
    CACHE_ROOT="$SOFTWARE_ROOT/cache"
fi

# Optional extras -- none of these are actual KUL_NIS dependencies, just
# commonly-wanted tools bundled in on request. All default to on; the wizard
# offers to trim the list down. Non-interactive/flag-driven runs skip this
# entirely and keep everything on (use --skip <section>,<section> instead).
if [ "$WIZARD_RAN" -eq 1 ]; then
    echo
    echo "  Optional extras (none are required by KUL_NIS itself):"
    echo "    itksnap psychopy datalad awscli vscode r rstudio afni"
    read -r -p "  Install which of these? [all/none/space-separated names] (all): " _wizard_extras
    case "${_wizard_extras:-all}" in
        all|ALL) ;;
        *)
            DO_ITKSNAP=0; DO_PSYCHOPY=0; DO_DATALAD=0; DO_AWSCLI=0; DO_VSCODE=0; DO_R=0; DO_RSTUDIO=0; DO_AFNI=0
            for _extra in $_wizard_extras; do
                case "$_extra" in
                    none|NONE) ;;
                    itksnap) DO_ITKSNAP=1 ;;
                    psychopy) DO_PSYCHOPY=1 ;;
                    datalad) DO_DATALAD=1 ;;
                    awscli)  DO_AWSCLI=1 ;;
                    vscode)  DO_VSCODE=1 ;;
                    r)       DO_R=1 ;;
                    rstudio) DO_RSTUDIO=1 ;;
                    afni)    DO_AFNI=1 ;;
                    *) warn "Unknown extra '$_extra', ignoring" ;;
                esac
            done
            ;;
    esac
    if [ "$DO_PSYCHOPY" -eq 1 ] && [ "${PSYCHOPY_VERSION_EXPLICIT:-0}" -ne 1 ]; then
        read -r -p "  PsychoPy Studio version [$PSYCHOPY_VERSION]: " _wizard_psychopy_ver
        [ -n "$_wizard_psychopy_ver" ] && PSYCHOPY_VERSION="$_wizard_psychopy_ver"
    fi
fi

# Defend against inherited conda/mamba state. Real bug, found in practice on a
# machine with a pre-existing micromamba install: MAMBA_ROOT_PREFIX (exported by
# micromamba's own 'shell init' block in ~/.bashrc) silently redirects
# `mamba create -n <name>` to THAT root instead of $SOFTWARE_ROOT/miniforge3 --
# even when the miniforge3 mamba binary is invoked by its full path. The env
# then gets created in the wrong place, and a later `conda run -n <name>` (using
# miniforge3's own conda, which correctly looks under $SOFTWARE_ROOT) fails with
# EnvironmentLocationNotFound -- which, combined with `set -e`, silently aborted
# the whole script before any later env-creation sections ever ran. A leftover
# activated env from an unrelated conda install (CONDA_PREFIX/VIRTUAL_ENV/compiler
# wrapper vars all pointing elsewhere) can cause similar surprises. Pin the one
# variable directly responsible for the confirmed bug; if you hit further
# contamination from your own shell's conda/mamba setup, the robust fix is
# running this script from a fresh, non-activated shell.
export MAMBA_ROOT_PREFIX="$SOFTWARE_ROOT/miniforge3"

# Self-apply, for the DURATION OF THIS RUNNING PROCESS ONLY, the same PATH
# additions section_bashrc will eventually persist to ~/.bashrc. Without this,
# every "have <tool>" check for something THIS SCRIPT ITSELF just installed
# under $SOFTWARE_ROOT can never find it -- the running process's PATH only
# ever reflects whatever the shell already had before this script started
# (e.g. a completely different, pre-existing dev environment's own ~/.bashrc
# block). Confirmed live, two symptoms of the same root cause: (1)
# dcm2niix/dcm2bids kept reinstalling on every single run despite succeeding
# the first time -- `have dcm2niix` was checking the OLD environment's PATH,
# which never had them, not this run's own miniforge base where they
# actually landed; (2) a freshly-built pinned mrtrix3/ANTs would keep losing
# to a stale/foreign build still resolving first on that same untouched
# PATH, re-triggering version_gate's rebuild prompt for something already
# correctly built moments earlier. Harmless to prepend paths that don't
# exist yet (nothing before the relevant section has run) -- bash silently
# skips missing PATH entries.
export PATH="$SOFTWARE_ROOT/miniforge3/bin:$SOFTWARE_ROOT/src/mrtrix3/bin:$SOFTWARE_ROOT/src/ANTs_install/bin:$PATH"

# ── Resolved configuration summary — confirm before touching anything ───────

echo
log "Resolved install configuration:"
echo "    Mode:            $INSTALL_MODE"
echo "    Software root:   $SOFTWARE_ROOT"
echo "    Cache root:      $CACHE_ROOT$([ "$CACHE_ROOT" = "$SOFTWARE_ROOT/cache" ] && echo " (default)")"
[ "$INSTALL_MODE" = "shared" ] && echo "    Shared group:    $GROUP_NAME (created if missing)"
echo "    CPUs for builds: $NCPU"
[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN — no commands will actually be executed"

_needs_sudo=0
section_enabled apt && _needs_sudo=1
section_enabled docker && _needs_sudo=1
section_enabled nvidia && _needs_sudo=1
section_enabled apptainer && _needs_sudo=1
section_enabled vscode && _needs_sudo=1
section_enabled freesurfer && _needs_sudo=1
section_enabled psychopy && _needs_sudo=1
section_enabled datalad && _needs_sudo=1
section_enabled awscli && _needs_sudo=1
section_enabled r && _needs_sudo=1
section_enabled rstudio && _needs_sudo=1
section_enabled afni && _needs_sudo=1
[ "$INSTALL_MODE" = "shared" ] && [ ! -d "$SOFTWARE_ROOT" ] && _needs_sudo=1
if [ "$INSTALL_MODE" = "shared" ] && ! _is_under "$CACHE_ROOT" "$SOFTWARE_ROOT" && [ ! -d "$CACHE_ROOT" ]; then
    _needs_sudo=1
fi
if [ "$_needs_sudo" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "This run will prompt for your sudo password (apt/docker install\
$([ "$INSTALL_MODE" = "shared" ] && echo ", creating the shared root under $SOFTWARE_ROOT")\
, and — only if you opt in when asked — NVIDIA driver/Container Toolkit changes)."
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "  Proceed? [y/N] " _confirm
    case "$_confirm" in
        y|Y|yes|YES) ;;
        *) fail "Aborted."; exit 1 ;;
    esac
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$INSTALL_MODE" = "shared" ]; then
        echo "    [dry-run] would run: sudo mkdir -p $SOFTWARE_ROOT/{src/FSL,src/freesurfer,src/ANTs_install,tmp/apptainer}"
        echo "    [dry-run] would run: sudo groupadd -f $GROUP_NAME"
        echo "    [dry-run] would run: sudo chown -R $(whoami):$GROUP_NAME $SOFTWARE_ROOT"
        echo "    [dry-run] would run: sudo find $SOFTWARE_ROOT -type d -exec chmod 2775 {} + (directories only)"
        if _is_under "$CACHE_ROOT" "$SOFTWARE_ROOT"; then
            echo "    [dry-run] would run: sudo mkdir -p $CACHE_ROOT/{pip,conda_pkgs,xdg} (covered by the software root's permissions above)"
        else
            echo "    [dry-run] would run: sudo mkdir -p $CACHE_ROOT/{pip,conda_pkgs,xdg}"
            echo "    [dry-run] would run: sudo chown -R $(whoami):$GROUP_NAME $CACHE_ROOT"
            echo "    [dry-run] would run: sudo find $CACHE_ROOT -type d -exec chmod 2775 {} + (directories only, separate cache root)"
        fi
    else
        echo "    [dry-run] would create the $SOFTWARE_ROOT directory skeleton (src/{FSL,freesurfer,ANTs_install}, tmp) and $CACHE_ROOT/{pip,conda_pkgs,xdg}"
    fi
else
    if [ "$INSTALL_MODE" = "shared" ]; then
        # Skip the sudo dance entirely if the root is already prepared --
        # confirmed friction (found live): this ran unconditionally on every
        # invocation, including a pure read-only '--only verify', demanding a
        # sudo password for a no-op every single time.
        if [ -d "$SOFTWARE_ROOT" ] && [ "$(stat -c '%U:%G' "$SOFTWARE_ROOT" 2>/dev/null)" = "$(whoami):$GROUP_NAME" ]; then
            ok "Shared root already prepared at $SOFTWARE_ROOT (owned by $(whoami):$GROUP_NAME) — skipping sudo setup"
            mkdir -p "$SOFTWARE_ROOT"/{src/FSL,src/freesurfer,src/ANTs_install,tmp/apptainer} 2>/dev/null || true
        else
            log "Preparing shared root at $SOFTWARE_ROOT (group: $GROUP_NAME) — needs sudo"
            sudo mkdir -p "$SOFTWARE_ROOT"/{src/FSL,src/freesurfer,src/ANTs_install,tmp/apptainer}
            sudo groupadd -f "$GROUP_NAME"
            sudo chown -R "$(whoami):$GROUP_NAME" "$SOFTWARE_ROOT"
            # setgid on DIRECTORIES ONLY so new files/subdirs created later keep
            # inheriting the shared group. Confirmed bug (found live): a blanket
            # 'chmod -R 2775' also setgids regular files, and glibc's dynamic
            # loader refuses to honor RPATH/RUNPATH/LD_LIBRARY_PATH for setgid
            # executables (security hardening against library injection) -- since
            # conda-distributed binaries rely entirely on RPATH to find their own
            # environment's .so files, that silently broke every one of them
            # (mamba included) with "cannot open shared object file", and re-runs
            # kept re-breaking anything built since. Directories only; leave file
            # permissions as installed.
            sudo find "$SOFTWARE_ROOT" -type d -exec chmod 2775 {} +
            ok "Shared root ready — other users need 'sudo usermod -aG $GROUP_NAME <user>' (plus a matching umask/newgrp) to write into it"
        fi
        if [ -d "$CACHE_ROOT" ] && [ "$(stat -c '%U:%G' "$CACHE_ROOT" 2>/dev/null)" = "$(whoami):$GROUP_NAME" ]; then
            mkdir -p "$CACHE_ROOT"/{pip,conda_pkgs,xdg} 2>/dev/null || true
        else
            # Confirmed bug (found live): the nested-under case used to just
            # 'sudo mkdir' with no chown/chmod of its own, assuming the
            # software root's earlier chown -R covered it -- it doesn't,
            # since this runs AFTER that chown, leaving these subdirs
            # root-owned with no group-write bit (pip/conda cache writes
            # would fail for the invoking user). Always chown+chmod here too,
            # nested or not.
            ! _is_under "$CACHE_ROOT" "$SOFTWARE_ROOT" && log "Cache root $CACHE_ROOT is outside the software root — setting up its own shared permissions"
            sudo mkdir -p "$CACHE_ROOT"/{pip,conda_pkgs,xdg}
            sudo chown -R "$(whoami):$GROUP_NAME" "$CACHE_ROOT"
            sudo find "$CACHE_ROOT" -type d -exec chmod 2775 {} +
        fi
    else
        mkdir -p "$SOFTWARE_ROOT"/{src/FSL,src/freesurfer,src/ANTs_install,tmp/apptainer}
        mkdir -p "$CACHE_ROOT"/{pip,conda_pkgs,xdg}
    fi
fi

# ── 1. System packages ────────────────────────────────────────────────────────

section_apt() {
    log "Installing system packages (apt)"
    run "sudo apt-get update"

    # apt-get install fails its ENTIRE transaction the instant one package
    # name doesn't resolve ("E: Unable to locate package") -- confirmed live
    # on Linux Mint 21.1 / Ubuntu jammy: qt6-svg-dev isn't packaged there
    # (qt6-base-dev is), and that alone aborted installing everything else in
    # this list too, including build-essential/cmake/gcc-12, which ARE always
    # available and were never actually the problem. Probe each package's
    # availability first and only ask apt for the ones that actually resolve
    # here -- same "detect capability, don't assume distro version"
    # philosophy section_mrtrix3 already uses for its own Qt5/Qt6 choice via
    # Qt6Config.cmake, just one layer earlier (apt metadata instead of a
    # post-install CMake config file).
    local core_pkgs="build-essential cmake ninja-build pkg-config git curl wget ca-certificates gnupg unzip \
        software-properties-common \
        gcc-12 g++-12 \
        python3 python3-dev python3-pip python3-venv \
        libeigen3-dev zlib1g-dev libfftw3-dev libtiff5-dev libpng-dev \
        libqt5opengl5-dev libqt5svg5-dev libgl1-mesa-dev libgl1-mesa-dri \
        xvfb \
        p7zip-full \
        dcmtk \
        imagemagick tcsh \
        rsync tmux htop glances nvtop iotop lm-sensors ncdu ripgrep fd-find shellcheck jq parallel git-lfs"
    local pkg avail_pkgs="" missing_pkgs=""
    for pkg in $core_pkgs; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            avail_pkgs="$avail_pkgs $pkg"
        else
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done
    [ -n "$missing_pkgs" ] && warn "Not packaged on this base, skipping (may need a manual \
alternative if you actually need one of these):$missing_pkgs"
    run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y$avail_pkgs"

    # Qt6 dev headers for mrtrix3/mrview: only worth installing as a pair.
    # qt6-base-dev alone (without qt6-svg-dev) would make section_mrtrix3's
    # own Qt6Config.cmake probe pick Qt6, then build a mrview with broken
    # toolbar icons/cursors (no SVG plugin) instead of a fully working Qt5
    # build. Confirmed live: qt6-base-dev IS packaged on Ubuntu 22.04/Linux
    # Mint 21, qt6-svg-dev is NOT -- so this deliberately skips installing
    # BOTH there, leaving Qt6Config.cmake absent, which makes
    # section_mrtrix3 correctly fall back to Qt5 (libqt5svg5-dev is already
    # in the core list above, so that fallback always has full SVG icon
    # support -- never a silently degraded build either way).
    if apt-cache show qt6-base-dev >/dev/null 2>&1 && apt-cache show qt6-svg-dev >/dev/null 2>&1; then
        run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qt6-base-dev qt6-svg-dev"
    else
        warn "qt6-base-dev + qt6-svg-dev aren't both packaged on this base -- skipping both, so \
mrtrix3 will build against Qt5 instead (already has full SVG icon support via libqt5svg5-dev above)"
    fi

    ok "apt packages installed (mrtrix3/ANTs build deps + pkg-config, gcc-12/g++-12 for the ANTs/ITK \
build specifically -- see section_ants for why, imagemagick/tcsh for FreeSurfer-adjacent tooling, \
xvfb + libgl1-mesa-dri for headless mrview screenshots (KUL_clinical_fmridti.sh's own runtime check \
names both -- xvfb alone isn't enough, -dri is the actual Mesa software-rendering driver, distinct \
from the -dev headers), p7zip for -B encrypted backups, dcmtk for send_2_orthanc, plus monitoring/dev \
quality-of-life: rsync/tmux/htop/glances/nvtop/iotop/lm-sensors/ncdu/ripgrep/fd-find/shellcheck/jq/parallel/git-lfs \
-- note Ubuntu installs fd-find's binary as 'fdfind', not 'fd' (name clash with an unrelated package))"
}

# ── 2. Docker ──────────────────────────────────────────────────────────────────

section_docker() {
    if have docker; then
        ok "docker already installed ($(docker --version 2>/dev/null || echo 'version unknown'))"
    else
        log "Installing Docker (docker.io from the Ubuntu/Mint apt repo)"
        run "sudo apt-get install -y docker.io"
        run "sudo usermod -aG docker \$(whoami)"
        warn "Added $(whoami) to the docker group — log out/in (or 'newgrp docker') \
before docker commands work without sudo."
    fi
    if nvidia_smi_ok; then
        ok "nvidia-smi found and working — GPU driver already present (see the nvidia section \
for the Container Toolkit needed for 'docker run --gpus')"
    elif have nvidia-smi; then
        warn "nvidia-smi is present but fails to run — see the nvidia section below, it'll \
flag this properly (until fixed, GPU-accelerated tools fall back to CPU)."
    else
        warn "No nvidia-smi found yet — see the nvidia section below; GPU-accelerated tools \
(FastSurfer, HD-BET, hd-glio-auto) fall back to CPU (slower but still works) until it's installed."
    fi
}

# ── 2b. NVIDIA driver + CUDA wheel selection + Container Toolkit ─────────────
# Fully gated on what's actually present: does nothing if no NVIDIA GPU is
# detected; if a driver is already installed, reports it and only touches
# anything if you explicitly ask to check for a different one. Driver choice
# itself is delegated to 'ubuntu-drivers', which already picks the correct
# recommended driver for whatever specific card is present (old or new) --
# this script deliberately doesn't hardcode a driver/CUDA version so it keeps
# working across different GPUs. See pick_torch_cuda_tag() below for how the
# per-GPU-appropriate PyTorch wheel is chosen for hd-bet-env/FastSurfer.

_nvidia_offer_driver_install() {
    if ! have ubuntu-drivers; then
        warn "'ubuntu-drivers' not found (not an Ubuntu/Mint-derived system?) — install your \
distro's NVIDIA driver package manually, then reboot, before GPU features will work."
        return
    fi
    echo "  Driver(s) ubuntu-drivers recommends for this card:"
    ubuntu-drivers devices 2>/dev/null | sed 's/^/    /'
    warn "Installing/changing a GPU driver replaces kernel modules system-wide and needs a \
REBOOT before nvidia-smi/CUDA work — unlike everything else this script does, it isn't confined \
to \$SOFTWARE_ROOT and is harder to reverse."
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would ask to run: sudo ubuntu-drivers autoinstall"
        return
    fi
    local go="$ASSUME_YES"
    if [ "$go" -ne 1 ]; then
        read -r -p "  Run 'sudo ubuntu-drivers autoinstall' now? [y/N] " _nv_confirm
        case "$_nv_confirm" in y|Y|yes|YES) go=1 ;; *) go=0 ;; esac
    fi
    if [ "$go" -eq 1 ]; then
        sudo ubuntu-drivers autoinstall
        NVIDIA_DRIVER_JUST_CHANGED=1
        warn "Driver installed/changed — REBOOT, then re-run this script, before GPU-accelerated \
sections will actually see the GPU."
    else
        warn "Skipped. Install manually later with 'sudo ubuntu-drivers autoinstall' (or a specific \
'sudo ubuntu-drivers install <package>' if you want a non-default version), then reboot."
    fi
}

section_nvidia() {
    if ! lspci 2>/dev/null | grep -qi nvidia && ! have nvidia-smi; then
        ok "No NVIDIA GPU detected on this machine — skipping driver/CUDA setup entirely \
(GPU-accelerated tools will run CPU-only)"
        return
    fi

    if nvidia_smi_ok; then
        ok "NVIDIA driver already installed: $(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null | head -1)"
        if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
            read -r -p "  Keep this driver, or check for a different one via ubuntu-drivers? [keep/check] " _nv_choice
            if [ "${_nv_choice:-keep}" = "check" ]; then
                _nvidia_offer_driver_install
            fi
        fi
    elif have nvidia-smi; then
        warn "nvidia-smi is present but fails to run ($(nvidia-smi 2>&1 | head -1)) — the classic \
symptom of a driver package upgrade whose kernel module hasn't been reloaded (i.e. needs a REBOOT). \
Try rebooting and re-running this section before reinstalling anything."
        if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
            read -r -p "  Reboot isn't done from here — reinstall the driver anyway via ubuntu-drivers instead? [y/N] " _nv_reinstall
            case "$_nv_reinstall" in y|Y|yes|YES) _nvidia_offer_driver_install ;; esac
        fi
        return
    else
        log "NVIDIA GPU detected but no driver installed"
        _nvidia_offer_driver_install
    fi

    # NVIDIA Container Toolkit: only relevant once Docker AND a working driver
    # are both present (a driver installed just above this run typically isn't
    # active yet — needs the reboot warned about above).
    if have docker && nvidia_smi_ok; then
        if have nvidia-ctk; then
            ok "NVIDIA Container Toolkit already installed (docker run --gpus is ready)"
        else
            log "Docker + NVIDIA GPU present — offering the NVIDIA Container Toolkit \
(needed for 'docker run --gpus', used by fastsurfer_gpu/hd-glio-auto-style GPU containers)"
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    [dry-run] would ask to add NVIDIA's apt repo and install nvidia-container-toolkit"
            else
                local go2="$ASSUME_YES"
                if [ "$go2" -ne 1 ]; then
                    read -r -p "  Add NVIDIA's apt repo and install nvidia-container-toolkit now? [y/N] " _ctk_confirm
                    case "$_ctk_confirm" in y|Y|yes|YES) go2=1 ;; *) go2=0 ;; esac
                fi
                if [ "$go2" -eq 1 ]; then
                    sudo apt-get update
                    sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg2
                    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
                    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
                    sudo apt-get update
                    sudo apt-get install -y nvidia-container-toolkit
                    sudo nvidia-ctk runtime configure --runtime=docker
                    sudo systemctl restart docker
                    ok "NVIDIA Container Toolkit installed and Docker runtime configured"
                else
                    warn "Skipped — GPU-accelerated docker containers won't see the GPU without this."
                fi
            fi
        fi
    fi

    # CUDA Toolkit (nvcc + dev libraries): NOT needed by anything KUL_NIS builds
    # or runs today -- HD-BET/FastSurfer torch wheels and FSL's prebuilt
    # eddy_cuda* all bring/expect just the CUDA *runtime*, not a compiler --
    # but installed on request (e.g. for eddy_cuda's runtime libs, or any
    # future need for nvcc itself). Installs ONLY the 'cuda-toolkit' apt
    # metapackage from NVIDIA's own repo, deliberately never the bare 'cuda'
    # metapackage -- that one also pulls 'cuda-drivers', which conflicts with
    # (dueling kernel modules from) the ubuntu-drivers-managed driver above.
    if nvidia_smi_ok; then
        if have nvcc; then
            ok "CUDA Toolkit already installed ($(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+'))"
        else
            log "NVIDIA GPU present, no nvcc/CUDA Toolkit found — offering to install one \
via NVIDIA's own apt repo (matched to this distro release)"
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    [dry-run] would ask to add NVIDIA's CUDA apt repo and install the cuda-toolkit metapackage"
            else
                local go3="$ASSUME_YES"
                if [ "$go3" -ne 1 ]; then
                    read -r -p "  Add NVIDIA's CUDA apt repo and install cuda-toolkit now? [y/N] " _cuda_confirm
                    case "$_cuda_confirm" in y|Y|yes|YES) go3=1 ;; *) go3=0 ;; esac
                fi
                if [ "$go3" -eq 1 ]; then
                    # Distro tag for NVIDIA's per-release repo path (e.g. "ubuntu2404").
                    local distro_tag="ubuntu$(ubuntu_release | tr -d '.')"
                    local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/$distro_tag/x86_64/cuda-keyring_1.1-1_all.deb"
                    if ! curl -fsSL --head "$keyring_url" >/dev/null 2>&1; then
                        warn "NVIDIA has no CUDA apt repo for '$distro_tag' yet (very new release?) — \
falling back to ubuntu2404. If that also fails, install manually from \
https://developer.download.nvidia.com/compute/cuda/repos/"
                        distro_tag="ubuntu2404"
                        keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/$distro_tag/x86_64/cuda-keyring_1.1-1_all.deb"
                    fi
                    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o /tmp/cuda-keyring.deb "$keyring_url"
                    sudo dpkg -i /tmp/cuda-keyring.deb
                    rm -f /tmp/cuda-keyring.deb
                    sudo apt-get update
                    sudo apt-get install -y cuda-toolkit
                    ok "CUDA Toolkit installed — open a new shell for nvcc/CUDA_HOME to land on PATH"
                else
                    warn "Skipped. Install manually later from https://developer.nvidia.com/cuda-downloads if needed."
                fi
            fi
        fi
    fi
}

# Probe actually-published PyTorch CUDA wheel indices and return the newest
# tag (e.g. cu126, cu121) this machine's driver supports, or "cpu" if none fit
# (no GPU, driver too old for any current wheel, or the probe itself fails --
# e.g. no network). Deliberately dynamic rather than a hardcoded cu-tag: a
# fixed choice ties the script to whatever driver happened to be on the
# machine it was last edited on, and silently breaks on older or much newer
# GPUs. Used by both hd-bet-env (pip, no version constraint) and FastSurfer
# (uv --torch-backend, which uses the same cuXXX tag naming, but constrained
# to whatever exact torch version its requirements.txt pins -- pass that as
# $2 so a tag isn't picked that lacks a build for that specific version).
pick_torch_cuda_tag() {
    local pip_bin="$1" want_version="${2:-}"
    if ! nvidia_smi_ok; then echo cpu; return; fi
    local max_cuda
    max_cuda=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\s*\K[0-9]+\.[0-9]+' | head -1) || true
    if [ -z "$max_cuda" ]; then echo cpu; return; fi
    # Newest-first candidates. Extend this list over time as PyTorch adds new
    # cu-tags -- a stale/missing entry is simply skipped by the probe below,
    # not silently mis-selected, since each candidate is checked for both (a)
    # fitting under this driver's max CUDA version and (b) actually having a
    # published torch wheel right now (and, if given, matching $want_version).
    local tag tag_ver probe
    for tag in cu128 cu126 cu124 cu121 cu118; do
        tag_ver="${tag#cu}"
        tag_ver="${tag_ver:0:2}.${tag_ver:2}"
        if awk -v a="$max_cuda" -v b="$tag_ver" 'BEGIN{exit !(a+0 >= b+0)}'; then
            probe=$("$pip_bin" index versions torch --index-url "https://download.pytorch.org/whl/$tag" 2>/dev/null) || true
            if [ -n "$probe" ] && { [ -z "$want_version" ] || [[ "$probe" == *"$want_version"* ]]; }; then
                echo "$tag"
                return
            fi
        fi
    done
    warn "NVIDIA GPU present (driver max CUDA $max_cuda) but no matching PyTorch CUDA wheel found${want_version:+ for torch==$want_version} — falling back to CPU-only torch" >&2
    echo cpu
}

# ── 2c. Apptainer/Singularity (VSC/HPC docker alternative) ───────────────────
# Real gap: KUL_preproc_all.sh and KUL_VSC_prepare_dwiprep.sh both support
# running mriqc/fmriprep via 'singularity run' as the VSC/HPC-cluster
# alternative to Docker (KUL_use_mriqc_singularity / KUL_use_fmriprep_singularity
# env vars), but nothing installed it before now. Apptainer (Singularity's
# current upstream project) ships a 'singularity' compatibility symlink by
# default, so KUL_NIS's existing singularity-based code paths work unmodified.

section_apptainer() {
    if have singularity || have apptainer; then
        ok "Apptainer/Singularity already installed ($(apptainer --version 2>/dev/null || singularity --version 2>/dev/null))"
        return
    fi
    log "Installing Apptainer via its official PPA"
    run "sudo add-apt-repository -y ppa:apptainer/ppa"
    run "sudo apt-get update"
    run "sudo apt-get install -y apptainer"
    ok "Apptainer installed — provides both 'apptainer' and a 'singularity' compatibility \
symlink (used by KUL_preproc_all.sh/KUL_VSC_prepare_dwiprep.sh's singularity options)"
}

# ── 2d. Visual Studio Code ─────────────────────────────────────────────────────
# Not a KUL_NIS dependency -- requested directly. Installed via Microsoft's own
# apt repo (their documented method), same general idiom as Apptainer's PPA and
# the NVIDIA/CUDA repos above.

section_vscode() {
    if have code; then
        ok "VS Code already installed ($(code --version 2>/dev/null | head -1))"
        return
    fi
    log "Installing VS Code via Microsoft's own apt repo"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would add Microsoft's apt repo and install the 'code' package"
        return
    fi
    sudo apt-get install -y wget gpg
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'VSCODE_SOURCES'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
VSCODE_SOURCES
    sudo apt-get update
    sudo apt-get install -y code
    ok "VS Code installed"
}

# ── 3. Miniforge ───────────────────────────────────────────────────────────────

section_miniforge() {
    if [ -x "$SOFTWARE_ROOT/miniforge3/bin/conda" ]; then
        ok "miniforge already installed at $SOFTWARE_ROOT/miniforge3"
        return
    fi
    log "Installing miniforge3"
    local installer="$SOFTWARE_ROOT/tmp/Miniforge3-Linux-x86_64.sh"
    run "curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o '$installer' https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
    run "bash '$installer' -b -p '$SOFTWARE_ROOT/miniforge3'"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would write $SOFTWARE_ROOT/.condarc"
    else
        cat > "$SOFTWARE_ROOT/.condarc" <<'EOF'
channels:
  - conda-forge
mirrored_channels:
  conda-forge:
    - https://conda.anaconda.org/conda-forge
    - https://prefix.dev/conda-forge
EOF
    fi
    run "'$SOFTWARE_ROOT/miniforge3/bin/conda' config --file '$SOFTWARE_ROOT/.condarc' --set always_yes true 2>/dev/null || true"
    ok "miniforge installed, .condarc written"
}

conda_bin() { echo "$SOFTWARE_ROOT/miniforge3/bin/conda"; }
mamba_bin() { echo "$SOFTWARE_ROOT/miniforge3/bin/mamba"; }
# Full path to a binary inside one of *our* envs. Deliberately NOT using
# `conda run -n <name>`/`mamba run -n <name>` for this: confirmed in practice
# that name-based env resolution can silently resolve to a completely different
# environment of the same name under an unrelated conda/mamba install elsewhere
# on the machine (e.g. a shared install's own "scilpy" env), even when the
# conda/mamba binary itself is invoked by full path under $SOFTWARE_ROOT — some
# inherited environment variable (CONDA_PREFIX, MAMBA_ROOT_PREFIX, etc.) takes
# precedence over the invoked binary's own location. Calling the target env's
# binary directly by its own full, unambiguous path sidesteps that entirely.
env_bin() { echo "$SOFTWARE_ROOT/miniforge3/envs/$1/bin/$2"; }

env_exists() {
    "$(conda_bin)" env list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# ── 3b. dcm2bids env (dcm2niix + dcm2bids — core dependency, README lists both ──
# as required for most dcm2bids scripts, but neither had an install path before:
# dcm2bids only existed inside the optional KarawunDev env, and dcm2niix wasn't
# installed anywhere. Its own small env keeps both self-contained under
# $SOFTWARE_ROOT while its bin/ is added directly to PATH in the bashrc/profile.d
# block below, so 'dcm2niix'/'dcm2bids' work globally without activating anything
# -- same pattern as FSL/ANTs/mrtrix3.

section_env_dcm2bids() {
    # Installed straight into the miniforge base env, not a dedicated env --
    # confirmed against KUL_dcm2bids.sh's own self-check (`which
    # dcm2bids_scaffold`, falling back to a bare `pip install dcm2bids` with
    # no env-scoping at all if missing) that this is the convention KUL_NIS's
    # own scripts already assume, matching how it was set up previously too.
    # A separate env's bin/ would have needed permanently prepending to PATH
    # to work the same way without activation, which would've shadowed base's
    # own python3/pip in every fresh shell for no real benefit.
    if have dcm2niix && have dcm2bids_scaffold; then
        ok "dcm2niix/dcm2bids already installed in base"
        return
    fi
    log "Installing dcm2niix + dcm2bids >=3.1 into the miniforge base env — any recent 3.x \
satisfies KUL_NIS's requirement per SOFTWARE_ROOT_SETUP.md; config schema only changes at the \
v2->v3 boundary"
    run "$(mamba_bin) install -n base -c conda-forge dcm2niix -y"
    run "'$SOFTWARE_ROOT/miniforge3/bin/pip' install 'dcm2bids>=3.1'"
    ok "dcm2niix/dcm2bids ready in base (used by KUL_dcm2bids.sh, KUL_dcm2bids_new.sh, \
KUL_multisubjects_dcm2bids.sh)"
}

# ── 3c. Python packages for the clinical DICOM-generation scripts ────────────
# Confirmed gap: KUL_nii2dcm.py (writes the actual output DICOM series for
# KUL_clinical_fmridti.sh's -R PACS/Karawun step) and KUL_EDs_b2masks.py run
# under plain python3 -- whatever's on PATH at call time (the miniforge base
# env here), not a dedicated conda env -- so their dependencies, per
# README.md's own documented list, need to live in base. Nothing installed
# these before now. vtk is optional (only KUL_EDs_b2masks.py's
# --bg-image --volume-render path) so its failure doesn't abort the section.

section_clinical_pydeps() {
    if "$SOFTWARE_ROOT/miniforge3/bin/python" -c "import SimpleITK, PIL, numpy, nibabel, scipy, matplotlib" >/dev/null 2>&1; then
        ok "Clinical DICOM-generation Python packages already installed in base"
        return
    fi
    log "Installing Python packages for KUL_nii2dcm.py/KUL_EDs_b2masks.py into miniforge base \
(SimpleITK, Pillow, numpy, nibabel, scipy, matplotlib; vtk optional)"
    run "'$SOFTWARE_ROOT/miniforge3/bin/pip' install SimpleITK Pillow numpy nibabel scipy matplotlib"
    run "'$SOFTWARE_ROOT/miniforge3/bin/pip' install vtk || true"
    ok "Clinical DICOM-generation Python packages ready in base"
}

# ── 4a. scilpy env (required — KUL_FWT's filtering/RecoBundles step) ──────────

section_env_scilpy() {
    local dest="$SOFTWARE_ROOT/src/scilpy"
    if env_exists scilpy; then
        if [ -d "$dest/.git" ]; then
            local installed_commit
            installed_commit=$(git -C "$dest" rev-parse HEAD 2>/dev/null) || installed_commit=""
            if _git_short_matches "$installed_commit" "$SCILPY_COMMIT"; then
                ok "conda env 'scilpy' already exists at the pinned commit (${installed_commit:0:8})"
                return
            fi
            version_gate "scilpy" "${installed_commit:-unknown}" "$SCILPY_COMMIT" && return
        else
            ok "conda env 'scilpy' already exists (no git checkout at $dest to verify against the pinned commit -- assuming OK)"
            return
        fi
    fi
    log "Creating 'scilpy' env (python 3.12, KUL fork $SCILPY_BRANCH @ $SCILPY_COMMIT \
— v2.3.0 base plus three upstream bugfixes)"
    run "$(mamba_bin) create -n scilpy python=3.12 -y"
    run "'$(env_bin scilpy pip)' install scilpy==2.3.0"
    run "'$(env_bin scilpy pip)' uninstall scilpy -y"
    [ -d "$dest" ] || run "git clone -b '$SCILPY_BRANCH' '$SCILPY_REPO' '$dest'"
    run "cd '$dest' && git checkout $SCILPY_COMMIT"
    run "cd '$dest' && '$(env_bin scilpy pip)' install -e . --no-deps"
    # Pillow, stated explicitly. KUL_FWT_bundle_report.py imports PIL, but nothing
    # in this env declares it directly -- it arrives only transitively via
    # matplotlib/fury/scikit-image, which the scilpy pin above happens to pull in
    # today. A future scilpy release that drops or vendors any of those would
    # break the bundle report with an ImportError a long way from here. Cheap to
    # state, and a no-op when already satisfied.
    run "'$(env_bin scilpy pip)' install pillow"
    ok "scilpy env ready — used automatically by KUL_clinical_fmridti.sh's FWT step (default \$KUL_SCILPY_ENV)"
}

# ── 4b. HD-BET env (brain extraction) ─────────────────────────────────────────

section_env_hdbet() {
    local dest="$SOFTWARE_ROOT/src/HD-BET"
    if env_exists hd-bet-env; then
        if [ -d "$dest/.git" ]; then
            local installed_commit
            installed_commit=$(git -C "$dest" rev-parse HEAD 2>/dev/null) || installed_commit=""
            if _git_short_matches "$installed_commit" "$HDBET_COMMIT"; then
                ok "conda env 'hd-bet-env' already exists at the pinned commit (${installed_commit:0:8})"
                return
            fi
            version_gate "hd-bet-env (HD-BET)" "${installed_commit:-unknown}" "$HDBET_COMMIT" && return
        else
            ok "conda env 'hd-bet-env' already exists (no git checkout at $dest to verify -- assuming OK)"
            return
        fi
    fi
    log "Creating 'hd-bet-env' (python 3.10, torch 2.6, HD-BET $HDBET_COMMIT)"
    run "$(mamba_bin) create -n hd-bet-env python=3.10 -y"
    [ -d "$dest" ] || run "git clone https://github.com/MIC-DKFZ/HD-BET.git '$dest'"
    run "cd '$dest' && git checkout $HDBET_COMMIT"
    # Install HD-BET and torch together in one resolver pass, with the CUDA (or
    # CPU) wheel index as primary and PyPI as extra. Doing this as two separate
    # pip calls (torch first, then 'pip install -e .' for HD-BET/nnunetv2) is a
    # confirmed bug: the second call's unconstrained transitive "torch"
    # requirement gets re-resolved against plain PyPI (no index-url given) and
    # silently replaces the working CUDA build with a newer, plain-PyPI one
    # that doesn't match this machine's CUDA driver.
    local torch_tag
    torch_tag=$(pick_torch_cuda_tag "$SOFTWARE_ROOT/miniforge3/bin/pip")
    if [ "$torch_tag" != "cpu" ]; then
        # No exact torch version pin here (deliberately, unlike a hardcoded
        # cu-tag) -- pick_torch_cuda_tag already confirmed this index has a
        # published torch build, and keeping the whole install (torch + -e
        # HD-BET) as one pip call against that single --index-url is what
        # actually avoids the drift bug above, not the exact version pin.
        run "'$(env_bin hd-bet-env pip)' install --index-url https://download.pytorch.org/whl/$torch_tag --extra-index-url https://pypi.org/simple torch -e '$dest'"
    else
        warn "Installing CPU-only torch for hd-bet-env (no usable NVIDIA GPU/driver found — much slower, but avoids a multi-GB CUDA wheel download you can't use)"
        run "'$(env_bin hd-bet-env pip)' install --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple -e '$dest'"
    fi
    ok "hd-bet-env ready (used by KUL_dwiprep -m 1, KUL_anat_register)"
}

# ── 4c. resseg env (resection-cavity segmentation) ────────────────────────────

RESSEG_WEIGHTS_NAME="self_semi_37-b571f7ba.pth"
RESSEG_WEIGHTS_URL="https://github.com/fepegar/resseg/raw/master/$RESSEG_WEIGHTS_NAME"

# resseg ships no usable pretrained weights: 'pip install resseg' installs the
# code but not the checkpoint, and the lookup in resseg/model.py is broken
# anyway. It computes Path(__file__).parent.parent, which assumed model.py sat
# one level below the repo root beside the checkpoint -- untrue since upstream
# moved to a src/ layout (src/resseg/model.py -> parent.parent is src/, while
# the checkpoint is at the repo root) and untrue for a pip install (where
# parent.parent is site-packages/). Every resseg run therefore dies with
#
#   FileNotFoundError: .../site-packages/self_semi_37-b571f7ba.pth
#
# which in the pipeline surfaces only as "resseg run 1 might have failed" in a
# log, leaving the resection cavity silently unsegmented.
#
# Note the checkpoint must NOT be dropped into site-packages/ to satisfy the
# upstream path: Python's site module parses every *.pth file directly in that
# directory as a UTF-8 path-configuration file at interpreter startup, so a
# binary checkpoint there stops the environment's python from starting at all
# ("Failed to import the site module"). It goes in resseg/weights/ instead,
# which site does not scan.
#
# Idempotent, and deliberately run even when the env already exists, so an
# existing broken install is repaired rather than skipped.
_resseg_fix_weights() {
    local sp weights model_py patcher
    sp=$("$(env_bin resseg python)" -c \
        "import os, resseg; print(os.path.dirname(resseg.__file__))" 2>/dev/null) || {
        warn "resseg not importable — skipping weights fix"
        return
    }
    weights="$sp/weights/$RESSEG_WEIGHTS_NAME"
    model_py="$sp/model.py"

    if [ ! -f "$weights" ]; then
        log "Fetching resseg pretrained weights (~1 MB)"
        run "mkdir -p '$sp/weights'"
        run "curl -fsSL -o '$weights' '$RESSEG_WEIGHTS_URL'"
    fi

    if grep -q "KUL patch" "$model_py" 2>/dev/null; then
        ok "resseg model.py already patched"
        return
    fi

    log "Patching resseg/model.py to find its checkpoint"
    [ "$DRY_RUN" -eq 1 ] && { echo "    [dry-run] patch $model_py"; return; }
    cp -n "$model_py" "$model_py.orig" 2>/dev/null || true
    patcher=$(mktemp) || return
    cat > "$patcher" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
old = """    if pretrained:
        repo_dir = Path(__file__).parent.parent
        weights_path = repo_dir / 'self_semi_37-b571f7ba.pth'
        state_dict = torch.load(weights_path)
        model.load_state_dict(state_dict)
    return model"""
new = """    if pretrained:
        # KUL patch (see setup_environment.sh, section_env_resseg) -- upstream
        # looks for the checkpoint beside a repo root that no longer exists in
        # either the src/ layout or a pip install. Never put the .pth directly
        # in site-packages: python's site module parses those as text at
        # startup and a binary one breaks the interpreter.
        weights_name = 'self_semi_37-b571f7ba.pth'
        candidates = (
            Path(__file__).parent / 'weights' / weights_name,
            Path(__file__).parent.parent / weights_name,
            Path(__file__).parent.parent.parent / weights_name,
            Path(torch.hub.get_dir()) / 'fepegar_resseg_master' / weights_name,
        )
        for weights_path in candidates:
            if weights_path.is_file():
                state_dict = torch.load(weights_path, map_location='cpu')
                break
        else:
            state_dict = torch.hub.load_state_dict_from_url(
                WEIGHTS_URL, progress=progress, map_location='cpu')
        model.load_state_dict(state_dict)
    return model"""
if old not in s:
    sys.exit("resseg/model.py does not match the expected upstream text; "
             "not patching (check whether upstream has fixed this)")
p.write_text(s.replace(old, new))
PYEOF
    if "$(env_bin resseg python)" "$patcher" "$model_py"; then
        ok "resseg/model.py patched"
    else
        warn "could not patch resseg/model.py — resseg will fail to load its weights"
    fi
    rm -f "$patcher"
}

# ── 4d. hdglio env (HD-GLIO-AUTO, non-docker) ─────────────────────────────────
#
# KUL_anat_segment_tumor.sh needs HD-GLIO-AUTO for the tumour segmentation. The
# upstream project distributes it as a docker image; this installs it natively,
# which is what the pipeline's local-install branch expects.
#
# The image freezes a 2020 toolchain (python 3.6, torch 1.6, numpy 1.19,
# SimpleITK 2.0). Installing the same software against a current Python breaks
# in eleven separate places, and only some of them fail at install time -- the
# rest surface mid-run, after minutes of GPU work. Every pin and patch below is
# one of those; none is cosmetic. Verified end to end on a real 4-contrast
# clinical study: 4m34s, segmentation.nii.gz + volumes.txt produced, volume
# cross-checked against an independent count of the label map.
#
# Runtime also needs FSL on PATH (fslreorient2std, flirt, fslmaths).
_hdglio_patch_sources() {
    local f patcher
    patcher=$(mktemp) || return 1
    cat > "$patcher" <<'PYEOF'
import sys
from pathlib import Path

hdbet, hdglioauto = Path(sys.argv[1]), Path(sys.argv[2])
changed = []

# (a) HD_BET/hd-bet has no shebang. setup.py lists it in scripts=[...]; the old
#     'setup.py develop' wrapped it in an easy-install shim that supplied one,
#     but modern pip copies the file verbatim, so bin/hd-bet starts with
#     'import os' and exec() fails with OSError [Errno 8] Exec format error.
p = hdbet / "HD_BET" / "hd-bet"
s = p.read_text()
if not s.startswith("#!"):
    p.write_text("#!/usr/bin/env python\n" + s)
    changed.append("HD_BET/hd-bet: added shebang")

# (b) HD_BET/data_loading.py compares the whole segmentation ARRAY against a
#     3-element size, where it means the array's shape. numpy <1.25 evaluated
#     that as False with a DeprecationWarning (so the branch never ran, silently
#     wrong); numpy >=1.25 raises ValueError and hd-bet dies at export, after
#     inference has completed.
p = hdbet / "HD_BET" / "data_loading.py"
s = p.read_text()
old = "if np.any(np.array(seg_old_size) != np.array(dct['size'])[[2, 1, 0]]):"
new = "if np.any(np.array(seg_old_size.shape) != np.array(dct['size'])[[2, 1, 0]]):"
if old in s:
    p.write_text(s.replace(old, new))
    changed.append("HD_BET/data_loading.py: compare shape, not array")

# (c) scripts/run.py uses img.get_data(), removed in nibabel 5.0
#     (ExpiredDeprecationError). asanyarray(dataobj) is the documented
#     equivalent; get_fdata() would upcast the label map to float64. This one
#     fires AFTER the segmentation is written, so the expensive work completes
#     and the run then dies while reporting volumes.
#     np.product was likewise removed in numpy 2.0.
p = hdglioauto / "scripts" / "run.py"
s = p.read_text()
orig = s
import re
s = re.sub(r"(\w+)\.get_data\(\)", r"np.asanyarray(\1.dataobj)", s)
s = s.replace("np.product(", "np.prod(")
if s != orig:
    p.write_text(s)
    changed.append("HD-GLIO-AUTO/scripts/run.py: get_data -> asanyarray, product -> prod")

print("\n".join("    patched " + c for c in changed) if changed
      else "    sources already patched")
PYEOF
    "$SOFTWARE_ROOT/miniforge3/bin/python" "$patcher" \
        "$SOFTWARE_ROOT/src/HD-BET_v1" "$SOFTWARE_ROOT/src/HD-GLIO-AUTO"
    f=$?
    rm -f "$patcher"
    return $f
}

section_env_hdglio() {
    local hdbet_dir="$SOFTWARE_ROOT/src/HD-BET_v1"
    local auto_dir="$SOFTWARE_ROOT/src/HD-GLIO-AUTO"

    [ -d "$auto_dir" ]  || run "git clone https://github.com/NeuroAI-HD/HD-GLIO-AUTO.git '$auto_dir'"
    run "cd '$auto_dir' && git checkout $HDGLIOAUTO_COMMIT"
    [ -d "$hdbet_dir" ] || run "git clone https://github.com/MIC-DKFZ/HD-BET.git '$hdbet_dir'"
    run "cd '$hdbet_dir' && git checkout $HDBET_V1_COMMIT"

    local need_create=1
    if env_exists hdglio; then
        local installed_ver
        installed_ver=$("$(mamba_bin)" list -n hdglio hd-glio 2>/dev/null | awk '$1=="hd-glio"{print $2}')
        if [ "$installed_ver" = "2.0" ]; then
            ok "conda env 'hdglio' already exists at the pinned hd-glio version ($installed_ver)"
            need_create=0
        elif [ -n "$installed_ver" ]; then
            version_gate "hdglio (hd-glio package)" "$installed_ver" "2.0" && need_create=0
        else
            ok "conda env 'hdglio' already exists (couldn't read the installed hd-glio version -- assuming OK)"
            need_create=0
        fi
    fi
    if [ "$need_create" -eq 1 ]; then
        log "Creating 'hdglio' env (python 3.9, torch 1.13.1, nnunet 1.6.4, hd-glio 2.0, HD-BET 1.0)"
        run "$(mamba_bin) create -n hdglio python=3.9 -y"

        # One pip call, one resolver pass, for the reason documented in
        # section_env_hdbet: splitting it lets a later unconstrained 'torch'
        # requirement silently replace the CUDA build.
        #
        #   torch==1.13.1      nnunet 1.x predates torch 2.x. 1.13.1 is the last
        #                      1.x, and cu117 wheels run on current drivers.
        #   numpy<2            torch 1.13 was built against numpy 1.x. With numpy
        #                      2 it INSTALLS FINE and then dies at the first
        #                      array<->tensor conversion: "RuntimeError: Numpy is
        #                      not available".
        #   python-gdcm pin    pulled in via nnunet -> dicom2nifti. Newer versions
        #                      have no cp39 wheel and their sdist has no
        #                      CMakeLists.txt, so the source build fails.
        #   batchgenerators    0.25 moved MultiThreadedAugmenter out of
        #     ==0.21           batchgenerators.dataloading, which nnunet imports.
        #   matplotlib         imported by nnunet, not declared by it.
        #   SKLEARN_ALLOW_...  nnunet 1.6.4 requires the deprecated 'sklearn'
        #                      shim, which now refuses to install without this.
        local torch_tag
        torch_tag=$(pick_torch_cuda_tag "$SOFTWARE_ROOT/miniforge3/bin/pip")
        [ "$torch_tag" = "cpu" ] && warn "No usable GPU found — hd-glio will run on CPU (very slow)"
        run "SKLEARN_ALLOW_DEPRECATED_SKLEARN_PACKAGE_INSTALL=True '$(env_bin hdglio pip)' install \
            --index-url https://download.pytorch.org/whl/cu117 \
            --extra-index-url https://pypi.org/simple \
            'torch==1.13.1' 'numpy<2' 'python-gdcm==3.0.24.1' 'nnunet==1.6.4' \
            'hd-glio==2.0' 'batchgenerators==0.21' matplotlib -e '$hdbet_dir'"
    fi

    _hdglio_patch_sources
    # The shebang patch changes what pip copies into bin/, so reinstall after it.
    run "'$(env_bin hdglio pip)' install -q --force-reinstall --no-deps -e '$hdbet_dir'"
    _hdglio_fix_weights
    ok "hdglio env ready (used by KUL_anat_segment_tumor.sh; needs FSL on PATH at run time)"
}

# hd_glio and HD-BET both hardcode their weights to os.path.expanduser('~') with
# no environment override, so on a shared install every user re-downloads ~400 MB
# into their own home and the installer cannot provision them once. Point both at
# a shared directory under SOFTWARE_ROOT, keeping ~ as the fallback so a
# user-mode install still behaves as upstream intends.
_hdglio_fix_weights() {
    local share="$SOFTWARE_ROOT/share/hd_models"
    local patcher
    run "mkdir -p '$share/hd_glio_params' '$share/hd-bet_params'"
    [ "$DRY_RUN" -eq 1 ] && { echo "    [dry-run] patch paths.py + fetch weights"; return; }

    patcher=$(mktemp) || return
    cat > "$patcher" <<'PYEOF'
import sys
from pathlib import Path

share = sys.argv[1]
for mod_path, folder in ((sys.argv[2], "hd_glio_params"), (sys.argv[3], "hd-bet_params")):
    p = Path(mod_path)
    s = p.read_text()
    if "KUL patch" in s:
        continue
    p.write_text(
        "import os\n"
        "# KUL patch: prefer a shared, installer-provisioned parameter directory,\n"
        "# so every user of a shared install does not re-download the weights into\n"
        "# their own home. Falls back to upstream's ~/<name> when the shared one is\n"
        "# absent (user-mode installs), and an explicit env var wins over both.\n"
        "_shared = {shared!r}\n"
        "folder_with_parameter_files = (\n"
        "    os.environ.get('KUL_HD_PARAMS_DIR')\n"
        "    or (_shared if os.path.isdir(_shared) else\n"
        "        os.path.join(os.path.expanduser('~'), {folder!r}))\n"
        ")\n".format(shared=str(Path(share) / folder), folder=folder)
    )
    print("    patched " + mod_path)
PYEOF
    # tail -1: importing hd_glio prints a multi-line citation banner to stdout,
    # which would otherwise be captured as part of the path.
    local glio_paths
    glio_paths=$("$(env_bin hdglio python)" -c "import hd_glio.paths as m; print(m.__file__)" 2>/dev/null | tail -n 1)
    "$(env_bin hdglio python)" "$patcher" "$share" \
        "$glio_paths" \
        "$SOFTWARE_ROOT/src/HD-BET_v1/HD_BET/paths.py"
    rm -f "$patcher"

    log "Fetching HD-GLIO / HD-BET model weights into $share (~400 MB, once)"
    run "'$(env_bin hdglio python)' -c \"from hd_glio.setup_hd_glio import maybe_download_weights; maybe_download_weights()\""
    run "'$(env_bin hdglio python)' -c \"from HD_BET.utils import maybe_download_parameters; [maybe_download_parameters(i) for i in range(5)]\""
}

section_env_resseg() {
    if env_exists resseg; then
        ok "conda env 'resseg' already exists"
        _resseg_fix_weights
        return
    fi
    log "Creating 'resseg' env (python 3.8, resseg 0.3.7, antspyx 0.4.2)"
    run "$(mamba_bin) create -n resseg python=3.8 -y"
    # Pin simpleitk to the last version with a cp38 manylinux wheel before installing
    # resseg/antspyx -- torchio (a resseg dependency) allows any simpleitk!=2.0.*,!=2.1.1.1
    # and pip's resolver otherwise picks the latest (2.5.5+), which has no cp38 wheel and
    # fails building from source (conda toolchain doesn't see system crypt.h).
    run "'$(env_bin resseg pip)' install simpleitk==2.4.1"
    run "'$(env_bin resseg pip)' install resseg==0.3.7 antspyx==0.4.2"
    _resseg_fix_weights
    ok "resseg env ready (used by KUL_anat_segment_tumor.sh)"
}

# ── 4d. Karawun env (Brainlab export) ─────────────────────────────────────────

section_env_karawun() {
    if [ "$USE_KARAWUN_DEV" -eq 1 ]; then
        local dest="$SOFTWARE_ROOT/src/karawun"
        if env_exists KarawunDev; then
            if [ -d "$dest/.git" ]; then
                local installed_commit
                installed_commit=$(git -C "$dest" rev-parse HEAD 2>/dev/null) || installed_commit=""
                if _git_short_matches "$installed_commit" "$KARAWUN_COMMIT"; then
                    ok "conda env 'KarawunDev' already exists at the pinned commit (${installed_commit:0:8})"
                    return
                fi
                version_gate "KarawunDev (karawun)" "${installed_commit:-unknown}" "$KARAWUN_COMMIT" && return
            else
                ok "conda env 'KarawunDev' already exists (no git checkout at $dest to verify -- assuming OK)"
                return
            fi
        fi
        log "Creating 'KarawunDev' (editable install, karawun $KARAWUN_COMMIT + dcm2bids 3.1.1)"
        run "$(mamba_bin) create -n KarawunDev python=3.14 -y"
        run "'$(env_bin KarawunDev pip)' install dcm2bids>=3.1"
        [ -d "$dest" ] || run "git clone -b '$KARAWUN_BRANCH' '$KARAWUN_REPO' '$dest'"
        run "cd '$dest' && git checkout $KARAWUN_COMMIT"
        run "cd '$dest' && '$(env_bin KarawunDev pip)' install -e ."
        ok "KarawunDev ready"
    else
        if env_exists KarawunEnv; then
            local installed_ver
            installed_ver=$("$(mamba_bin)" list -n KarawunEnv karawun 2>/dev/null | awk '$1=="karawun"{print $2}')
            if [ "$installed_ver" = "$KARAWUN_STOCK_VERSION" ]; then
                ok "conda env 'KarawunEnv' already exists at the pinned version ($installed_ver)"
                return
            elif [ -n "$installed_ver" ]; then
                version_gate "KarawunEnv (karawun)" "$installed_ver" "$KARAWUN_STOCK_VERSION" && return
            else
                ok "conda env 'KarawunEnv' already exists (couldn't read the installed karawun version -- assuming OK)"
                return
            fi
        fi
        log "Creating 'KarawunEnv' (plain conda-forge package, no git clone needed)"
        run "$(mamba_bin) create -n KarawunEnv python=3.8 karawun=$KARAWUN_STOCK_VERSION -c conda-forge -y"
        ok "KarawunEnv ready (used by KUL_karawun_prepare.sh / KUL_karawun2brainlab.sh)"
        warn "KarawunEnv (v$KARAWUN_STOCK_VERSION) will silently corrupt output DICOMs given an Enhanced/multi-frame donor (e.g. Philips) -- re-run with --karawun-dev if that's a possibility at your site"
    fi
}

# ── 4e. FastSurfer env (faster recon-all alternative; needs FreeSurfer 8 for compat) ──

section_env_fastsurfer() {
    local dest="$SOFTWARE_ROOT/src/FastSurfer"
    # FastSurfer's native-install method upstream is uv + a per-checkout .venv,
    # not a conda env (confirmed against the current repo: env/environment_gpu.yml
    # no longer exists, only an empty env/fastsurfer.yml placeholder; their own
    # docs now say 'uv venv' + 'uv pip sync requirements.txt --torch-backend
    # <backend>'). This section installs uv into the isolated miniforge3 base env
    # (self-contained — just a pip package, no separate download/PATH entry) and
    # uses it to build FastSurfer's own venv the same way.
    if [ -d "$dest/.venv" ]; then
        ok "FastSurfer already cloned with a .venv at $dest"
        return
    fi
    log "Cloning FastSurfer and building its uv venv"
    [ -d "$dest" ] || run "git clone https://github.com/Deep-MI/FastSurfer.git '$dest'"
    if [ ! -x "$SOFTWARE_ROOT/miniforge3/bin/uv" ]; then
        run "'$SOFTWARE_ROOT/miniforge3/bin/pip' install uv"
    fi
    local uv="$SOFTWARE_ROOT/miniforge3/bin/uv"
    run "cd '$dest' && '$uv' venv --python 3.12"
    # torch-backend: pick_torch_cuda_tag probes for the newest CUDA backend
    # that (a) actually has a build for whatever exact torch version this
    # freshly-cloned requirements.txt pins right now (read below, not
    # hardcoded -- FastSurfer bumps this pin over time) and (b) this driver
    # supports. Falls back to "cpu" if nothing fits or no GPU.
    local fs_torch_version torch_backend
    fs_torch_version=$(grep -oP '^torch==\K[0-9.]+' "$dest/requirements.txt" 2>/dev/null | head -1) || true
    if [ "$DRY_RUN" -eq 1 ] && [ -z "$fs_torch_version" ]; then
        torch_backend="cu118" # placeholder for the dry-run echo below; requirements.txt doesn't exist yet pre-clone
    else
        torch_backend=$(pick_torch_cuda_tag "$SOFTWARE_ROOT/miniforge3/bin/pip" "$fs_torch_version")
    fi
    # Must be compile-then-sync, NOT a direct 'uv pip sync requirements.txt' —
    # confirmed bug: requirements.txt deliberately excludes nvidia-* CUDA
    # runtime packages from its pinned list (per its own header comment) and
    # expects the compile step to resolve them in transitively; 'sync' alone
    # only installs packages literally listed in the file, silently skipping
    # the runtime libs and leaving torch unable to import
    # ("libcudart.so.11.0: cannot open shared object file").
    run "cd '$dest' && '$uv' pip compile --torch-backend $torch_backend requirements.txt --python .venv/bin/python | '$uv' pip sync --torch-backend $torch_backend --python .venv/bin/python -"
    # Wrapper shim: run_fastsurfer.sh calls plain python3 with no self-activation
    # of its own venv, and it's invoked both by full path and by bare name (via
    # PATH) across different KUL_NIS/KUL_VBG scripts. Renaming the real script
    # and dropping a wrapper at the original filename covers both invocation
    # styles without touching any KUL_NIS/KUL_VBG source.
    if [ -f "$dest/run_fastsurfer.sh" ] && [ ! -f "$dest/run_fastsurfer.real.sh" ]; then
        run "mv '$dest/run_fastsurfer.sh' '$dest/run_fastsurfer.real.sh'"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would write the run_fastsurfer.sh venv-activation wrapper shim"
    else
        cat > "$dest/run_fastsurfer.sh" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Wrapper shim: activates FastSurfer's uv-managed .venv (run_fastsurfer.real.sh
# calls plain python3 with no self-activation), then hands off. Scoped to this
# process via exec -- never leaks back to the calling shell.
set -euo pipefail
if [[ -z "${BASH_SOURCE[0]}" ]]; then THIS_SCRIPT="$0"
else THIS_SCRIPT="${BASH_SOURCE[0]}"
fi
FASTSURFER_HOME="$(cd "$(dirname "$THIS_SCRIPT")" &>/dev/null && pwd)"
source "$FASTSURFER_HOME/.venv/bin/activate"
exec "$FASTSURFER_HOME/run_fastsurfer.real.sh" "$@"
WRAPPER_EOF
        chmod +x "$dest/run_fastsurfer.sh"
    fi
    warn "Set FASTSURFER_HOME=$dest in your shell — KUL_anat_segment_tumor.sh calls \
\$FASTSURFER_HOME/run_fastsurfer.sh directly (and KUL_FS_multiparc.sh/KUL_clinical_fmridti.sh/KUL_VBG.sh \
call it by bare name via PATH); the wrapper shim handles venv activation either way. \
KUL_NIS's README requires FastSurfer v3+ for FreeSurfer 8 compatibility."
    ok "FastSurfer section done (uv venv + wrapper shim — verify torch imports and reports cuda available if you have a GPU)"
}

# ── 4f. shared Python fMRI env (KUL_NIS/share/rsfmri_pipeline + nilearn tbfMRI) ─
# Both KUL_run_rsfMRI_networks.sh and KUL_fmriproc_nilearn_new.sh hardcode this
# exact env name and quit if it isn't found — there is no flag to point either
# script at a differently-named env, so this section is not skippable in
# practice: without it, both the rsfMRI network-mapping step (-N) and the
# nilearn task-fMRI GLM engine (-E nilearn) in KUL_clinical_fmridti.sh fail
# immediately (or, before this was consolidated, failed later and less
# obviously against a bare `python3` lacking these packages).

section_env_pyfmri() {
    if env_exists pyfMRI; then
        ok "conda env 'pyfMRI' already exists"
        return
    fi
    # Migration: this env used to be named 'rsfmri_env'. If that's still
    # around (and 'pyfMRI' isn't, checked above), rename it in place via
    # clone+remove rather than re-downloading/re-resolving everything.
    if env_exists rsfmri_env; then
        log "Found legacy env 'rsfmri_env' — renaming to 'pyfMRI' (clone + remove)"
        run "$(mamba_bin) create -n pyfMRI --clone rsfmri_env -y"
        run "$(mamba_bin) env remove -n rsfmri_env -y"
        ok "'rsfmri_env' migrated to 'pyfMRI'"
        return
    fi
    log "Creating 'pyfMRI' (nilearn/nibabel/numpy/scipy/pandas/matplotlib/pyyaml — \
shared by KUL_run_rsfMRI_networks.sh and KUL_fmriproc_nilearn_new.sh, both of which \
hardcode this env name; no hardcoded version pins upstream, so this creates \
everything fresh together in one resolver pass to avoid ABI drift between \
packages installed piecemeal over time)"
    run "$(mamba_bin) create -n pyfMRI -c conda-forge python=3.10 nilearn nibabel numpy scipy pandas matplotlib pyyaml -y"
    ok "pyfMRI ready — used automatically by KUL_run_rsfMRI_networks.sh and KUL_fmriproc_nilearn_new.sh"
}

section_env_dicom() {
    if env_exists KUL_dicom; then
        ok "conda env 'KUL_dicom' already exists"
        return
    fi
    # pydicom is a hard requirement, not a nicety: SimpleITK/GDCM refuses to write
    # a non-integer RescaleSlope/Intercept and silently inverse-rescales the pixel
    # data instead, so -q/--label (the measurable series an ROI on PACS reads in
    # true units) fail without it.
    #
    # KUL_NIS ships an equivalent share/envs/KUL_dicom.yml for creating this by
    # hand. Keep the two in step if either changes; the package set is small and
    # deliberately duplicated here so the installer stays self-contained and can
    # run before (or without) KUL_NIS being cloned.
    log "Creating 'KUL_dicom' (SimpleITK/Pillow/numpy/pydicom — used by KUL_nii2dcm.py, \
the NIfTI/PNG -> DICOM step behind KUL_clinical_fmridti.sh -R)"
    run "$(mamba_bin) create -n KUL_dicom -c conda-forge 'python>=3.10' 'simpleitk>=2.2' \
'pillow>=9.1' 'numpy>=1.24' 'pydicom>=2.3' -y"
    ok "KUL_dicom ready — found automatically via \$KUL_DICOM_ENV; override with KUL_clinical_fmridti.sh -m"
}

# ── 5. Sibling repos, pinned branches ──────────────────────────────────────────

section_repos() {
    log "Cloning KUL_NIS / KUL_VBG / KUL_FWT at their pinned branches"
    local src="$SOFTWARE_ROOT/src"

    clone_at() {
        local url="$1" dir="$2" branch="$3"
        if [ -d "$src/$dir" ]; then
            ok "$dir already cloned at $src/$dir"
        else
            run "git clone '$url' '$src/$dir'"
            run "cd '$src/$dir' && git checkout '$branch'"
            ok "$dir @ $branch"
        fi
    }

    clone_at https://github.com/treanus/KUL_NIS.git       KUL_NIS    "$KUL_NIS_BRANCH"
    clone_at https://github.com/KUL-Radneuron/KUL_VBG.git KUL_VBG    "$KUL_VBG_BRANCH"
    clone_at https://github.com/KUL-Radneuron/KUL_FWT.git KUL_FWT    "$KUL_FWT_BRANCH"

    warn "Add these to PATH (see the ~/.bashrc block this script writes): \
$src/KUL_NIS, $src/KUL_VBG, $src/KUL_FWT, and KUL_NIS/KUL_DTI_ALPS. \
KUL_FWT's own scripts must resolve on PATH before running KUL_clinical_fmridti.sh — \
it no longer auto-prepends a sibling ../KUL_FWT folder."
}

# ── 5b. LoRE-SD (DWI decomposition; regular pip package, NOT an MRtrix3 module build) ──
# Despite living on a branch named 'mrtrix_module' and mentioning MRtrix3 module
# builds in older docs, LoRE-SD is just installed as a normal editable pip
# package (setup.py + pybind11/nlopt/cmake) — confirmed working via a validated
# install sequence. No mrtrix3 source tree needed.

section_env_lore_sd() {
    if env_exists lore_sd; then
        ok "conda env 'lore_sd' already exists"
        return
    fi
    local dest="$SOFTWARE_ROOT/src/LoRE-SD"
    [ -d "$dest" ] || run "git clone --branch mrtrix_module https://github.com/SiebeLeysen/LoRE-SD.git '$dest'"
    log "Creating 'lore_sd' env (python 3.10, nlopt/cmake/compilers via conda-forge, editable pip install)"
    run "$(mamba_bin) create -n lore_sd python=3.10 -y"
    run "$(mamba_bin) install -n lore_sd -c conda-forge nlopt cmake compilers -y"
    run "'$(env_bin lore_sd pip)' install pybind11 numpy setuptools wheel"
    run "cd '$dest' && '$(env_bin lore_sd pip)' install -e . --no-build-isolation"
    ok "lore_sd env ready — lore_dwi2decomposition / lore_decomposition2contrast available in it \
(used by KUL_dwiprep -D run_dwiprep_lore_sd.txt)"
}

# ── 6. MRtrix3 (build from source) ────────────────────────────────────────────

section_mrtrix3() {
    if have mrconvert; then
        local installed_ver installed_hash pinned_short
        installed_ver=$(mrconvert -version 2>&1 | head -1)
        installed_hash=$(echo "$installed_ver" | grep -oP '(?<=-g)[0-9a-f]+' | head -1)
        pinned_short="${MRTRIX3_COMMIT:0:8}"
        if _git_short_matches "$installed_hash" "$pinned_short"; then
            ok "mrconvert already on PATH at the pinned commit ($installed_ver)"
            return
        fi
        version_gate "mrtrix3" "${installed_hash:-$installed_ver}" "$pinned_short ($MRTRIX3_BRANCH)" && return
    fi
    local dest="$SOFTWARE_ROOT/src/mrtrix3"
    log "Building MRtrix3 @ $MRTRIX3_COMMIT via CMake+Ninja (this takes a while)"

    # As of Oct 2023 (commit 06e8e4cde) upstream removed the classic
    # ./configure && ./build scripts entirely -- the dev branch only builds
    # with CMake now. Installing with --prefix pointed back at the clone
    # itself (rather than a separate install dir) keeps bin/lib/python
    # layout compatible with the rest of this script (PATH/PYTHONPATH below
    # are unchanged from the old classic-build layout: cmake --install
    # still populates $dest/bin and $dest/lib/mrtrix3 the same way).
    [ -d "$dest" ] || run "git clone -b '$MRTRIX3_BRANCH' '$MRTRIX3_REPO' '$dest'"
    run "cd '$dest' && git checkout '$MRTRIX3_COMMIT'"

    # -DCMAKE_IGNORE_PREFIX_PATH excludes miniforge3 from find_package() searches
    # entirely: without it, cmake can silently pick up a *conda* Qt (e.g. from
    # the pyfMRI env, which pulls one in transitively via matplotlib) instead of
    # the system one, producing a mrview that's built against one Qt but
    # resolves a different, incompatible one (undefined symbol version errors)
    # at runtime. -DQt<N>_DIR pins the exact system Qt CMake config as a second,
    # more surgical guard against the same class of ambiguity.
    #
    # Qt6 is preferred, with a Qt5 fallback for older distributions (Linux Mint
    # 20/21 and anything else on a base without qt6-base-dev). The switch is
    # mrtrix3's own supported option -- CMakeLists.txt declares
    # option(MRTRIX_USE_QT5 "Use Qt 5 to build" OFF) and cpp/gui/CMakeLists.txt
    # branches on it between find_package(Qt5 ...)/qt5_add_resources and the Qt6
    # pair -- so this is a supported configuration, not a workaround.
    #
    # Detection is by capability (does the Qt6 CMake config exist?) rather than
    # by distro release, so it degrades correctly on any base without needing a
    # version whitelist kept up to date.
    local qt6_cmake_dir="/usr/lib/x86_64-linux-gnu/cmake/Qt6"
    local qt5_cmake_dir="/usr/lib/x86_64-linux-gnu/cmake/Qt5"
    local qt_cmake_args qt_major
    if [ -f "$qt6_cmake_dir/Qt6Config.cmake" ]; then
        qt_major=6
        qt_cmake_args="-DQt6_DIR='$qt6_cmake_dir'"
    elif [ -f "$qt5_cmake_dir/Qt5Config.cmake" ]; then
        qt_major=5
        qt_cmake_args="-DMRTRIX_USE_QT5=ON -DQt5_DIR='$qt5_cmake_dir'"
        warn "System Qt6 CMake config not found at $qt6_cmake_dir -- falling back to \
Qt5 ($qt5_cmake_dir) and building mrview with -DMRTRIX_USE_QT5=ON. This is expected on \
older bases (e.g. Linux Mint 20/21); mrview and xvfb-run offscreen rendering both work \
the same way under Qt5."
    else
        qt_major=6
        qt_cmake_args="-DQt6_DIR='$qt6_cmake_dir'"
        warn "Neither Qt6 nor Qt5 CMake config found ($qt6_cmake_dir, $qt5_cmake_dir) \
-- apt Qt package layout may differ on this OS/arch. Proceeding with Qt6; cmake may pick \
up an unintended Qt (e.g. from a conda env) or fail outright. Check that qt6-base-dev (or \
libqt5opengl5-dev) is installed and locate the actual Qt<N>Config.cmake if this fails."
    fi

    # mrview renders screenshots through xvfb-run (see KUL_clinical_fmridti.sh),
    # which needs Qt's *xcb* platform plugin at runtime -- a different package
    # from the CMake config found above. Missing it is a silent failure mode:
    # the build succeeds and every screenshot dies at run time instead.
    local qt_xcb_plugin="/usr/lib/x86_64-linux-gnu/qt${qt_major}/plugins/platforms/libqxcb.so"
    if [ ! -f "$qt_xcb_plugin" ]; then
        warn "Qt${qt_major} xcb platform plugin not found at $qt_xcb_plugin -- mrview will \
build but headless screenshots via xvfb-run will fail. Install it with: sudo apt install -y \
$( [ "$qt_major" = 5 ] && echo 'libqt5gui5' || echo 'qt6-qpa-plugins' )   (on Ubuntu 24.04+ \
the Qt5 package is named libqt5gui5t64)."
    fi

    log "Building mrview against Qt${qt_major}"
    # /usr/bin/cmake (and CMAKE_MAKE_PROGRAM=/usr/bin/ninja) explicitly, not a
    # bare 'cmake' resolved via PATH -- confirmed bug: any shell that already
    # sourced a DIFFERENT, unrelated conda/mamba setup before this script ran
    # (e.g. a pre-existing dev environment's ~/.bashrc block, prepending its
    # own miniforge3/bin onto PATH ahead of anything this script installs) can
    # silently substitute a wrong cmake here. Its own default search prefixes
    # then pull in that OTHER conda env's incomplete zlib (runtime .so.1 only,
    # no dev libz.so symlink), so find_package(ZLIB) reports the version fine
    # (from the system header) but fails on ZLIB_LIBRARY -- CMAKE_IGNORE_PREFIX_PATH
    # above only excludes THIS root's own miniforge, not some other one.
    # /usr/bin/cmake always exists at that fixed path once section_apt's
    # 'cmake' package is installed, so it sidesteps PATH ambiguity entirely --
    # same "don't trust bare-name PATH resolution" principle as env_bin/
    # mamba_bin/conda_bin elsewhere in this script.
    #
    # Pinning the cmake BINARY alone is not sufficient -- confirmed live:
    # even invoked via /usr/bin/cmake, CMake's own compiler detection still
    # resolves a bare 'cc'/'c++' via the same contaminated PATH, landing on
    # that other conda env's own bundled GCC (its 'compilers' package) rather
    # than the system one, which is what was actually biasing ZLIB_LIBRARY
    # detection toward that conda env's incomplete zlib -- reproduced and
    # confirmed fixed in isolation with a trivial find_package(ZLIB) test.
    # /usr/bin/gcc-12 / g++-12 are pinned explicitly here for the same reason
    # section_ants already pins them (see the ITK/GCC13 comment there) --
    # reusing the identical, already-proven-working pair rather than
    # introducing a second, untested compiler combination in this script.
    #
    # Pinning cmake + the compiler is STILL not sufficient -- confirmed live,
    # a third layer of the same bug: GCC finds its own subprograms (ld, as)
    # by searching PATH itself (unless told otherwise), so the final link
    # step silently used that other conda env's ld (GNU Binutils 2.45.1,
    # bundled by its own 'compilers' package) instead of the system one
    # (2.38, what every /usr/lib .so on this machine was actually built
    # against) -- producing hundreds of bogus "undefined reference" errors
    # for symbols in transitively-linked system libraries (libkrb5, libX11,
    # libharfbuzz, etc.) that a 7-major-version-newer linker resolves
    # differently. -B/usr/bin makes gcc/g++ search there FIRST for ld/as,
    # confirmed live to correctly resolve to the real system linker.
    run "cd '$dest' && /usr/bin/cmake -B build -GNinja \
        -DCMAKE_MAKE_PROGRAM=/usr/bin/ninja \
        -DCMAKE_C_COMPILER=/usr/bin/gcc-12 \
        -DCMAKE_CXX_COMPILER=/usr/bin/g++-12 \
        -DCMAKE_C_FLAGS=-B/usr/bin \
        -DCMAKE_CXX_FLAGS=-B/usr/bin \
        -DCMAKE_EXE_LINKER_FLAGS=-B/usr/bin \
        -DCMAKE_SHARED_LINKER_FLAGS=-B/usr/bin \
        -DCMAKE_INSTALL_PREFIX='$dest' \
        -DCMAKE_IGNORE_PREFIX_PATH='$SOFTWARE_ROOT/miniforge3' \
        $qt_cmake_args"
    run "cd '$dest' && /usr/bin/cmake --build build -j$NCPU"
    run "cd '$dest' && /usr/bin/cmake --install build"

    # mrview's toolbar icons and custom tool cursors are loaded at runtime as
    # Qt resources ending in .svg (cpp/gui/cursor.cpp etc use the generic
    # QPixmap(":/foo.svg") constructor) -- this resolves via Qt's *runtime*
    # image-format plugin system, not compile-time linking (the gui
    # CMakeLists.txt never links Qt6::Svg at all). Without qt6-svg-dev
    # installed, every icon/cursor silently fails to load: mrview still
    # opens, but with blank toolbar buttons and a repeated "QCursor: Cannot
    # create bitmap cursor; invalid bitmap(s)" warning. apt (section_apt)
    # installs qt6-svg-dev (and libqt5svg5-dev for the Qt5 path) for exactly
    # this reason -- if that's missing here, something upstream didn't run.
    local qt_svg_pkg
    [ "$qt_major" = 5 ] && qt_svg_pkg="libqt5svg5-dev" || qt_svg_pkg="qt6-svg-dev"
    if ! dpkg -s "$qt_svg_pkg" >/dev/null 2>&1; then
        warn "$qt_svg_pkg not detected -- mrview will open but with missing \
toolbar icons and broken tool cursors (QCursor 'invalid bitmap(s)' warnings). \
Run: sudo apt install -y $qt_svg_pkg"
    fi

    ok "mrtrix3 built at $dest (add $dest/bin to PATH — done automatically in the bashrc section)"
}

# ── 6b. shard-recon (external MRtrix3 module) ─────────────────────────────────
# dwimotioncorrect/mssh2amp, invoked by KUL_dwiprep.sh's shard_recon: 1 config
# option (off in every shipped config by default). Built out-of-tree against
# the mrtrix3 source above, following Daan Christiaens' own build
# instructions (gitlab.com/ChD/shard-recon / github.com/dchristiaens/shard-recon):
# symlink mrtrix3's `build` script and `bin/mrtrix3.py` into the shard-recon
# checkout, then run `./build` there.
#
# CURRENTLY BROKEN against the mrtrix3 dev-branch/CMake pin above: upstream
# removed the classic `build` script entirely in Oct 2023 (see MRTRIX3_COMMIT
# comment), and shard-recon's own build process has no CMake equivalent as of
# its latest commit (checked github.com/dchristiaens/shard-recon, last
# activity June 2025 -- still documents the classic-build symlink method
# only). DO_SHARD_RECON therefore defaults to 0. If shard-recon adds CMake
# support upstream, or you build a second classic-build mrtrix3 tree
# specifically for this, re-enable and adjust mrtrix_dest below accordingly.

section_shard_recon() {
    if have dwimotioncorrect; then
        ok "shard-recon (dwimotioncorrect) already on PATH"
        return
    fi
    local mrtrix_dest="$SOFTWARE_ROOT/src/mrtrix3"
    # -f (regular file), not -x: the new CMake build/ is a *directory* and
    # directories are typically traversable (+x) regardless of whether a
    # classic build script exists, so an -x check alone would not reliably
    # tell the two build layouts apart.
    if [ ! -f "$mrtrix_dest/build" ] || [ ! -x "$mrtrix_dest/build" ] || [ ! -f "$mrtrix_dest/bin/mrtrix3.py" ]; then
        warn "Skipping shard-recon: no classic-build mrtrix3 tree found at $mrtrix_dest \
(expected a 'build' script there, not a CMake 'build/' directory). shard-recon has no \
CMake-based build of its own as of its latest upstream commit — see the comment above \
section_shard_recon in this script for details."
        return
    fi
    local dest="$SOFTWARE_ROOT/src/shard-recon"
    log "Building shard-recon (external MRtrix3 module for dwimotioncorrect/mssh2amp)"
    [ -d "$dest" ] || run "git clone https://github.com/dchristiaens/shard-recon.git '$dest'"
    [ -L "$dest/build" ] || run "ln -s '$mrtrix_dest/build' '$dest/build'"
    [ -L "$dest/bin/mrtrix3.py" ] || run "mkdir -p '$dest/bin' && ln -s '$mrtrix_dest/bin/mrtrix3.py' '$dest/bin/mrtrix3.py'"
    run "cd '$dest' && NUMBER_OF_PROCESSORS=$NCPU ./build"
    ok "shard-recon built at $dest (add $dest/bin to PATH — done automatically in the bashrc section)"
}

# ── 7. ANTs (build from source) ───────────────────────────────────────────────

section_ants() {
    if have antsRegistrationSyN.sh; then
        local installed_ver installed_hash
        installed_ver=$(antsRegistration --version 2>&1 | head -1)
        installed_hash=$(echo "$installed_ver" | grep -oP '(?<=-g)[0-9a-f]+' | head -1)
        if _git_short_matches "$installed_hash" "$ANTS_COMMIT"; then
            ok "ANTs already on PATH at the pinned commit ($installed_ver)"
            return
        fi
        version_gate "ANTs" "${installed_hash:-$installed_ver}" "$ANTS_COMMIT (v2.4.4.post20)" && return
    fi
    local dest="$SOFTWARE_ROOT/src/ANTs"
    log "Building ANTs @ $ANTS_COMMIT (v2.4.4.post20) — this takes a long while"
    [ -d "$dest" ] || run "git clone https://github.com/ANTsX/ANTs.git '$dest'"
    run "cd '$dest' && git checkout '$ANTS_COMMIT'"
    # ANTs vendors a mid-2023 ITKv5 snapshot with several auto-generated Enum
    # headers (e.g. itkMathematicalMorphologyEnums.h) that rely on <cstdint>
    # being transitively included via another standard header -- GCC 13
    # (default on Ubuntu 24.04) stopped doing that, so the ITK sub-build fails
    # partway through with "'uint8_t' was not declared" (confirmed: a known,
    # documented ITK/GCC13 incompatibility -- discourse.itk.org/t/itkmathematicalmorphologyenums-h-compile-error-with-gcc-13-on-linux/6377,
    # ITK issue #4607 -- not specific to this machine). Building with gcc-12
    # instead sidesteps the whole class of breakage rather than patching
    # vendored ITK source file-by-file as each one surfaces.
    if [ -f "$dest/build/CMakeCache.txt" ] && ! grep -q "g++-12\|gcc-12" "$dest/build/CMakeCache.txt" 2>/dev/null; then
        warn "Existing ANTs build dir was configured with a different compiler — removing it for \
a clean reconfigure against gcc-12 (any prior partial build progress is lost, but mixing compilers \
mid-build isn't safe anyway)"
        run "rm -rf '$dest/build'"
    fi
    run "mkdir -p '$dest/build'"
    # /usr/bin/cmake and /usr/bin/make explicitly, not bare names -- same
    # PATH-shadowing risk as section_mrtrix3 above (a different, unrelated
    # conda/mamba setup already active in the shell can substitute a wrong
    # cmake here too), fixed the same way: apt-installed build tools always
    # live at this fixed system path regardless of shell PATH ordering.
    # -B/usr/bin also pins gcc-12/g++-12's own subprogram search (ld, as) to
    # the system ones -- confirmed live in section_mrtrix3 that GCC otherwise
    # finds a bare 'ld' via PATH too, silently picking up that other conda
    # env's much newer (and ABI-incompatible with this system's .so files)
    # binutils and failing the link step with hundreds of bogus "undefined
    # reference" errors.
    run "cd '$dest/build' && /usr/bin/cmake -DCMAKE_C_COMPILER=/usr/bin/gcc-12 -DCMAKE_CXX_COMPILER=/usr/bin/g++-12 -DCMAKE_C_FLAGS=-B/usr/bin -DCMAKE_CXX_FLAGS=-B/usr/bin -DCMAKE_EXE_LINKER_FLAGS=-B/usr/bin -DCMAKE_SHARED_LINKER_FLAGS=-B/usr/bin -DCMAKE_INSTALL_PREFIX='$SOFTWARE_ROOT/src/ANTs_install' .."
    run "cd '$dest/build' && /usr/bin/make -j$NCPU"
    run "cd '$dest/build/ANTS-build' && /usr/bin/make install"
    ok "ANTs installed to $SOFTWARE_ROOT/src/ANTs_install"
}

# ── 8. FSL ─────────────────────────────────────────────────────────────────────

section_fsl() {
    if [ -x "$SOFTWARE_ROOT/src/FSL/bin/flirt" ] || have flirt; then
        # Confirmed bug (found live): using ${FSLDIR:-$SOFTWARE_ROOT/src/FSL}
        # here (matching section_verify's own lookup) let an inherited
        # FSLDIR from a completely different, pre-existing shell environment
        # (e.g. a shared /usr/local/fsl install exported by an unrelated
        # ~/.bashrc block) override a build that's ALREADY correctly sitting
        # under this root at the pinned version -- the direct-path check just
        # above finds it fine, but the version check then read the OTHER
        # FSLDIR's fslversion instead and reported a false mismatch against
        # an install this script never touched. This root's own copy, if
        # present, always wins; $FSLDIR is only the fallback when this root
        # has nothing of its own to check (e.g. only 'have flirt' matched).
        local fsl_root="$SOFTWARE_ROOT/src/FSL"
        [ -f "$fsl_root/etc/fslversion" ] || fsl_root="${FSLDIR:-$fsl_root}"
        if [ -f "$fsl_root/etc/fslversion" ]; then
            local installed_ver
            installed_ver="$(cat "$fsl_root/etc/fslversion")"
            if [ "$installed_ver" = "$FSL_VERSION" ]; then
                ok "FSL already installed at the pinned version ($installed_ver)"
                return
            fi
            version_gate "FSL" "$installed_ver" "$FSL_VERSION" && return
        else
            ok "FSL already installed (no $fsl_root/etc/fslversion to check against the pinned $FSL_VERSION -- assuming OK)"
            return
        fi
    fi
    log "Installing FSL $FSL_VERSION via the official installer"
    local installer="$SOFTWARE_ROOT/tmp/fslinstaller.py"
    run "curl -fsSL -o '$installer' https://fsl.fmrib.ox.ac.uk/fsldownloads/fslinstaller.py"
    warn "FSL installer syntax changes across releases (SOFTWARE_ROOT_SETUP.md flags this) — \
if the -V flag below is rejected, check 'python3 $installer --help' for the current syntax."
    # -s/--no_shell: fslinstaller.py has its own independent configure_shell()
    # step that writes a "FSL Setup" FSLDIR/PATH block straight into
    # ~/.profile (or ~/.bash_profile) -- confirmed live, it did so on this
    # machine unless told not to. That's a third, redundant source of FSL
    # environment config on top of section_bashrc's own managed ~/.bashrc
    # block (which already handles FSLDIR/PATH correctly) -- harmless only by
    # coincidence when it happens to agree, actively wrong if this section
    # ever rebuilds FSL to a newer pinned version and the .profile copy goes
    # stale. section_bashrc is the one authoritative place this script
    # manages shell config; let it stay that way.
    run "python3 '$installer' -d '$SOFTWARE_ROOT/src/FSL' -V '$FSL_VERSION' -s"
    ok "FSL installed to $SOFTWARE_ROOT/src/FSL"
}

# ── 9. FreeSurfer — software auto-downloaded, only the license is manual ─────
# Confirmed: FreeSurfer 8.2.0's own .deb download (surfer.nmr.mgh.harvard.edu)
# needs no login -- only the separate license.txt is registration-gated (a
# personal file emailed to you, used at runtime, not needed to fetch the
# software itself). Since FreeSurfer moved to a fixed-prefix .deb/.rpm
# installer as of the 8.0 release (no more relocatable tarball), this extracts
# the .deb's payload directly with dpkg-deb -x -- NOT a real 'dpkg -i' system
# install -- so it lands under $SOFTWARE_ROOT like everything else here, no
# root/dpkg-database registration needed.

section_freesurfer() {
    if [ -f "$SOFTWARE_ROOT/src/freesurfer/SetUpFreeSurfer.sh" ]; then
        ok "FreeSurfer already present at $SOFTWARE_ROOT/src/freesurfer"
    else
        local rel debfile url tmpdir pkgname real_home
        rel="$(ubuntu_release)"
        case "$rel" in
            22.*) debfile="freesurfer_ubuntu22-8.2.0_amd64.deb" ;;
            24.*) debfile="freesurfer_ubuntu24-8.2.0_amd64.deb" ;;
            *)
                warn "No FreeSurfer 8.2.0 .deb published for Ubuntu $rel (only 22.04/24.04 are) -- \
falling back to the ubuntu24 build; if this machine is much older/newer that may not run cleanly. \
Check https://surfer.nmr.mgh.harvard.edu/fswiki/rel8download for other options if it doesn't."
                debfile="freesurfer_ubuntu24-8.2.0_amd64.deb"
                ;;
        esac
        url="https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/8.2.0/$debfile"
        log "Downloading and installing FreeSurfer 8.2.0 ($debfile, several GB -- this takes a while)"
        tmpdir="$SOFTWARE_ROOT/tmp/freesurfer_extract"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    [dry-run] would download $url and install it via dpkg/apt (a REAL system \
install, landing outside \$SOFTWARE_ROOT), then symlink \$SOFTWARE_ROOT/src/freesurfer to wherever it lands"
        else
            rm -rf "$tmpdir"
            mkdir -p "$tmpdir"
            curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$tmpdir/freesurfer.deb" "$url"
            # Real system install, NOT dpkg-deb -x -- confirmed bug (found live): a
            # payload-only extraction skips the .deb's declared runtime-library
            # dependencies, which broke 'freeview' ("libITKCommon-5.3.so.1: cannot
            # open shared object file") since ITK isn't bundled inside FreeSurfer's
            # own tree, only referenced as a dependency apt is expected to supply.
            # 'dpkg -i' commonly exits non-zero here (reports missing deps, still
            # unpacks the files) -- that's expected, not a real failure, which is
            # why the next 'apt-get install -f' step exists to resolve and install
            # them and finish configuring the package. This is the standard,
            # universally-compatible way to install a local .deb with dependencies.
            # Consequence: FreeSurfer is the one component that no longer lives
            # under $SOFTWARE_ROOT (symlinked instead) -- current upstream FreeSurfer
            # packaging (.deb/.rpm only since 8.0) doesn't support a relocatable
            # install at all, so this isn't something a smarter extraction could fix.
            sudo dpkg -i "$tmpdir/freesurfer.deb" || true
            sudo apt-get install -f -y
            pkgname="$(dpkg-deb -f "$tmpdir/freesurfer.deb" Package)"
            real_home="$(dpkg -L "$pkgname" 2>/dev/null | grep -m1 'SetUpFreeSurfer\.sh$')" || true
            real_home="${real_home%/SetUpFreeSurfer.sh}"
            rm -rf "$tmpdir"
            if [ -z "$real_home" ] || [ ! -f "$real_home/SetUpFreeSurfer.sh" ]; then
                fail "Installed via apt, but couldn't determine where it landed -- find it yourself \
('sudo find / -name SetUpFreeSurfer.sh') and 'ln -sfn <that dir> $SOFTWARE_ROOT/src/freesurfer'."
            else
                if [ ! -L "$SOFTWARE_ROOT/src/freesurfer" ] && [ -e "$SOFTWARE_ROOT/src/freesurfer" ]; then
                    warn "Removing old $SOFTWARE_ROOT/src/freesurfer (leftover from a previous \
payload-only extraction, now superseded by this real install)"
                    rm -rf "$SOFTWARE_ROOT/src/freesurfer"
                fi
                ln -sfn "$real_home" "$SOFTWARE_ROOT/src/freesurfer"
                ok "FreeSurfer 8.2.0 installed to $real_home (symlinked from $SOFTWARE_ROOT/src/freesurfer)"
            fi
        fi
    fi

    local fs_license="$SOFTWARE_ROOT/src/freesurfer/license.txt"
    if [ -f "$fs_license" ]; then
        ok "license.txt present"
    elif [ "$DRY_RUN" -eq 1 ]; then
        :
    elif [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        warn "No license.txt yet -- this part genuinely can't be automated (personal registration \
required). Register at https://surfer.nmr.mgh.harvard.edu/registration.html, then place the file \
they email you at $fs_license. KUL_VBG.sh, KUL_FS_multiparc.sh, MSBP (via Docker), and recon-all \
itself will all refuse to run without one."
    else
        warn "No license.txt found -- this part genuinely can't be automated (personal registration required)."
        read -r -p "  Path to an existing license.txt on this machine (blank to skip and add it later): " _fs_lic_path
        if [ -n "$_fs_lic_path" ] && [ -f "$_fs_lic_path" ]; then
            sudo cp "$_fs_lic_path" "$fs_license"
            ok "license.txt copied from $_fs_lic_path"
        elif [ -n "$_fs_lic_path" ]; then
            fail "No file found at '$_fs_lic_path' -- skipping. Register at \
https://surfer.nmr.mgh.harvard.edu/registration.html, then place it at $fs_license yourself."
        else
            warn "Skipped. Register at https://surfer.nmr.mgh.harvard.edu/registration.html, then \
place the file they email you at $fs_license."
        fi
    fi

    # Official, checksummed post-release patches -- confirmed live and legitimate
    # (surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/8.2.0/fs820_updates.sh):
    # verifies each patched file's checksum both before and after replacing it,
    # aborts on any mismatch, and explicitly recognizes Ubuntu 24. Re-running
    # this is always safe/idempotent -- it no-ops on files that already match.
    # NOTE: filename ("fs820_updates.sh") is specific to 8.2.0 -- if FreeSurfer's
    # pinned version above is ever bumped, this needs updating to match.
    # Requires a browser-style User-Agent -- confirmed the plain curl default
    # gets a 403 from this particular path on their server.
    if [ ! -f "$SOFTWARE_ROOT/src/freesurfer/bin/recon-all" ]; then
        : # nothing installed to patch (install itself must have failed above)
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would check for and apply official FreeSurfer 8.2.0 patches (fs820_updates.sh)"
    else
        log "Checking for official FreeSurfer 8.2.0 patches"
        local real_fs_home upd_script="$SOFTWARE_ROOT/tmp/fs820_updates.sh"
        real_fs_home="$(readlink -f "$SOFTWARE_ROOT/src/freesurfer")"
        if curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
                -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                -o "$upd_script" \
                "https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/8.2.0/fs820_updates.sh"; then
            # fs820_updates.sh does its own OS-detection via a hardcoded `grep
            # PRETTY_NAME /etc/os-release`, matched against literal strings
            # ("Ubuntu 22", "Ubuntu 24", CentOS/Rocky/Darwin) -- it has no
            # concept of Debian/Ubuntu derivatives, so on Linux Mint (whose
            # PRETTY_NAME says "Linux Mint 21.1") it hits its catch-all
            # "unrecognized" branch and exits 1 before ever checking for or
            # applying a single patch, even though the real base (confirmed
            # via the same /etc/upstream-release/lsb-release ubuntu_release()
            # already reads for every other apt/download decision in this
            # script) is an Ubuntu release it explicitly supports. This is
            # FreeSurfer's own third-party script, not ours to fix upstream --
            # so the local copy just downloaded gets a one-line patch feeding
            # it "Ubuntu <real upstream release>" instead of the raw Mint
            # PRETTY_NAME. Every actual patch-selection/checksum-verification
            # line is untouched; a native (non-derivative) Ubuntu is unaffected
            # since /etc/upstream-release/lsb-release won't exist there.
            if [ -f /etc/upstream-release/lsb-release ]; then
                python3 - "$upd_script" "$(ubuntu_release)" <<'PYEOF'
import sys
from pathlib import Path
p = Path(sys.argv[1])
release = sys.argv[2]
s = p.read_text()
old = 'host_cmd="grep PRETTY_NAME /etc/os-release"'
new = 'host_cmd="echo PRETTY_NAME=\\"Ubuntu {}\\""'.format(release)
if old in s:
    p.write_text(s.replace(old, new))
    print("    patched fs820_updates.sh OS-identification (Linux Mint -> Ubuntu {})".format(release))
else:
    print("    fs820_updates.sh OS-identification line has changed upstream -- patch skipped, \
falling back to its own (likely 'unrecognized OS') behavior")
PYEOF
            fi
            # The script prompts per-file via 'read -n 1' ("Update <file>?
            # [Yy/Nn]"). Confirmed bug: plain 'yes |' actually answers only
            # every OTHER prompt correctly -- each 'y\n' pair satisfies one
            # read with 'y', but the leftover '\n' then gets consumed as the
            # single character for the NEXT prompt (which doesn't match
            # [Yy], so it's silently skipped). A no-newline 'y' stream
            # doesn't have this desync since there's nothing to leave over.
            # Confirmed bug: under pipefail, 'yes' getting SIGPIPE'd once the
            # script finishes reading (normal/expected) makes the WHOLE
            # pipeline register as failed even though the script itself
            # succeeded -- killing the rest of this run via set -e. Disable
            # pipefail just for this subshell and capture the real exit code
            # via $? instead of relying on the pipeline's own status.
            local patch_status=0
            ( cd "$SOFTWARE_ROOT/tmp" && set +o pipefail \
              && yes | tr -d '\n' | sudo FREESURFER_HOME="$real_fs_home" bash "$upd_script" ) || patch_status=$?
            [ "$patch_status" -ne 0 ] && warn "Patch script exited with status $patch_status (patches already applied, if any, are still valid -- checksummed before use)"
            ok "FreeSurfer patch check complete"
        else
            warn "Couldn't download fs820_updates.sh — skipping the patch check (not fatal, just means \
you're on plain 8.2.0 without its post-release fixes)"
        fi
    fi
}

# ── 9b. Lead-DBS atlas/template data (not the full MATLAB toolbox) ──────────
# KUL_tracts_ocd.sh only needs Lead-DBS's bundled atlas/template data (CIT168,
# ABGT, etc. under templates/space/...), not the Lead-DBS MATLAB application
# itself. Confirmed live: Lead-DBS's own release data bundle is a direct,
# no-login zip download (redirects to a filedn.com-hosted file) -- this pulls
# just the templates/ subtree out of it, not the multi-GB full toolbox.

section_leaddbs_atlases() {
    if [ -d "$SOFTWARE_ROOT/src/leaddbs/templates" ]; then
        ok "Lead-DBS atlas/template data already present at $SOFTWARE_ROOT/src/leaddbs/templates"
        return
    fi
    log "Downloading Lead-DBS's atlas/template data (KUL_tracts_ocd.sh's CIT168/ABGT atlases live here)"
    local url="http://www.lead-dbs.org/release/download.php?id=data_pcloud"
    local tmpdir="$SOFTWARE_ROOT/tmp/leaddbs_extract"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would download $url and extract its templates/ subtree to $SOFTWARE_ROOT/src/leaddbs/templates"
        return
    fi
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$tmpdir/leaddbs_data.zip" "$url"
    unzip -q "$tmpdir/leaddbs_data.zip" -d "$tmpdir/extracted"
    local templates_dir
    templates_dir="$(find "$tmpdir/extracted" -maxdepth 4 -type d -name templates | head -1)" || true
    if [ -z "$templates_dir" ]; then
        fail "Couldn't find a 'templates' directory inside the downloaded Lead-DBS data zip -- its \
internal layout may have changed. Extract $tmpdir/leaddbs_data.zip by hand and move the templates \
directory to $SOFTWARE_ROOT/src/leaddbs/templates yourself."
    else
        mkdir -p "$SOFTWARE_ROOT/src/leaddbs"
        mv "$templates_dir" "$SOFTWARE_ROOT/src/leaddbs/templates"
        rm -rf "$tmpdir"
        ok "Lead-DBS atlas/template data ready at $SOFTWARE_ROOT/src/leaddbs/templates"
    fi
}

# ── 9c. ITK-SNAP (segmentation/viewer) ────────────────────────────────────────
# Not referenced by any KUL_NIS script -- requested directly. No apt package
# exists for it on Ubuntu 24.04 (checked: universe/multiverse are both enabled,
# it's just not packaged there), so this pulls the official self-contained
# Linux binary release from SourceForge instead (bundles its own Qt/VTK/ITK,
# no separate system dependencies needed, unlike FreeSurfer's .deb).

ITKSNAP_VERSION="4.2.0-20240422" # check https://sourceforge.net/projects/itk-snap/files/itk-snap/ for newer

section_spm12() {
    # SPM12 is plain MATLAB source -- no compilation, no license of its own. It is
    # MATLAB that is commercial, and MATLAB is NOT installed here; this section only
    # lays SPM down where the pipeline expects it and exports the variable that
    # points at it. A site without MATLAB gets the files and an explanatory note.
    #
    # Layout: $SOFTWARE_ROOT/src/matlab_apps/{spm12,...}. The extra directory level
    # exists so MATLAB toolboxes (conn next, most likely) share one root that
    # $KUL_MATLAB_APPS can name, rather than each needing its own variable.
    local apps="$SOFTWARE_ROOT/src/matlab_apps"
    local dest="$apps/spm12"
    if [ -f "$dest/spm.m" ]; then
        ok "SPM12 already installed at $dest"
        return
    fi
    log "Downloading and extracting SPM12"
    local url="https://www.fil.ion.ucl.ac.uk/spm/download/restricted/eldorado/spm12.zip"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would download $url and extract it to $dest"
        return
    fi
    mkdir -p "$apps"
    local tmpfile="$SOFTWARE_ROOT/tmp/spm12.zip"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$tmpfile" "$url"
    unzip -q -o "$tmpfile" -d "$apps"      # the zip already contains a top-level spm12/
    rm -f "$tmpfile"
    if [ ! -f "$dest/spm.m" ]; then
        warn "SPM12 unpacked but $dest/spm.m is missing -- the archive layout may have \
changed. KUL_fmriproc_spm_new.sh will fail until this is sorted."
        return
    fi
    record_version spm12 "12 (FIL release, see $dest/Contents.m)"
    if have matlab; then
        ok "SPM12 installed to $dest (matlab found at $(command -v matlab))"
    else
        ok "SPM12 installed to $dest"
        warn "matlab not on PATH -- KUL_fmriproc_spm_new.sh needs it (it runs 'matlab \
-nodisplay -r ...'). SPM itself is in place; install/licence MATLAB separately, or use \
the nilearn GLM engine instead (KUL_clinical_fmridti.sh -E nilearn)."
    fi
}

section_itksnap() {
    local dest="$SOFTWARE_ROOT/src/itksnap"
    local marker="$SOFTWARE_ROOT/.installed_versions/itksnap"
    if [ -x "$dest/bin/itksnap" ]; then
        if [ -f "$marker" ]; then
            local installed_ver
            installed_ver="$(cat "$marker")"
            if [ "$installed_ver" = "$ITKSNAP_VERSION" ]; then
                ok "ITK-SNAP already installed at the pinned version ($installed_ver)"
                return
            fi
            version_gate "ITK-SNAP" "$installed_ver" "$ITKSNAP_VERSION" && return
        else
            ok "ITK-SNAP already installed at $dest (no version marker to check against the pinned $ITKSNAP_VERSION -- assuming OK)"
            return
        fi
    fi
    log "Downloading and extracting ITK-SNAP $ITKSNAP_VERSION"
    local url="https://sourceforge.net/projects/itk-snap/files/itk-snap/${ITKSNAP_VERSION%%-*}/itksnap-${ITKSNAP_VERSION}-Linux-gcc64.tar.gz/download"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would download $url and extract it to $dest"
        return
    fi
    rm -rf "$dest"
    mkdir -p "$dest"
    local tmpfile="$SOFTWARE_ROOT/tmp/itksnap.tar.gz"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$tmpfile" "$url"
    tar xzf "$tmpfile" -C "$dest" --strip-components=1
    rm -f "$tmpfile"
    record_version itksnap "$ITKSNAP_VERSION"
    ok "ITK-SNAP installed to $dest (added to PATH via the bashrc/profile.d block)"
}

# ── 9c2. PsychoPy Studio ───────────────────────────────────────────────────────
# Not a KUL_NIS dependency -- requested directly. PsychoPy's own docs call the
# traditional pip+wxPython route on Linux "often rather painful" (needs Python
# 3.8-3.10 specifically, plus a hand-matched wxPython wheel per distro/GTK
# version) and now recommend "PsychoPy Studio" instead -- a self-contained
# Electron/AppImage build with none of that. Pinned to 2026.2.0 specifically
# (not latest): checked 2026.1.3 first and found a confirmed bug running
# version-pinned older .psyexp files, fixed in 2026.2.0.
# AppImages need libfuse2 to run -- Ubuntu renamed this package per release
# (libfuse2t64 on 24.04, libfuse2 on 22.04), so branch on ubuntu_release()
# rather than hardcoding one name in the general apt list. PSYCHOPY_VERSION
# itself is set near the top of the script (--psychopy-version / wizard prompt).

section_psychopy() {
    local dest="$SOFTWARE_ROOT/src/psychopy"
    local marker="$SOFTWARE_ROOT/.installed_versions/psychopy"
    if [ -x "$dest/psychopy" ]; then
        if [ -f "$marker" ]; then
            local installed_ver
            installed_ver="$(cat "$marker")"
            if [ "$installed_ver" = "$PSYCHOPY_VERSION" ]; then
                ok "PsychoPy Studio already installed at the pinned version ($installed_ver)"
                return
            fi
            version_gate "PsychoPy Studio" "$installed_ver" "$PSYCHOPY_VERSION" && return
        else
            ok "PsychoPy Studio already installed at $dest (no version marker to check against the pinned $PSYCHOPY_VERSION -- assuming OK)"
            return
        fi
    fi
    log "Installing libfuse2 (needed to run AppImages) and downloading PsychoPy Studio $PSYCHOPY_VERSION"
    local url="https://github.com/psychopy/psychopy/releases/download/$PSYCHOPY_VERSION/PsychoPy_Studio_${PSYCHOPY_VERSION}.AppImage"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would apt-get install libfuse2(t64) and download $url to $dest/psychopy"
        return
    fi
    case "$(ubuntu_release)" in
        24.*) sudo apt-get install -y libfuse2t64 ;;
        *)    sudo apt-get install -y libfuse2 ;;
    esac
    mkdir -p "$dest"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$dest/psychopy" "$url"
    chmod +x "$dest/psychopy"
    record_version psychopy "$PSYCHOPY_VERSION"
    ok "PsychoPy Studio installed to $dest (added to PATH via the bashrc/profile.d block; run as 'psychopy')"
}

# ── 9d. datalad (dataset version control) ─────────────────────────────────────
# Not referenced by any KUL_NIS script -- requested directly. Needs git-annex
# as a real system dependency (apt), then datalad itself goes into the
# miniforge base env via pip, same convention as dcm2niix/dcm2bids.

section_datalad() {
    if have datalad; then
        ok "datalad already installed ($(datalad --version 2>/dev/null | head -1))"
        return
    fi
    log "Installing git-annex (apt) + datalad (pip, into miniforge base)"
    run "sudo apt-get install -y git-annex"
    run "'$SOFTWARE_ROOT/miniforge3/bin/pip' install datalad"
    ok "datalad ready"
}

# ── 9h. AWS CLI v2 ─────────────────────────────────────────────────────────────
# Not a KUL_NIS dependency -- requested directly, for pulling data from S3-hosted
# datasets. AWS deprecated v1 (the pip-installed 'awscli' package) in favor of
# v2, their own self-contained installer -- real system install (standard
# /usr/local/aws-cli + /usr/local/bin/aws symlink), same category as Docker/
# VS Code/R, not under $SOFTWARE_ROOT.

section_awscli() {
    if have aws && aws --version 2>&1 | grep -q "aws-cli/2\."; then
        ok "AWS CLI v2 already installed ($(aws --version 2>&1))"
        return
    fi
    if have aws; then
        warn "Found a non-v2 aws CLI ($(aws --version 2>&1)) -- likely the deprecated pip-installed \
v1. Installing v2 via AWS's own installer alongside it; since v1 is commonly on PATH ahead of \
v2's /usr/local/bin (e.g. via ~/.local/bin), you may need to uninstall it (pip uninstall awscli) \
or reorder PATH for 'aws' to actually resolve to v2 afterward."
    fi
    log "Installing AWS CLI v2 (official installer)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would download the AWS CLI v2 installer and run sudo ./aws/install --update"
        return
    fi
    local tmpdir="$SOFTWARE_ROOT/tmp/awscli"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -o "$tmpdir/awscliv2.zip" \
        "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
    sudo "$tmpdir/aws/install" --update
    rm -rf "$tmpdir"
    ok "AWS CLI v2 installed ($(aws --version 2>&1))"
}

# ── 9e. R (via CRAN's own apt repo, newer than Ubuntu's bundled r-base) ──────
# Not a KUL_NIS dependency -- requested directly. Ubuntu 24.04's own r-base is
# 4.3.3; CRAN's own repo tracks the current release instead (their "cran40"
# repo name is a legacy artifact -- it actually resolves to the latest R).
# Real system install (standard apt package, not under $SOFTWARE_ROOT), same
# category as Docker/VS Code.

section_r() {
    if have R; then
        ok "R already installed ($(R --version 2>/dev/null | head -1))"
        return
    fi
    log "Installing R via CRAN's own apt repo"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would add CRAN's apt repo and install r-base"
        return
    fi
    sudo apt-get install -y --no-install-recommends software-properties-common dirmngr
    wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc | sudo tee /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc >/dev/null
    sudo add-apt-repository -y "deb https://cloud.r-project.org/bin/linux/ubuntu $(ubuntu_codename)-cran40/"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends r-base
    ok "R installed"
}

# ── 9f. RStudio Desktop ────────────────────────────────────────────────────────
# Not a KUL_NIS dependency -- requested directly. Direct .deb from Posit (their
# "jammy" build, documented as compatible with both Ubuntu 22.04 and 24.04 --
# no separate 24.04 build exists). Real dpkg/apt install like FreeSurfer/RStudio's
# own Electron+Qt dependencies aren't bundled in the .deb -- same reasoning as
# the FreeSurfer fix: a payload-only extraction would skip them.

RSTUDIO_VERSION="2026.07.1-147"

section_rstudio() {
    local marker="$SOFTWARE_ROOT/.installed_versions/rstudio"
    if have rstudio; then
        if [ -f "$marker" ]; then
            local installed_ver
            installed_ver="$(cat "$marker")"
            if [ "$installed_ver" = "$RSTUDIO_VERSION" ]; then
                ok "RStudio already installed at the pinned version ($installed_ver)"
                return
            fi
            version_gate "RStudio" "$installed_ver" "$RSTUDIO_VERSION" && return
        else
            ok "RStudio already installed (no version marker to check against the pinned $RSTUDIO_VERSION -- assuming OK; likely installed before this script tracked versions, or by another means)"
            return
        fi
    fi
    if ! have R; then
        warn "RStudio works best with R already installed -- run the r section first if it's not already done"
    fi
    log "Downloading and installing RStudio Desktop $RSTUDIO_VERSION"
    local url="https://download1.rstudio.org/electron/jammy/amd64/rstudio-${RSTUDIO_VERSION}-amd64.deb"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would download $url and install it via dpkg/apt"
        return
    fi
    local tmpfile="$SOFTWARE_ROOT/tmp/rstudio.deb"
    curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - -o "$tmpfile" "$url"
    sudo dpkg -i "$tmpfile" || true
    sudo apt-get install -f -y
    rm -f "$tmpfile"
    record_version rstudio "$RSTUDIO_VERSION"
    ok "RStudio installed"
}

# ── 9g. AFNI ───────────────────────────────────────────────────────────────────
# Not a KUL_NIS dependency -- requested directly. Official install method is
# AFNI's own @update.afni.binaries tcsh script (self-updating, not a plain
# tarball or apt package). Apt prerequisite list is AFNI's own documented one
# for Ubuntu 24.04, trimmed of purely-desktop-convenience GUI apps (firefox,
# gedit, nautilus, evince, eog, gnome-terminal, gnome-tweaks) their docs bundle
# in for people turning a bare server into a full desktop -- not applicable
# here, and not actual AFNI dependencies.

section_afni() {
    local dest="$SOFTWARE_ROOT/src/afni"
    if [ -x "$dest/afni" ]; then
        ok "AFNI already installed at $dest"
        return
    fi
    local rel afni_pkg
    rel="$(ubuntu_release)"
    case "$rel" in
        24.*) afni_pkg="linux_ubuntu_24_64" ;;
        *)
            # AFNI dropped linux_ubuntu_22_64 from their distribution server
            # at some point after this section was written -- confirmed live
            # (curl https://afni.nimh.nih.gov/pub/dist/bin/ 404s a test file
            # for it, and no longer lists it in the directory index at all;
            # only linux_ubuntu_16_64 and linux_ubuntu_24_64 remain for
            # Ubuntu). Route everything that isn't 24.x here, not just
            # genuinely unknown releases -- AFNI's own package list, not this
            # script's guess at Ubuntu compatibility, is the actual source of
            # truth, and it changes on their schedule, not this script's.
            warn "AFNI has no package specifically for Ubuntu $rel (checked \
https://afni.nimh.nih.gov/pub/dist/bin/ live -- only linux_ubuntu_16_64 and linux_ubuntu_24_64 \
exist for Ubuntu right now) -- falling back to the 24.04 build. Check \
https://afni.nimh.nih.gov/pub/dist/doc/htmldoc/background_install/install_instructs/index.html \
if it doesn't run cleanly."
            afni_pkg="linux_ubuntu_24_64"
            ;;
    esac
    log "Installing AFNI prerequisites (apt) and running its official @update.afni.binaries installer"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] would apt-get install AFNI's prerequisite libraries, then run \
@update.afni.binaries -package $afni_pkg -bindir $dest"
        return
    fi
    sudo apt-get install -y tcsh xfonts-base libssl-dev python-is-python3 \
        python3-matplotlib python3-numpy python3-flask python3-flask-cors \
        python3-pil gsl-bin netpbm libjpeg62 xvfb xterm libglu1-mesa-dev \
        libglw1-mesa-dev libxm4 build-essential libcurl4-openssl-dev \
        libxml2-dev libgomp1 xfonts-100dpi r-base-dev cmake bc git \
        libgdal-dev libopenblas-dev libnode-dev libudunits2-dev
    mkdir -p "$dest"
    ( cd "$SOFTWARE_ROOT/tmp" \
      && curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -O https://afni.nimh.nih.gov/pub/dist/bin/misc/@update.afni.binaries \
      && tcsh @update.afni.binaries -package "$afni_pkg" -bindir "$dest" -do_extras )
    # AFNI has no stable semantic version (@update.afni.binaries always pulls
    # whatever's current at install time) -- record what we actually know:
    # the package identifier and install date.
    record_version afni "$afni_pkg, installed $(date +%Y-%m-%d)"
    ok "AFNI installed to $dest (added to PATH via the bashrc/profile.d block)"
}

# ── 10. Docker images used by the pipeline ────────────────────────────────────

section_docker_images() {
    if ! have docker; then
        warn "docker not found — skipping image pulls (run the docker section first)"
        return
    fi
    log "Pulling Docker images used by the clinical pipeline"
    run "docker pull nipreps/fmriprep:$FMRIPREP_VERSION"
    run "docker pull poldracklab/mriqc:latest"
    run "docker pull leonyichencai/synb0-disco:v3.0"
    run "docker pull sebastientourbier/multiscalebrainparcellator:v1.1.1"
    # Confirmed via HD-GLIO-AUTO's own README (github.com/NeuroAI-HD/HD-GLIO-AUTO) and verified
    # live on Docker Hub: 'jenspetersen/hd-glio-auto' (note the spelling -- not 'jenspeter') is
    # the real, current, actively-published image. On by default like the other images now --
    # 'INCLUDE_HDGLIOAUTO=0 ./setup_environment.sh' skips just this one if you don't want it.
    # GPU-heavy at *run* time (needs nvidia-docker/the Container Toolkit from the nvidia section),
    # but pulling the image itself needs no GPU.
    if [ "$INCLUDE_HDGLIOAUTO" -eq 1 ]; then
        run "docker pull jenspetersen/hd-glio-auto"
    fi
    ok "Docker images pulled. FreeSurfer license.txt must be bind-mounted at \
/opt/freesurfer/license.txt (fmriprep) or /usr/local/freesurfer/license.txt (MSBP) at run time — \
see each script's existing 'docker run' invocation for the exact mount."
}

# ── 11. Environment block — ~/.bashrc (user mode) or /etc/profile.d (shared) ──

section_bashrc() {
    local marker="$KUL_BLOCK_MARKER"
    local marker_end="$KUL_BLOCK_MARKER_END"
    local src="$SOFTWARE_ROOT/src"
    # First shared destination is the canonical one (it holds the body); any
    # other shared destination gets a source shim pointing at it. Derived from
    # the array rather than hardcoded so the two cannot drift apart.
    local canonical="${KUL_BLOCK_SHARED_DESTS[0]}"

    # Confirmed bug (found live): /etc/profile.d/*.sh is only sourced by LOGIN
    # shells (SSH/console logins, 'bash -l') -- it is NOT sourced by the plain
    # interactive non-login shells that desktop terminal emulators actually
    # spawn (verified: 'bash -i' never saw it, only 'bash -l' did). Debian/
    # Ubuntu's bash package, however, DOES auto-source /etc/bash.bashrc for
    # every interactive shell regardless of login status -- that's the file
    # that actually covers "just open a terminal."
    #
    # Confirmed bug (found live, second order): the fix for that used to be
    # writing the same block to BOTH files, on the assumption that they cover
    # disjoint sets of shells. They do not. Debian/Ubuntu's /etc/profile
    # sources /etc/bash.bashrc itself when $PS1 is set, so an interactive login
    # shell reaches the body twice -- FreeSurfer's banner printed twice and
    # PATH picked up two copies of everything before ~/.bashrc was even read.
    # Shared mode now keeps exactly one copy of the body, in /etc/profile.d,
    # and puts a one-line source shim in /etc/bash.bashrc; the body is written
    # to be re-entrant so the remaining overlap is a no-op.
    local block_content
    block_content=$(cat <<EOF

$marker
export SOFTWARE_ROOT="$SOFTWARE_ROOT"
export CACHE_ROOT="$CACHE_ROOT"

# Confirmed bug (found live): every entry below used to be added with a plain
# 'export PATH="new:\$PATH"'. Because this block runs again in each nested
# shell -- and twice over in an interactive login shell, see the note in
# section_bashrc -- PATH grew without bound; a working session was routinely
# carrying seven copies of the FreeSurfer directories. Add entries through
# this instead: same order, but a no-op if the entry is already present.
kul_path_prepend() {
    case ":\${PATH}:" in
        *":\$1:"*) ;;
        *) PATH="\$1:\${PATH}" ;;
    esac
}

# The vendor setup scripts sourced further down (FSL's fsl.sh, FreeSurfer's
# FreeSurferEnv.sh, conda's activate-base hook) each extend PATH themselves and
# none of them check what is already there -- FreeSurferEnv.sh appends FSL_BIN
# at its line 469, which fsl.sh has usually just prepended, so a single clean
# pass still ended up with two copies of \$FSLDIR/share/fsl/bin. Sweeping once
# at the end, keeping the first occurrence, is simpler and more robust than
# trying to out-guess all three. It also drops empty entries, which the shell
# reads as "the current directory".
kul_path_dedupe() {
    local out="" e
    local IFS=:
    for e in \$PATH; do
        [ -z "\$e" ] && continue
        case ":\$out:" in
            *":\$e:"*) ;;
            *) out="\${out:+\$out:}\$e" ;;
        esac
    done
    PATH="\$out"
}

# --- Conda / miniforge ---
kul_path_prepend "\$SOFTWARE_ROOT/miniforge3/bin"
# KUL_ENV_SOURCED is deliberately NOT exported. It suppresses a second pass
# within the SAME shell (the /etc/profile -> /etc/bash.bashrc overlap), while
# still letting every new nested shell run the hooks -- which it must, since
# 'conda' and 'mamba' are shell functions and a child shell does not inherit
# them. Everything else in this block is idempotent by construction, so only
# the two expensive hook evals need the guard.
if [ -z "\${KUL_ENV_SOURCED:-}" ]; then
    # Confirmed bug (found live): plain 'source .../etc/profile.d/conda.sh' only
    # wires up the 'conda' function -- it does NOT auto-activate base the way a
    # standard 'conda init' setup does, because that auto-activation is baked
    # into the dynamically-generated output of 'conda shell.bash hook' itself
    # (ends in a literal "conda activate 'base'"), not into conda.sh. Using the
    # hook instead gives both the function AND the expected auto-activated base.
    eval "\$("\$SOFTWARE_ROOT/miniforge3/bin/conda" shell.bash hook)"
    # mamba has its own separate shell hook (completions + the 'mamba'/'micromamba'
    # functions; it does NOT duplicate conda's own activate-base call, so running
    # both is safe) -- without this, 'mamba activate' fails with "mamba is running
    # as a subprocess and can't modify the parent shell." Together these mean
    # either 'conda activate <env>' or 'mamba activate <env>' works interchangeably
    # (mamba is faster for create/install; activation itself is the same mechanism).
    if command -v mamba >/dev/null 2>&1; then
        eval "\$(mamba shell hook --shell bash)"
    fi
    KUL_ENV_SOURCED=1
fi
export CONDA_PKGS_DIRS="\$CACHE_ROOT/conda_pkgs"

# --- Caches / tmp ---
export XDG_CACHE_HOME="\$CACHE_ROOT/xdg"
export PIP_CACHE_DIR="\$CACHE_ROOT/pip"
export TMPDIR="\$SOFTWARE_ROOT/tmp"
export APPTAINER_TMPDIR="\$SOFTWARE_ROOT/tmp/apptainer"

# --- FSL ---
export FSLDIR="\$SOFTWARE_ROOT/src/FSL"
# fsl.sh and SetUpFreeSurfer.sh only export variables and extend PATH, and
# FreeSurfer's prints a banner on the way through -- re-sourcing them in every
# nested shell is what put the FreeSurfer header on screen more than once per
# terminal. Everything they set is exported, so once per shell tree is enough;
# these two flags ARE exported, unlike KUL_ENV_SOURCED above.
if [ -z "\${KUL_FSL_SOURCED:-}" ] && [ -f "\$FSLDIR/etc/fslconf/fsl.sh" ]; then
    . "\$FSLDIR/etc/fslconf/fsl.sh"
    export KUL_FSL_SOURCED=1
fi
kul_path_prepend "\$FSLDIR/share/fsl/bin"

# --- FreeSurfer ---
export FREESURFER_HOME="\$SOFTWARE_ROOT/src/freesurfer"
if [ -z "\${KUL_FS_SOURCED:-}" ] && [ -f "\$FREESURFER_HOME/SetUpFreeSurfer.sh" ]; then
    . "\$FREESURFER_HOME/SetUpFreeSurfer.sh"
    export KUL_FS_SOURCED=1
fi
export SUBJECTS_DIR="\$FREESURFER_HOME/subjects"
export FS_LICENSE="\$FREESURFER_HOME/license.txt"

# --- FastSurfer ---
export FASTSURFER_HOME="\$SOFTWARE_ROOT/src/FastSurfer"

# --- ANTs ---
export ANTSPATH="\$SOFTWARE_ROOT/src/ANTs_install/bin"
kul_path_prepend "\$ANTSPATH"

# --- MATLAB toolboxes (SPM12 now, conn etc. later) ---
# Deliberately NOT on PATH: nothing here is an executable. These are MATLAB
# sources that the .m templates in KUL_NIS/share/spm12/ addpath() at runtime,
# after resolving this variable with getenv(). MATLAB itself must be on PATH
# (KUL_fmriproc_spm_new.sh does 'which matlab'), but that is a separate,
# site-managed install.
# KUL_apps_DIR is the legacy name the templates originally used, from the old
# /usr/local/KUL_apps layout; exported alongside so an older checkout of the
# templates keeps working against this install.
export KUL_MATLAB_APPS="\$SOFTWARE_ROOT/src/matlab_apps"
export KUL_apps_DIR="\$KUL_MATLAB_APPS"

# --- CUDA Toolkit (only if installed -- see the nvidia section) ---
if [ -d /usr/local/cuda ]; then
    export CUDA_HOME=/usr/local/cuda
    kul_path_prepend /usr/local/cuda/bin
    # Confirmed bug (found live): this was
    # LD_LIBRARY_PATH="/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}". On the
    # common case of LD_LIBRARY_PATH being unset that expands to a TRAILING
    # COLON, which the dynamic loader reads as "also search the current
    # directory" -- so any cwd containing a stray libfoo.so silently shadowed
    # the system one. \${VAR:+:\$VAR} appends the separator only when
    # there is something to separate.
    case ":\${LD_LIBRARY_PATH:-}:" in
        *":/usr/local/cuda/lib64:"*) ;;
        *) export LD_LIBRARY_PATH="/usr/local/cuda/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" ;;
    esac
fi

# --- mrtrix3 ---
kul_path_prepend "\$SOFTWARE_ROOT/src/mrtrix3/bin"
# Same trailing-colon bug as LD_LIBRARY_PATH above, and worse: an empty entry
# in PYTHONPATH puts the current working directory on sys.path for every
# Python process on the box.
case ":\${PYTHONPATH:-}:" in
    *":\$SOFTWARE_ROOT/src/mrtrix3/lib:"*) ;;
    *) export PYTHONPATH="\$SOFTWARE_ROOT/src/mrtrix3/lib\${PYTHONPATH:+:\$PYTHONPATH}" ;;
esac

# --- shard-recon (external mrtrix3 module, dwimotioncorrect/mssh2amp) ---
kul_path_prepend "\$SOFTWARE_ROOT/src/shard-recon/bin"

# --- ITK-SNAP ---
kul_path_prepend "\$SOFTWARE_ROOT/src/itksnap/bin"

# --- PsychoPy Studio ---
kul_path_prepend "\$SOFTWARE_ROOT/src/psychopy"

# --- AFNI ---
kul_path_prepend "\$SOFTWARE_ROOT/src/afni"

# --- KUL_NIS / KUL_VBG / KUL_FWT / KUL_DTI_ALPS on PATH ---
# Prepended in reverse so the resulting order matches the list as written.
kul_path_prepend "$src/KUL_NIS/KUL_DTI_ALPS"
kul_path_prepend "$src/KUL_FWT"
kul_path_prepend "$src/KUL_VBG"
kul_path_prepend "$src/KUL_NIS"

kul_path_dedupe
export PATH
$marker_end
EOF
)

    local shim_content
    shim_content=$(cat <<EOF

$marker
# The body of this block lives in $canonical and is
# deliberately NOT duplicated here. /etc/profile.d/*.sh is read only by LOGIN
# shells, while desktop terminal emulators spawn interactive NON-login shells
# that Ubuntu's bash serves from this file instead -- so both entry points are
# needed, but only one copy of the content. Note that /etc/profile also
# sources this file when \$PS1 is set, so an interactive login shell reaches
# the body twice; kul_path_prepend and the KUL_*_SOURCED guards inside it make
# that second pass a no-op.
[ -f $canonical ] && . $canonical
$marker_end
EOF
)

    # --fresh-bashrc: back up ~/.bashrc and rebuild it from the distro's own
    # stock skeleton before the normal append logic below runs. This is
    # deliberately narrow, not an attempt at understanding what's "worth
    # keeping" in an arbitrary ~/.bashrc -- it can't know that (that took an
    # actual read of the specific file it was tested against, not something
    # a generic script can infer). What it CAN do generically: give a clean
    # slate based on /etc/skel/.bashrc (the same baseline every fresh account
    # gets, which covers the prompt/aliases/history/completion setup most
    # unmodified ~/.bashrc files still have) plus this script's own managed
    # block, instead of appending onto a ~/.bashrc that might already source
    # a completely different, unrelated environment -- confirmed live, during
    # this project's own migration, that appending onto such a file leaves
    # BOTH active at once and causes real bugs (PATH-shadowed compilers/
    # linkers, wrong tool versions silently winning). The backup is there so
    # nothing from the old file is actually lost, just not auto-merged.
    if [ "$FRESH_BASHRC" -eq 1 ]; then
        if [ "$INSTALL_MODE" = "shared" ]; then
            warn "--fresh-bashrc only applies in user mode (rewriting /etc/bash.bashrc would affect \
every account on this box, not just yours) -- ignoring it, appending to the existing files as usual."
        elif [ "$DRY_RUN" -eq 1 ]; then
            echo "    [dry-run] would back up $HOME/.bashrc and rebuild it from /etc/skel/.bashrc \
(or leave the current file as-is if no skeleton exists) plus the managed block below"
        else
            local bashrc_backup="$HOME/.bashrc.pre_kul_setup_$(date +%Y%m%d_%H%M%S)"
            if [ -f "$HOME/.bashrc" ]; then
                cp "$HOME/.bashrc" "$bashrc_backup"
                ok "Backed up your existing \$HOME/.bashrc to $bashrc_backup"
            fi
            if [ -f /etc/skel/.bashrc ]; then
                cp /etc/skel/.bashrc "$HOME/.bashrc"
                ok "Rebuilt \$HOME/.bashrc from the stock /etc/skel/.bashrc skeleton -- review \
$bashrc_backup for anything you added beyond the stock prompt/aliases/completion setup (custom \
exports, extra aliases, another shell config sourced from it, etc.) and add it back in by hand; \
this script only adds its own managed block below."
            else
                warn "No /etc/skel/.bashrc on this system to rebuild from -- leaving your current \
\$HOME/.bashrc as the base and just appending the managed block below, same as without \
--fresh-bashrc (your backup at $bashrc_backup is there either way)."
            fi
        fi
    fi

    local dests=()
    if [ "$INSTALL_MODE" = "shared" ]; then
        dests=("${KUL_BLOCK_SHARED_DESTS[@]}")
    else
        dests=("${KUL_BLOCK_USER_DESTS[@]}")
    fi

    # Confirmed bug (found live): the old guard was "if the file I am about to
    # write already has the marker, skip it". That could neither notice copies
    # left behind in the OTHER mode's locations (so a user-mode re-run after a
    # shared install left three live copies), nor refresh a stale one -- "not
    # touching it" froze /etc at whatever script version first ran, while later
    # runs appended a NEWER block elsewhere. On this box that silently split
    # the environment: KUL_MATLAB_APPS and shard-recon existed only in the
    # ~/.bashrc copy, so they were missing from every SSH login. Now: prune
    # every location that is not a destination for this mode, and replace
    # rather than skip in the ones that are.
    local f content
    for f in "${KUL_BLOCK_ALL_DESTS[@]}"; do
        kul_in_list "$f" "${dests[@]}" && continue
        kul_block_present_in "$f" || continue
        warn "Removing stale managed block from $f (this install is '$INSTALL_MODE' mode)"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    [dry-run] would remove the managed block from $f"
            continue
        fi
        kul_block_strip "$f"
        ok "$f cleaned (backup alongside as $(basename "$f").kulbak.*)"
    done

    for f in "${dests[@]}"; do
        content="$block_content"
        if [ "$INSTALL_MODE" = "shared" ] && [ "$f" != "$canonical" ]; then
            content="$shim_content"
        fi
        if kul_block_present_in "$f"; then
            log "Refreshing managed environment block in $f"
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    [dry-run] would replace the managed block in $f"
                continue
            fi
            kul_block_strip "$f"
        else
            log "Appending environment block to $f"
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "    [dry-run] would append the managed block to $f"
                continue
            fi
        fi
        kul_block_append "$f" "$content"
        ok "$f updated"
    done

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ "$INSTALL_MODE" = "shared" ]; then
            ok "Body in $canonical, one-line source shim in the rest. New terminals \
and real logins both pick this up from their next start; 'source $canonical' for the current one."
        else
            ok "Run 'source ~/.bashrc' or open a new shell to pick it up."
        fi
        ok "Blocks now on disk: $(kul_block_locations | tr '\n' ' ')"
    fi
}

# ── 12. Verify — read-only health check + summary table ──────────────────────
# Doesn't install or modify anything. Safe to run any time, including on its
# own (--only verify) to sanity-check a machine you didn't set up with this
# script, or to see what's left after a partial/interrupted run.

VERIFY_OK=0
VERIFY_WARN=0
VERIFY_FAIL=0

vprint() { printf "  [%-4s] %-24s %s\n" "$1" "$2" "$3"; }
vok()    { vprint "OK"   "$1" "$2"; VERIFY_OK=$((VERIFY_OK + 1)); }
vwarn()  { vprint "WARN" "$1" "$2"; VERIFY_WARN=$((VERIFY_WARN + 1)); }
vfail()  { vprint "FAIL" "$1" "$2"; VERIFY_FAIL=$((VERIFY_FAIL + 1)); }

section_verify() {
    log "Verifying the environment (read-only — nothing here modifies anything)"
    _refresh_env_for_verify
    VERIFY_OK=0; VERIFY_WARN=0; VERIFY_FAIL=0

    echo "  -- core imaging tools (checked on PATH, wherever they actually come from) --"
    if have mrconvert; then
        vok "MRtrix3" "$(mrconvert -version 2>&1 | head -1 | sed -e 's/^== *//' -e 's/ *==$//')"
    else
        vfail "MRtrix3" "mrconvert not found on PATH"
    fi

    if have dwimotioncorrect; then
        vok "shard-recon" "dwimotioncorrect resolves"
    else
        vwarn "shard-recon" "dwimotioncorrect not found on PATH — only needed for shard_recon: 1 in a dwiprep config (off by default everywhere)"
    fi

    if have antsRegistrationSyN.sh; then
        vok "ANTs" "antsRegistrationSyN.sh resolves"
    else
        vfail "ANTs" "antsRegistrationSyN.sh not found on PATH"
    fi

    if have flirt; then
        # 'flirt -version' only reports FLIRT's own major.minor (e.g. "6.0"), not
        # FSL's actual patch version -- real behavioural differences exist between
        # e.g. 6.0.5 and 6.0.6 downstream in this pipeline, so pull the precise
        # version FSL itself records instead.
        # This root's own copy wins if it has one -- same fix as section_fsl's
        # install-time check (confirmed live: an inherited FSLDIR from an
        # unrelated pre-existing shell environment was overriding a build
        # already correctly sitting under $SOFTWARE_ROOT, misreporting its
        # version here too).
        _fsl_dir="$SOFTWARE_ROOT/src/FSL"
        if [ ! -f "$_fsl_dir/etc/fslversion" ]; then
            _fsl_dir="${FSLDIR:-}"
        fi
        if [ ! -f "$_fsl_dir/etc/fslversion" ]; then
            _flirt_bin=$(command -v flirt)
            _fsl_dir="${_flirt_bin%/bin/flirt}"
            _fsl_dir="${_fsl_dir%/share/fsl}"
        fi
        if [ -f "$_fsl_dir/etc/fslversion" ]; then
            vok "FSL" "$(cat "$_fsl_dir/etc/fslversion") (exact, from etc/fslversion)"
        else
            vwarn "FSL" "$(flirt -version 2>&1 | head -1) — exact patch version not found; only major.minor available"
        fi
    else
        vfail "FSL" "flirt not found on PATH"
    fi

    if have recon-all; then
        # Same "this root's own copy wins" fix as FSL above.
        local _fs_lic="$SOFTWARE_ROOT/src/freesurfer/license.txt"
        [ -f "$_fs_lic" ] || _fs_lic="${FS_LICENSE:-${FREESURFER_HOME:-}/license.txt}"
        if [ -f "$_fs_lic" ]; then
            vok "FreeSurfer" "recon-all resolves, license.txt present"
        else
            vwarn "FreeSurfer" "recon-all resolves, but no license.txt found at $_fs_lic"
        fi
    else
        vfail "FreeSurfer" "recon-all not found on PATH (license-gated install — see freesurfer section)"
    fi

    if have dcm2niix && have dcm2bids_scaffold; then
        vok "dcm2niix/dcm2bids" "both resolve on PATH (base env)"
    else
        vfail "dcm2niix/dcm2bids" "not found on PATH — see the env-dcm2bids section"
    fi
    if "$SOFTWARE_ROOT/miniforge3/bin/python" -c "import SimpleITK, PIL, numpy, nibabel, scipy, matplotlib" >/dev/null 2>&1; then
        vok "clinical DICOM pydeps" "SimpleITK/Pillow/numpy/nibabel/scipy/matplotlib importable in base"
    else
        vfail "clinical DICOM pydeps" "missing in base — see the clinical-pydeps section (needed by KUL_nii2dcm.py/-R PACS output)"
    fi

    if have itksnap; then
        vok "ITK-SNAP" "$(read_version itksnap || echo 'resolves on PATH, version unrecorded')"
    else
        vwarn "ITK-SNAP" "not found — see the itksnap section"
    fi
    if have psychopy; then
        vok "PsychoPy Studio" "$(read_version psychopy || echo 'resolves on PATH, version unrecorded')"
    else
        vwarn "PsychoPy Studio" "not found — see the psychopy section"
    fi

    if have datalad; then
        vok "datalad" "$(datalad --version 2>/dev/null | head -1)"
    else
        vwarn "datalad" "not found — see the datalad section"
    fi
    if have aws; then
        vok "AWS CLI" "$(aws --version 2>&1)"
    else
        vwarn "AWS CLI" "not found — see the awscli section"
    fi
    if have R; then
        vok "R" "$(R --version 2>/dev/null | head -1)"
    else
        vwarn "R" "not found — see the r section"
    fi
    if have rstudio; then
        vok "RStudio" "$(read_version rstudio || echo 'resolves on PATH, version unrecorded')"
    else
        vwarn "RStudio" "not found — see the rstudio section"
    fi
    if have afni; then
        vok "AFNI" "$(read_version afni || echo 'resolves on PATH, version unrecorded')"
    else
        vwarn "AFNI" "not found — see the afni section"
    fi

    echo
    echo "  -- Docker --"
    if have docker; then
        if docker info >/dev/null 2>&1; then
            vok "Docker" "installed, usable without sudo"
        else
            vwarn "Docker" "installed, but not usable yet (log out/in after group add?)"
        fi
    else
        vfail "Docker" "not installed"
    fi

    if have docker; then
        for img in "nipreps/fmriprep:$FMRIPREP_VERSION" "poldracklab/mriqc:latest" \
                   "leonyichencai/synb0-disco:v3.0" "sebastientourbier/multiscalebrainparcellator:v1.1.1"; do
            if docker image inspect "$img" >/dev/null 2>&1; then
                vok "docker image" "$img"
            else
                vwarn "docker image" "$img — not pulled"
            fi
        done
    fi

    echo
    echo "  -- GPU / Apptainer --"
    if nvidia_smi_ok; then
        vok "NVIDIA driver" "$(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null | head -1)"
    elif have nvidia-smi; then
        vfail "NVIDIA driver" "nvidia-smi present but fails to run ($(nvidia-smi 2>&1 | head -1)) — likely needs a reboot after a driver upgrade"
    else
        vwarn "NVIDIA driver" "not found (fine if this machine has no NVIDIA GPU)"
    fi
    if have nvcc; then
        vok "CUDA Toolkit" "$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+')"
    else
        vwarn "CUDA Toolkit" "nvcc not found — only needed if something requires compiling CUDA code; HD-BET/FastSurfer/eddy_cuda don't"
    fi
    if have singularity || have apptainer; then
        vok "Apptainer/Singularity" "$(apptainer --version 2>/dev/null || singularity --version 2>/dev/null)"
    else
        vwarn "Apptainer/Singularity" "not found — only needed for the VSC/HPC singularity path in KUL_preproc_all.sh"
    fi
    if have docker && docker info 2>/dev/null | grep -q "^ Runtimes:.*nvidia"; then
        vok "NVIDIA Container Toolkit" "nvidia runtime registered with docker (docker run --gpus ready)"
    elif have nvidia-ctk; then
        vwarn "NVIDIA Container Toolkit" "nvidia-ctk installed but docker's nvidia runtime isn't registered — \
run 'sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker'"
    else
        vwarn "NVIDIA Container Toolkit" "not installed — only needed for GPU-accelerated docker containers (fastsurfer_gpu/hd-glio-auto)"
    fi
    if have code; then
        vok "VS Code" "$(code --version 2>/dev/null | head -1)"
    else
        vwarn "VS Code" "not found — see the vscode section"
    fi

    echo
    echo "  -- conda environments --"
    if [ -x "$(conda_bin)" ]; then
        vok "miniforge" "$(conda_bin)"

        _verify_env_bin() {
            # $1=env name, $2=label, $3=binary inside envs/$1/bin, $4... = args to smoke-test it
            local env="$1" label="$2" bin="$3"; shift 3
            local path="$SOFTWARE_ROOT/miniforge3/envs/$env/bin/$bin"
            if [ ! -d "$SOFTWARE_ROOT/miniforge3/envs/$env" ]; then
                vfail "conda: $env" "environment does not exist"
            elif [ ! -x "$path" ]; then
                vwarn "conda: $env" "environment exists, but $bin not found in it"
            elif "$path" "$@" >/dev/null 2>&1; then
                vok "conda: $env" "$label"
            else
                vwarn "conda: $env" "environment exists, but '$bin $*' failed"
            fi
        }

        _verify_env_bin scilpy "scil_tractogram_filter_by_roi resolves" scil_tractogram_filter_by_roi --help
        _verify_env_bin hd-bet-env "hd-bet resolves" hd-bet --help
        # Instantiating the pretrained model, not just importing: 'import
        # resseg, ants' succeeds on an install whose checkpoint is missing or
        # unreachable, which is the failure mode that actually happens (see
        # _resseg_fix_weights) and which otherwise only shows up mid-run.
        _verify_env_bin resseg "resseg importable and pretrained weights load" \
            python -c "import ants; from resseg.model import ressegnet; ressegnet()"

        # Import the chain that actually broke during install (nnunet ->
        # batchgenerators -> matplotlib), touch numpy<->torch (which fails at
        # runtime, not import, under numpy 2), and confirm the weights resolve.
        # A bare 'import hd_glio' passes on an install that cannot segment.
        _verify_env_bin hdglio "hd-glio importable, torch/numpy interop, weights present" \
            python -c "import numpy as np, torch, matplotlib; from batchgenerators.dataloading import MultiThreadedAugmenter; from nnunet.inference.predict import predict_cases; import os; from hd_glio import paths; torch.from_numpy(np.zeros((2,2), dtype=np.float32)); assert os.path.isdir(paths.folder_with_parameter_files), paths.folder_with_parameter_files"
        # hd-bet v1 is a scripts=[] entry with no shebang upstream; this fails
        # with 'Exec format error' if the source patch did not apply.
        _verify_env_bin hdglio "hd-bet (v1) is executable" hd-bet --help
        if [ "$USE_KARAWUN_DEV" -eq 1 ]; then
            _verify_env_bin KarawunDev "karawun importable" python -c "import karawun"
        else
            _verify_env_bin KarawunEnv "karawun importable" python -c "import karawun"
        fi
        _verify_env_bin pyfMRI "nilearn importable" python -c "import nilearn, nibabel, pandas, matplotlib, yaml"
        _verify_env_bin lore_sd "lore_dwi2decomposition resolves" lore_dwi2decomposition --help
    else
        vfail "miniforge" "not installed at $SOFTWARE_ROOT/miniforge3"
    fi

    echo
    echo "  -- FastSurfer (uv venv, not a conda env) --"
    local fsdest="$SOFTWARE_ROOT/src/FastSurfer"
    if [ ! -x "$fsdest/.venv/bin/python" ]; then
        vfail "FastSurfer .venv" "not found at $fsdest/.venv"
    elif "$fsdest/.venv/bin/python" -c "import torch" >/dev/null 2>&1; then
        vok "FastSurfer .venv" "torch importable"
    else
        vwarn "FastSurfer .venv" "exists, but torch import failed"
    fi
    if [ -x "$fsdest/run_fastsurfer.sh" ] && [ -f "$fsdest/run_fastsurfer.real.sh" ]; then
        vok "FastSurfer wrapper" "run_fastsurfer.sh shim + run_fastsurfer.real.sh both present"
    else
        vwarn "FastSurfer wrapper" "run_fastsurfer.sh shim or run_fastsurfer.real.sh missing at $fsdest"
    fi

    echo
    echo "  -- sibling repos --"
    _verify_repo() {
        local name="$1" expect_branch="$2"
        local dir="$SOFTWARE_ROOT/src/$name"
        if [ ! -d "$dir/.git" ]; then
            vfail "repo: $name" "not cloned"
            return
        fi
        local actual_branch
        actual_branch=$(git -C "$dir" branch --show-current 2>/dev/null)
        if [ "$actual_branch" = "$expect_branch" ]; then
            vok "repo: $name" "@ $actual_branch"
        else
            vwarn "repo: $name" "on '$actual_branch', expected '$expect_branch' (detached HEAD is normal for a pinned-commit checkout — verify the commit by hand)"
        fi
    }
    _verify_repo KUL_NIS "$KUL_NIS_BRANCH"
    _verify_repo KUL_VBG "$KUL_VBG_BRANCH"
    _verify_repo KUL_FWT "$KUL_FWT_BRANCH"
    if [ -d "$SOFTWARE_ROOT/src/LoRE-SD/.git" ]; then
        vok "repo: LoRE-SD" "cloned @ $(git -C "$SOFTWARE_ROOT/src/LoRE-SD" branch --show-current 2>/dev/null) (see 'conda: lore_sd' above for the actual install check)"
    else
        vfail "repo: LoRE-SD" "not cloned"
    fi

    echo
    echo "  -- shell integration --"
    # Confirmed bug (found live): this used to derive the list of files to check
    # from INSTALL_MODE and then test each only for PRESENCE of the marker. A
    # box carrying the block in ~/.bashrc *and* both /etc files therefore
    # verified perfectly clean while every shell sourced FreeSurfer and FSL
    # three times over. Scan all known locations and treat an unexpected count
    # as a failure, not a pass.
    _found_blocks="$(kul_block_locations)"
    _n_blocks=$(printf '%s\n' "$_found_blocks" | grep -c . || true)
    _expected_blocks=1
    [ "$INSTALL_MODE" = "shared" ] && _expected_blocks=2   # body in profile.d + shim in bash.bashrc
    if [ "$_n_blocks" -eq 0 ]; then
        vwarn "shell env" "managed block not found in any of: ${KUL_BLOCK_ALL_DESTS[*]} — run the bashrc section (or add it by hand if you deliberately skipped it, e.g. on a machine with pre-existing FSL/ANTs/FreeSurfer/mrtrix3)"
    else
        while IFS= read -r _profile_dest; do
            [ -n "$_profile_dest" ] && vok "$_profile_dest" "managed environment block present"
        done <<< "$_found_blocks"
    fi
    if [ "$_n_blocks" -gt "$_expected_blocks" ]; then
        vfail "shell env" "managed block found in $_n_blocks files, expected $_expected_blocks for '$INSTALL_MODE' mode — FreeSurfer/FSL are being sourced more than once per shell; run '--only bashrc' to de-duplicate"
    fi

    # Cheap end-to-end check on the result: even with one block per file, a
    # non-idempotent PATH export would still show up here.
    _dupe_path=$(printf '%s' "$PATH" | tr ':' '\n' | sort | uniq -d | grep -c . || true)
    if [ "${_dupe_path:-0}" -gt 0 ]; then
        vwarn "PATH" "$_dupe_path duplicated entries in the PATH this script inherited — expected until you open a fresh terminal; if it survives that, the block is still in more than one file"
    else
        vok "PATH" "no duplicate entries"
    fi

    echo
    echo "  ────────────────────────────────────────────────────────────"
    printf "  %s OK   %s WARN   %s FAIL\n" "$VERIFY_OK" "$VERIFY_WARN" "$VERIFY_FAIL"
    if [ "$VERIFY_FAIL" -gt 0 ]; then
        fail "One or more required components are missing — see the FAIL lines above."
    elif [ "$VERIFY_WARN" -gt 0 ]; then
        warn "Everything required is present; some secondary/optional pieces need attention — see the WARN lines above."
    else
        ok "Everything checked out clean."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

maybe_run_section() {
    local name="$1" flag_var="$2" func="$3"
    if ! section_enabled "$name"; then
        return
    fi
    if [ "${!flag_var}" -eq 1 ]; then
        echo
        "$func"
    else
        warn "Skipping '$name' (disabled by config — set $flag_var=1 to enable)"
    fi
}

maybe_run_section apt              DO_APT               section_apt
maybe_run_section docker           DO_DOCKER             section_docker
maybe_run_section nvidia           DO_NVIDIA             section_nvidia
maybe_run_section apptainer        DO_APPTAINER           section_apptainer
maybe_run_section vscode           DO_VSCODE              section_vscode
maybe_run_section miniforge        DO_MINIFORGE          section_miniforge
maybe_run_section env-dcm2bids     DO_ENV_DCM2BIDS        section_env_dcm2bids
maybe_run_section clinical-pydeps  DO_CLINICAL_PYDEPS     section_clinical_pydeps
maybe_run_section env-scilpy       DO_ENV_SCILPY         section_env_scilpy
maybe_run_section env-hdbet        DO_ENV_HDBET          section_env_hdbet
maybe_run_section env-resseg       DO_ENV_RESSEG          section_env_resseg
maybe_run_section env-hdglio       DO_ENV_HDGLIO          section_env_hdglio
maybe_run_section env-karawun      DO_ENV_KARAWUN         section_env_karawun
maybe_run_section env-fastsurfer   DO_ENV_FASTSURFER      section_env_fastsurfer
maybe_run_section env-pyfmri        DO_ENV_PYFMRI          section_env_pyfmri
maybe_run_section env-lore-sd      DO_ENV_LORE_SD         section_env_lore_sd
maybe_run_section env-dicom        DO_ENV_DICOM           section_env_dicom
maybe_run_section repos            DO_REPOS               section_repos
maybe_run_section mrtrix3          DO_MRTRIX3             section_mrtrix3
maybe_run_section shard-recon      DO_SHARD_RECON         section_shard_recon
maybe_run_section ants             DO_ANTS                section_ants
maybe_run_section fsl              DO_FSL                 section_fsl
maybe_run_section freesurfer DO_FREESURFER    section_freesurfer
maybe_run_section leaddbs-atlases  DO_LEADDBS_ATLASES     section_leaddbs_atlases
maybe_run_section spm12            DO_SPM12               section_spm12
maybe_run_section itksnap          DO_ITKSNAP             section_itksnap
maybe_run_section psychopy         DO_PSYCHOPY            section_psychopy
maybe_run_section datalad          DO_DATALAD             section_datalad
maybe_run_section awscli           DO_AWSCLI              section_awscli
maybe_run_section r                DO_R                   section_r
maybe_run_section rstudio          DO_RSTUDIO             section_rstudio
maybe_run_section afni             DO_AFNI                section_afni
maybe_run_section docker-images    DO_DOCKER_IMAGES       section_docker_images
maybe_run_section bashrc           DO_BASHRC              section_bashrc

echo
log "Done. Manual steps this script cannot do for you:"
echo "   - FreeSurfer license.txt (registration-gated, see the freesurfer section output above)"
echo "   - SPM12 + MATLAB, for KUL_fmriproc_spm's task-fMRI GLM (commercial software; nilearn"
echo "     via KUL_fmriproc_nilearn_new.sh is the license-free alternative already in the pipeline)"
echo "   - hd-glio-auto's image is pulled by default now (see docker-images); needs nvidia-docker/"
echo "     the Container Toolkit at run time — check its own README for the 'docker run' invocation"
echo "   - Lead-DBS itself (the MATLAB GUI app) isn't installed -- only its atlas/template data is"
echo "     (see leaddbs-atlases), which is all KUL_tracts_ocd.sh actually needs. Get the full app"
echo "     from lead-dbs.org yourself if you want it too; KUL_tracts_ocd.sh now reads the atlas path"
echo "     from \$SOFTWARE_ROOT/src/leaddbs instead of the old hardcoded /usr/local/KUL_apps/leaddbs"
if [ "$NVIDIA_DRIVER_JUST_CHANGED" -eq 1 ]; then
    echo "   - REBOOT before GPU-accelerated sections will see the driver just installed/changed"
fi
if [ "$INSTALL_MODE" = "shared" ]; then
    echo "   - For each additional user who needs this install:"
    echo "       sudo usermod -aG $GROUP_NAME <user>   # write access to $SOFTWARE_ROOT"
    echo "       sudo usermod -aG docker <user>        # docker access (if the docker section ran)"
    echo "     Both take effect on that user's next login."
    echo "   - New terminals/logins pick up /etc/bash.bashrc + /etc/profile.d/kul_nis_env.sh"
    echo "     automatically; 'source /etc/bash.bashrc' to pick it up in the current one"
else
    echo "   - 'source ~/.bashrc' (or open a new terminal) to pick up the new PATH/env vars"
fi

# QC report: always runs at the end, regardless of --only/--skip scoping --
# it's a pure read-only report, not an installable section, so "what's
# actually on this machine and what version" is worth seeing after every
# invocation, not just full unfiltered runs. Persisted to a timestamped file
# too, not just the console. Still respects an explicit '--skip verify' or
# DO_VERIFY=0 if you genuinely don't want it (e.g. scripted/CI use).
_run_qc=1
[ "$DO_VERIFY" -eq 0 ] && _run_qc=0
if [ -n "${SKIP_SECTIONS:-}" ] && [[ ",${SKIP_SECTIONS}," == *",verify,"* ]]; then
    _run_qc=0
fi
if [ "$_run_qc" -eq 1 ]; then
    mkdir -p "$SOFTWARE_ROOT/qc_reports" 2>/dev/null || true
    _qc_report="$SOFTWARE_ROOT/qc_reports/qc_$(date +%Y%m%d_%H%M%S).txt"
    echo
    section_verify 2>&1 | tee "$_qc_report"
    echo
    log "QC report saved to $_qc_report"
fi
