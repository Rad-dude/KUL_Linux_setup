# KUL_Linux_setup

Sets up a fresh Ubuntu / Linux Mint machine to run the KUL neuroimaging
pipelines — [KUL_NIS](https://github.com/treanus/KUL_NIS),
[KUL_VBG](https://github.com/KUL-Radneuron/KUL_VBG) and
[KUL_FWT](https://github.com/KUL-Radneuron/KUL_FWT) — including cloning those
three repositories at their pinned branches.

```bash
git clone <this-repo> KUL_Linux_setup
cd KUL_Linux_setup
./setup_environment.sh
```

Run with no flags in a real terminal and a short wizard asks whether the install
is for this account or shared, and where it should live.

## Usage

```bash
./setup_environment.sh                                   # wizard
./setup_environment.sh --mode user                       # this account only (default root: $HOME/software)
./setup_environment.sh --mode shared --group kulusers    # shared install (default root: /opt/kul_software)
./setup_environment.sh --root /some/other/path           # override the mode's default root
./setup_environment.sh -y                                # skip the confirmation prompt (automation)
./setup_environment.sh --list                            # show section names and exit
./setup_environment.sh --only mrtrix3,ants               # run just these sections
./setup_environment.sh --skip docker,fsl                 # run everything except these
./setup_environment.sh --karawun-stock                   # conda-forge karawun instead of the KUL fork
./setup_environment.sh --dry-run                         # print what would run, do nothing
```

`--help` prints the full option list. The script is idempotent where practical:
completed sections check for their own output and are cheap to skip, so it is
safe to re-run after fixing a failure partway through.

It does modify the system — apt packages, Docker, CUDA/NVIDIA driver bits, and a
managed environment block, written to `~/.bashrc` in user mode or to
`/etc/profile.d/kul_nis_env.sh` in shared mode (with a one-line source shim in
`/etc/bash.bashrc`, since `/etc/profile.d` is only read by login shells and
desktop terminals spawn non-login ones). The `bashrc` section owns that block:
it works out which mode the machine is already in from what is on disk, refreshes
a stale block in place, and removes copies left behind in the other mode's
locations, keeping backups as `<file>.kulbak.<timestamp>`. Exactly one live copy
of the body is the invariant — a second one makes every shell source FreeSurfer
and FSL twice and leaves PATH full of duplicates — and `--only verify` fails if
it finds more. Everything under `$SOFTWARE_ROOT` is self-contained and easy to delete,
with one exception: FreeSurfer is a real system install, because upstream ships
only `.deb`/`.rpm` with no relocatable option since 8.0. `$SOFTWARE_ROOT/src/freesurfer`
is a symlink to wherever apt put it.

## What it installs

33 sections, listed by `--list`. Broadly:

- **System**: apt build deps, Docker, NVIDIA/CUDA, Apptainer, VS Code
- **Python**: Miniforge, then per-tool conda envs — dcm2bids, scilpy, HD-BET,
  resseg, HD-GLIO, karawun, FastSurfer, pyfMRI, LoRE-SD
- **Neuroimaging**: MRtrix3, shard-recon, ANTs, FSL, FreeSurfer, SPM12,
  Lead-DBS atlases, ITK-SNAP
- **Extras** (not KUL_NIS dependencies, installed on request): PsychoPy, datalad,
  awscli, R, RStudio, AFNI
- **Finally**: the three pipeline repos, docker images, the environment block,
  and a `verify` pass

## Notable, non-obvious choices

**mrtrix3 and karawun build from KUL forks, not upstream** — both carry fixes the
pipelines require, and both are pinned to explicit commits:

| | repo | branch | commit |
|---|---|---|---|
| mrtrix3 | `Rad-dude/mrtrix3` | `fix/mrconvert-direct-io-arg-binding` | `5a643594` |
| karawun | `Rad-dude/karawun` | `kul-extended-palette` | `72bbc955` |

The mrtrix3 branch restores a missing f-string prefix in `dwifslpreproc`, without
which the `mrconvert` call that crops the eddy-derived field map gets three
positional arguments instead of two and fails immediately. The karawun branch
widens the colour palette from 31 to 64 entries, append-only so indices 0-30 stay
byte-identical; stock karawun clamps everything above index 30, so every fMRI
activation label renders in one colour and collides with the tracts. The karawun
fork is the default install — `--karawun-stock` opts back out to the conda-forge
package, which is also the one that corrupts Enhanced/multi-frame donor DICOMs.

**mrview builds against Qt6 where available, Qt5 otherwise**, via mrtrix3's own
`-DMRTRIX_USE_QT5=ON`. The choice is made by probing for the Qt CMake config
rather than by distro release, so older bases (Linux Mint 20/21) work without a
version whitelist to maintain. Headless screenshots through `xvfb-run` behave the
same either way — Xvfb is an X server and has no knowledge of the client toolkit —
but the Qt **xcb platform plugin** does matter, and the script warns explicitly if
it is missing rather than letting every screenshot fail at run time.

**SPM12 is installed; MATLAB is not.** SPM12 lands in
`$SOFTWARE_ROOT/src/matlab_apps/spm12` with `$KUL_MATLAB_APPS` exported, which is
what `KUL_NIS/share/spm12/*.m` resolves at runtime. MATLAB itself is commercial
and must be installed and licensed separately; without it, use the MATLAB-free
GLM engine (`KUL_clinical_fmridti.sh -E nilearn`).

**Known issue, not fixed by this script: `fsleyes` can segfault under remote-desktop
sessions using software OpenGL rendering** — e.g. observed under NoMachine's default
virtual-display setup (no GPU passthrough), not under Tailscale/RustDesk in the same
testing. The actual trigger is Mesa's software rasterizer (`swrast_dri.so`), not the
remote-desktop protocol itself: FSL's own bundled `libglapi.so.0` (an older Mesa
build, shipped for portability) can mismatch the system's newer one once rendering
falls back to software mode. If you hit it, this fixes it:
```bash
alias fsleyes='LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libglapi.so.0 fsleyes'
```
(adjust the path for your distro/arch if `/usr/lib/x86_64-linux-gnu` doesn't exist).
Not applied by this script, since it's a workaround for a specific remote-display
symptom, not something every install needs — worth keeping in your own `~/.bashrc`
if you use a remote-desktop setup that triggers it.

## Documentation

- [`SOFTWARE_ROOT_SETUP.md`](SOFTWARE_ROOT_SETUP.md) — directory layout,
  environment variables, exact pinned commits, and per-tool build notes
- [`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) — per-conda-env recipes, for
  reproducing an environment by hand

## History

This script previously lived at `tools/setup_scripts_new/` inside KUL_NIS, up to
commit `e9bcf40`. It was split out because it clones KUL_NIS itself — living
inside the repo it installs meant bootstrapping by hand first.

It supersedes [`treanus/KUL_Linux_Installation`](https://github.com/treanus/KUL_Linux_Installation)
for the pipelines above, though the two are not equivalent: that script also
installs CAT12, CONN, the full Lead-DBS toolbox, MeVisLab and GDCM, none of which
are covered here yet.
