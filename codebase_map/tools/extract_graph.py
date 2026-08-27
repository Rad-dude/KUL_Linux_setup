#!/usr/bin/env python3
"""
Regex/heuristic dependency-graph extractor for KUL_NIS / KUL_VBG / KUL_FWT.

Not a real parser (bash has no robust free one, and this codebase mixes
bash/Python/MATLAB) -- this is a documented set of heuristics, tuned against
manual inventories of all three projects (see codebase_map/notes/). It is
meant to be re-run after future changes, not a one-time snapshot.

Method (see codebase_map/PLAN.md section 3 for the rationale):
  1. Walk each project tree, register every .sh/.py/.m file as a node.
  2. Strip comments / heredocs / docstrings from each file's text (this is
     what keeps "usage text mentions a sibling script" from turning into a
     false call edge -- confirmed necessary against KUL_VBG.sh, which
     documents but never calls its own sibling scripts).
  3. Whole-word scan the cleaned text for (a) other local script basenames
     across all three projects, (b) a curated external-tool vocabulary.
     Because the codebase's own convention is "assign the command line to a
     variable (task_in/cmd/cmd_str), then eval it via a wrapper function"
     rather than calling directly, scanning the whole file text for literal
     name occurrences (not just line-start commands) is what actually
     recovers these edges -- and it only fails exactly where the codebase's
     own indirection is genuinely dynamic (name built from a runtime
     variable, e.g. track_recipes/${bundle}.txt), which is the case where
     "unresolved" is the correct answer, not a bug in the heuristic.
  4. Separately: `source`/`.` lines (sourcing edges), Python
     import/from-import (module edges + curated py-lib edges).
  5. A short hand-curated list of edges the regex approach cannot recover at
     all (genuinely dynamic dispatch) -- added explicitly, tagged
     source="manual", so they're documented rather than silently missing.
  6. setup_environment.sh's install sections and conda/venv envs -- modeled
     from a hand-built table (the section structure is already fully
     enumerated in codebase_map/notes/setup_environment_analysis.md; re-
     deriving it via regex would be less accurate than transcribing it).

Output: codebase_map/data/graph.json -- nodes + typed edges, source of truth
for the diagrams and the interactive explorer. Also prints a short summary.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from curated_metadata import NODE_PURPOSE, TOOL_INFO

# codebase_map/tools/extract_graph.py -> KUL_software/ is two levels up.
# Not hardcoded to one machine's checkout path -- this runs the same from
# a CI clone as from a local one.
ROOT = Path(__file__).resolve().parent.parent.parent
PROJECT_DIRS = {
    "KUL_NIS": ROOT / "src/KUL_NIS",
    "KUL_VBG": ROOT / "src/KUL_VBG",
    "KUL_FWT": ROOT / "src/KUL_FWT",
}
SETUP_SCRIPT = ROOT / "setup_environment.sh"
OUT_PATH = ROOT / "codebase_map/data/graph.json"

CODE_EXTS = {".sh": "bash", ".py": "python", ".m": "matlab"}

# ---------------------------------------------------------------------------
# Curated external-tool vocabulary (name -> toolkit), compiled from the three
# inventory reports' "consolidated external-tool" tables plus
# setup_environment.sh's section list. Not exhaustive of everything these
# tools ship -- exhaustive of what this codebase is observed to call.
# ---------------------------------------------------------------------------
EXTERNAL_TOOLS = {}
def _tools(toolkit, names):
    for n in names:
        EXTERNAL_TOOLS[n] = toolkit

_tools("FreeSurfer", ["recon-all", "mri_convert", "mri_synthstrip", "mri_synthseg",
    "SynthSeg", "mri_segment_hypothalamic_subunits", "mri_surf2surf",
    "mri_annotation2label", "mri_mask", "mri_aparc2aseg", "mri_vol2vol",
    "segment_subregions", "samseg", "run_samseg", "mris_register"])
_tools("FastSurfer", ["run_fastsurfer", "run_fastsurfer.sh", "fastsurfer"])
_tools("ANTs", ["antsRegistration", "antsRegistrationSyN.sh", "antsRegistrationSyN",
    "antsApplyTransforms", "antsBrainExtraction.sh", "antsBrainExtraction",
    "antsAtroposN4.sh", "antsAtroposN4", "Atropos", "ImageMath",
    "WarpImageMultiTransform", "antsMotionCorr", "ConvertTransformFile",
    "N4BiasFieldCorrection", "N4"])
_tools("FSL", ["fslmaths", "fslstats", "fslreorient2std", "fslswapdim", "fslorient",
    "bet", "flirt", "fslmerge", "fsl_glm", "slicer", "susan", "topup", "fast"])
_tools("mrtrix3", ["mrcalc", "mrstats", "mrthreshold", "maskfilter", "mrfilter",
    "labelconvert", "mrmath", "mrconvert", "mrinfo", "mrgrid", "mrview",
    "mrtransform", "mrcat", "mrresize", "dwifslpreproc", "dwidenoise",
    "dwibiascorrect", "mrdegibbs", "dwi2mask", "dwi2response", "dwi2fod",
    "dwi2tensor", "tensor2metric", "tckgen", "tcksift", "tcksift2", "tckedit",
    "tckmap", "tckstats", "tckresample", "tcksample", "dwiextract",
    "dwigradcheck", "5ttgen", "5tt2gmwmi", "mtnormalise", "population_template",
    "responsemean", "voxel2fixel", "warpinit", "fixel2voxel", "fod2fixel",
    "tck2fixel"])
_tools("scilpy", ["scil_reco_bundles", "scil_bundle_compute_centroid",
    "scil_bundle_reject_outliers", "scil_bundle_uniformize_endpoints",
    "scil_bundle_label_map", "scil_filter_tracts", "scil_tractogram_convert",
    "scil_tractogram_detect_loops", "scil_tractogram_filter_by_roi",
    "scil_tractogram_segment_with_recobundles", "scil_tractogram_smooth",
    "scil_vis_mosaic", "scil_viz_bundle_screenshot_mni",
    "scil_viz_bundle_screenshot_mosaic"])
_tools("HD-BET/HD-GLIO", ["hd-bet", "HD-BET", "hd-glio-auto", "hd-glio-predict"])
_tools("resseg", ["resseg"])
_tools("karawun", ["karawun"])
_tools("DICOM/BIDS", ["dcm2niix", "dcm2bids", "dcmsend", "dcm2bids_scaffold"])
_tools("archival", ["7z"])
_tools("containers", ["docker", "singularity", "apptainer"])
_tools("MATLAB/SPM", ["matlab", "spm12"])
_tools("distortion-correction", ["synb0"])
_tools("pipelines", ["fmriprep", "qsiprep", "mrtrix_connectome", "mriqc", "tedana"])
_tools("viz", ["freeview"])
_tools("misc", ["csvkit"])

PY_LIBS = {"nibabel", "dipy", "nilearn", "scilpy", "numpy", "scipy", "matplotlib",
    "sklearn", "PIL", "pandas", "pdf2image", "vtk", "SimpleITK", "seaborn",
    "skimage"}

# Bash builtins / generic commands to never treat as "external tool calls"
# even if someone later adds them to EXTERNAL_TOOLS by mistake.
STOPLIST = {"cd", "rm", "mkdir", "echo", "printf", "cat", "cp", "mv", "chmod",
    "chown", "test", "true", "false", "exit", "return", "export", "unset",
    "read", "wait", "sleep", "tar", "gzip", "gunzip", "curl", "wget", "ln",
    "touch", "find", "grep", "sed", "awk", "cut", "sort", "uniq", "head",
    "tail", "xargs", "basename", "dirname", "date", "kill", "trap", "set",
    "local", "declare", "eval", "function", "bash", "sh", "sudo", "git",
    "pip", "conda", "mamba", "exec", "tee", "diff", "du", "df", "ls", "which",
    "command", "type", "hash", "nice", "nohup", "time"}

# ---------------------------------------------------------------------------
# Manually-curated edges the regex approach structurally cannot recover
# (target built from a runtime variable/config value, not literal text) --
# see codebase_map/notes/inventory_KUL_FWT.md and inventory_KUL_NIS.md.
# Tagged source="manual" in the output, never silently dropped.
# ---------------------------------------------------------------------------
MANUAL_DYNAMIC_EDGES = [
    dict(src="KUL_FWT/KUL_FWT_make_VOIs.sh", dst="KUL_FWT/track_recipes/",
         type="dynamic_data_dependency", function="make_VOIs",
         note="recipe_f=\"${function_path}/track_recipes/${tck_list[$q]}.txt\" -- bundle name from -c config file at runtime"),
    dict(src="KUL_FWT/KUL_FWT_make_VOIs_4Temp.sh", dst="KUL_FWT/track_recipes/",
         type="dynamic_data_dependency", function="make_VOIs", note="same pattern as KUL_FWT_make_VOIs.sh"),
    dict(src="KUL_FWT/KUL_FWT_make_TCKs.sh", dst="KUL_FWT/KUL_FWT_templates/TCK_models/",
         type="dynamic_data_dependency", function="make_bundle",
         note="TCK_models/${tck_list[$q]}_GN_symmetrical.tck -- per-bundle reference tractogram, bundle name at runtime"),
    dict(src="KUL_FWT/KUL_FWT_make_TCKs_4Temp.sh", dst="KUL_FWT/KUL_FWT_templates/TCK_models/",
         type="dynamic_data_dependency", function="make_bundle", note="same pattern as KUL_FWT_make_TCKs.sh"),
    dict(src="KUL_NIS/KUL_fmriproc_spm_new.sh", dst="KUL_NIS/share/spm12/",
         type="dynamic_dispatch", function="KUL_compute_SPM_matlab",
         note="matlab -r selects one of 6 spm12_*stats*run.m job scripts at runtime by run-count/algorithm flag"),
]

WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _blank(match):
    """Replace a matched span with same-length blanks, preserving newlines,
    so character offsets (and therefore line numbers) stay valid against the
    original text -- deleting the span outright would shift every later
    match's reported line number."""
    return "".join(c if c == "\n" else " " for c in match.group(0))


def strip_noise(text, lang):
    """Blank out comments/heredocs/docstrings so mentions-in-prose don't
    become false call edges (confirmed necessary: KUL_VBG.sh documents but
    never calls KUL_VBG_cook_template.sh/KUL_VBG_multiparc.sh in its own
    Usage heredoc). Inline comments (code; # trailing remark) are NOT
    stripped -- only whole-line comments -- so a trailing remark that happens
    to mention a tool/script name can still produce a false-positive edge;
    documented as a known limitation rather than worth a heavier fix."""
    if lang in ("bash",):
        # heredocs: <<[-]DELIM ... DELIM
        text = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?\n.*?\n\1\b", _blank, text, flags=re.DOTALL)
        # whole-line comments
        text = re.sub(r"(?m)^\s*#.*$", _blank, text)
    elif lang == "python":
        # triple-quoted strings (docstrings) -- also kills embedded HTML/JS
        # string literals in report generators, which is fine, we don't want those.
        text = re.sub(r'("""|\'\'\')(.*?)\1', _blank, text, flags=re.DOTALL)
        text = re.sub(r"(?m)^\s*#.*$", _blank, text)
    elif lang == "matlab":
        text = re.sub(r"(?m)^\s*%.*$", _blank, text)
    return text


def word_boundary_pattern(name):
    return re.compile(r"(?<![\w.-])" + re.escape(name) + r"(?![\w.-])")


class Node:
    __slots__ = ("id", "project", "path", "basename", "ext", "lang", "loc",
                 "functions", "function_ranges", "internal_steps",
                 "sourced_by_count", "has_usage_getopts", "is_dev")

    def __init__(self, node_id, project, path, basename, ext, lang, loc):
        self.id = node_id
        self.project = project
        self.path = path
        self.basename = basename
        self.ext = ext
        self.lang = lang
        self.loc = loc
        self.functions = []
        self.function_ranges = []
        self.internal_steps = []
        self.sourced_by_count = 0
        self.has_usage_getopts = False
        self.is_dev = False

    def to_dict(self):
        classification = "helper" if self.sourced_by_count > 0 and not self.has_usage_getopts else \
            ("entry-point" if self.has_usage_getopts else "utility")
        self.internal_steps.sort(key=lambda s: s["line"])
        return dict(id=self.id, type="code", lang=self.lang, project=self.project,
                    path=self.path, basename=self.basename,
                    classification=classification, is_dev=self.is_dev,
                    functions=self.functions, loc=self.loc,
                    purpose=NODE_PURPOSE.get(self.id),
                    internal=dict(functions=self.function_ranges, steps=self.internal_steps))


def discover_nodes():
    nodes = {}
    basename_index = {}
    for project, base in PROJECT_DIRS.items():
        for dirpath, dirnames, filenames in os.walk(base):
            # os.scandir (which os.walk uses) doesn't guarantee traversal
            # order -- sort so two runs over identical source produce
            # byte-identical output regardless of OS/filesystem, which is
            # what makes a CI "is the committed map stale" diff meaningful
            # rather than noisy.
            dirnames.sort()
            if ".git" in dirpath.split(os.sep):
                continue
            for fn in sorted(filenames):
                ext = Path(fn).suffix
                if ext not in CODE_EXTS:
                    continue
                full = Path(dirpath) / fn
                rel = full.relative_to(ROOT / "src")
                node_id = str(rel)
                try:
                    text = full.read_text(errors="replace")
                except OSError:
                    continue
                loc = text.count("\n") + 1
                node = Node(node_id, project, str(rel), fn, ext, CODE_EXTS[ext], loc)
                rel_lower = str(rel).lower()
                if any(tag in rel_lower for tag in ("dev_work", "_bkup", "wip", "deprecated")):
                    node.is_dev = True
                nodes[node_id] = node
                basename_index.setdefault(fn, []).append(node_id)
    return nodes, basename_index


def pick_primary(basename_index, name, exclude=None, caller_project=None):
    """Bare-name resolution: PATH puts all three project dirs on it, so a
    bare match could hit more than one node with the same basename -- either
    a same-project stale duplicate (e.g. the share/nilearn/ copy of
    KUL_fmriproc_nilearn_new.sh) or a genuine cross-project name collision
    (KUL_VBG and KUL_NIS each ship their own copy of the lausanne2008 LUT
    scripts under atlasses/atlases/). A caller almost always means its own
    project's copy when one exists, so that takes priority over "shallowest
    path" -- shallowest-path is only the right tie-break within one project
    (top-level over a stale share/ copy) or for genuine PATH-based
    cross-project calls where no same-project candidate exists at all."""
    candidates = basename_index.get(name, [])
    if exclude:
        candidates = [c for c in candidates if c != exclude]
    if not candidates:
        return None, []
    if caller_project:
        same_project = [c for c in candidates if c.split("/", 1)[0] == caller_project]
        if same_project:
            candidates = same_project + [c for c in candidates if c not in same_project]
            same_sorted = sorted(same_project, key=lambda c: (c.count("/"), c))
            rest = [c for c in candidates if c not in same_sorted]
            return same_sorted[0], same_sorted[1:] + rest
    candidates_sorted = sorted(candidates, key=lambda c: (c.count("/"), c))
    return candidates_sorted[0], candidates_sorted[1:]


def compute_function_ranges(clean_text, lang):
    """Function boundaries (1-indexed start/end line, inclusive), for
    attributing calls to "which function does this happen inside" -- the
    basis of the explorer's per-file drill-down. Runs on the comment/heredoc/
    docstring-stripped text so a stray brace or indentation inside a comment
    can't throw off matching.

    Bash: brace-counted from the function's opening `{`. This works even
    though `${var}` parameter expansions also contain braces, because those
    are always balanced pairs contributing net-zero depth -- the same trick
    that makes naive counting correct despite not being a real parser.

    Python: indentation-based -- the body runs until the next non-blank line
    at or below the `def` line's own indentation.
    """
    ranges = []
    if lang == "bash":
        n = len(clean_text)
        for pat in (r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{",
                    r"(?m)^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{"):
            for m in re.finditer(pat, clean_text):
                name = m.group(1)
                start_line = clean_text[:m.start()].count("\n") + 1
                depth, i = 1, m.end()
                while i < n and depth > 0:
                    if clean_text[i] == "{":
                        depth += 1
                    elif clean_text[i] == "}":
                        depth -= 1
                    i += 1
                end_line = clean_text[:i].count("\n") + 1
                ranges.append({"name": name, "start": start_line, "end": end_line})
    elif lang == "python":
        lines = clean_text.split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"^(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
            if not m:
                continue
            indent, name = len(m.group(1)), m.group(2)
            end_line = i + 1
            for j in range(i + 1, len(lines)):
                stripped = lines[j].strip()
                if not stripped:
                    continue
                if len(lines[j]) - len(lines[j].lstrip()) <= indent:
                    break
                end_line = j + 1
            ranges.append({"name": name, "start": i + 1, "end": end_line})
    return ranges


def function_at_line(ranges, line_no):
    """Innermost (smallest-span) function containing line_no, or None for
    module-level/top-level code -- represented as "(script body)" downstream."""
    best = None
    for r in ranges:
        if r["start"] <= line_no <= r["end"]:
            if best is None or (r["end"] - r["start"]) < (best["end"] - best["start"]):
                best = r
    return best["name"] if best else None


def extract_edges(nodes, basename_index):
    edges = []
    unresolved = []
    local_names = set(basename_index.keys())

    for node in nodes.values():
        full = ROOT / "src" / node.path
        raw = full.read_text(errors="replace")
        node.has_usage_getopts = bool(re.search(r"\bgetopts\b", raw)) or \
            bool(re.search(r"(?i)\bfunction\s+usage\b|\bdef\s+main\b|argparse\.ArgumentParser", raw))
        clean = strip_noise(raw, node.lang)
        ranges = compute_function_ranges(clean, node.lang)
        node.function_ranges = ranges
        # dedupe function names (a name can appear via both bash regexes, or
        # be redefined) while preserving first-seen order
        seen_fn = []
        for r in ranges:
            if r["name"] not in seen_fn:
                seen_fn.append(r["name"])
        node.functions = seen_fn

        def record_step(line_no, step_type, target, extra=None):
            entry = dict(function=function_at_line(ranges, line_no) or "(script body)",
                          type=step_type, target=target, line=line_no)
            if extra:
                entry.update(extra)
            node.internal_steps.append(entry)

        # 1. sourcing edges (bash) -- high-confidence, separate from the
        #    generic whole-word scan below.
        if node.lang == "bash":
            for m in re.finditer(r"(?m)^\s*(?:source|\.)\s+(.+)$", clean):
                expr = m.group(1)
                name_m = re.search(r"([A-Za-z0-9_.-]+\.sh)\b", expr)
                if not name_m:
                    continue
                target_name = name_m.group(1)
                if target_name == node.basename:
                    continue  # self-reference artifact, skip
                target_id, alts = pick_primary(basename_index, target_name, exclude=node.id, caller_project=node.project)
                line_no = raw[:m.start()].count("\n") + 1
                if target_id:
                    edges.append(dict(src=node.id, dst=target_id, type="sources",
                                       resolved=True, line=line_no, source="regex"))
                    record_step(line_no, "sources", target_id)
                else:
                    unresolved.append(dict(src=node.id, raw=target_name, type="sources",
                                            line=line_no))

        # 2. python import edges
        if node.lang == "python":
            for m in re.finditer(r"(?m)^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))", clean):
                mod = (m.group(1) or m.group(2)).split(".")[0]
                line_no = raw[:m.start()].count("\n") + 1
                local_py = mod + ".py"
                if local_py in local_names and local_py != node.basename:
                    target_id, alts = pick_primary(basename_index, local_py, exclude=node.id, caller_project=node.project)
                    if target_id:
                        edges.append(dict(src=node.id, dst=target_id, type="imports",
                                           resolved=True, line=line_no, source="regex"))
                        record_step(line_no, "imports", target_id)
                        continue
                if mod in PY_LIBS:
                    edges.append(dict(src=node.id, dst=f"pylib:{mod}", type="imports_lib",
                                       resolved=True, line=line_no, source="regex"))
                    record_step(line_no, "imports_lib", f"pylib:{mod}")

        # 3. whole-word scan for local script/tool mentions anywhere else in
        #    the cleaned text (catches task_in="...", cmd=, direct calls,
        #    variable-assignment indirection -- see module docstring).
        seen_positions = set()
        for name in sorted(local_names):
            if name == node.basename:
                continue
            if len(name) < 6:
                continue  # avoid noise from very short basenames
            pat = word_boundary_pattern(name)
            for m in pat.finditer(clean):
                if m.start() in seen_positions:
                    continue
                seen_positions.add(m.start())
                target_id, alts = pick_primary(basename_index, name, exclude=node.id, caller_project=node.project)
                if not target_id:
                    continue
                line_no = raw[:m.start()].count("\n") + 1
                edge_type = "invokes"
                if target_id in nodes and nodes[target_id].project != node.project:
                    edge_type = "invokes_cross_project"
                edges.append(dict(src=node.id, dst=target_id, type=edge_type,
                                   resolved=True, line=line_no, source="regex",
                                   alt_targets=alts or None))
                record_step(line_no, edge_type, target_id)

        for tool, toolkit in EXTERNAL_TOOLS.items():
            if tool in STOPLIST:
                continue
            pat = word_boundary_pattern(tool)
            for m in pat.finditer(clean):
                line_no = raw[:m.start()].count("\n") + 1
                edges.append(dict(src=node.id, dst=f"tool:{tool}", type="calls_tool",
                                   toolkit=toolkit, resolved=True, line=line_no,
                                   source="regex"))
                record_step(line_no, "calls_tool", f"tool:{tool}")

        # 4. conda env activation -- resolve the small set of known
        #    KUL_*_ENV variables to their documented defaults (see
        #    KUL_main_functions.sh), else record the literal name.
        env_defaults = {"KUL_PYFMRI_ENV": "pyfMRI", "KUL_SCILPY_ENV": "scilpy",
                         "KUL_LORESD_ENV": "lore_sd", "KUL_DICOM_ENV": "KUL_dicom"}
        for m in re.finditer(r"conda activate\s+[\"']?\$?\{?(\w+)\}?[\"']?", clean):
            env_name = env_defaults.get(m.group(1), m.group(1))
            line_no = raw[:m.start()].count("\n") + 1
            edges.append(dict(src=node.id, dst=f"env:{env_name}", type="uses_env",
                               resolved=True, line=line_no, source="regex"))
            record_step(line_no, "uses_env", f"env:{env_name}")

        # 5. intra-file function-to-function calls -- whole-word scan each
        # function's own body for every OTHER function name defined in this
        # same file. This is what turns "a flat list of functions" into an
        # actual internal call graph for the drill-down view.
        fn_names = [r["name"] for r in ranges]
        clean_lines = clean.split("\n")
        for r in ranges:
            body = "\n".join(clean_lines[r["start"]:r["end"] - 1])  # exclude the def line itself
            body_offset_lines = r["start"]  # body's line 1 corresponds to file line start+1
            for other in fn_names:
                if other == r["name"] or len(other) < 3:
                    continue
                pat = word_boundary_pattern(other)
                m = pat.search(body)
                if m:
                    line_no = body_offset_lines + body[:m.start()].count("\n") + 1
                    node.internal_steps.append(dict(function=r["name"], type="calls_function",
                                                     target=other, line=line_no))

    return edges, unresolved


# ---------------------------------------------------------------------------
# setup_environment.sh install graph -- transcribed from
# codebase_map/notes/setup_environment_analysis.md rather than re-derived by
# regex (already fully enumerated by manual read-through; more accurate).
# ---------------------------------------------------------------------------
INSTALL_SECTIONS = [
    ("apt", 1, []), ("docker", 2, ["tool:docker"]), ("nvidia", 3, []),
    ("apptainer", 4, ["tool:apptainer"]), ("vscode", 5, []),
    ("miniforge", 6, []),
    ("env-dcm2bids", 7, ["tool:dcm2niix", "tool:dcm2bids", "env:base"]),
    ("clinical-pydeps", 8, ["env:base"]),
    ("env-scilpy", 9, ["env:scilpy"]),
    ("env-hdbet", 10, ["env:hd-bet-env", "tool:hd-bet"]),
    ("env-resseg", 11, ["env:resseg", "tool:resseg"]),
    ("env-hdglio", 12, ["env:hdglio", "tool:hd-glio-auto"]),
    ("env-karawun", 13, ["env:KarawunDev", "env:KarawunEnv", "tool:karawun"]),
    ("env-fastsurfer", 14, ["venv:FastSurfer/.venv", "tool:fastsurfer"]),
    ("env-pyfmri", 15, ["env:pyfMRI"]),
    ("env-lore-sd", 16, ["env:lore_sd"]),
    ("env-dicom", 17, ["env:KUL_dicom"]),
    ("repos", 18, ["repo:KUL_NIS", "repo:KUL_VBG", "repo:KUL_FWT"]),
    ("mrtrix3", 19, ["tool:mrconvert", "tool:tckgen", "tool:mrcalc"]),
    ("shard-recon", 20, []),
    ("ants", 21, ["tool:antsRegistration", "tool:antsApplyTransforms"]),
    ("fsl", 22, ["tool:fslmaths", "tool:flirt", "tool:bet"]),
    ("freesurfer", 23, ["tool:recon-all", "tool:mri_synthseg"]),
    ("leaddbs-atlases", 24, []),
    ("spm12", 25, ["tool:spm12", "tool:matlab"]),
    ("itksnap", 26, []),
    ("psychopy", 27, []),
    ("datalad", 28, []), ("awscli", 29, []), ("r", 30, []), ("rstudio", 31, []),
    ("afni", 32, []),
    ("docker-images", 33, ["tool:docker"]),
]


def build_install_nodes_and_edges():
    nodes = []
    edges = []
    for name, order, provides in INSTALL_SECTIONS:
        node_id = f"install:{name}"
        nodes.append(dict(id=node_id, type="install_section", name=name, order=order))
        for target in provides:
            edges.append(dict(src=node_id, dst=target, type="provides",
                               resolved=True, source="manual"))
    return nodes, edges


def main():
    nodes, basename_index = discover_nodes()
    edges, unresolved = extract_edges(nodes, basename_index)

    tool_ids = sorted({e["dst"] for e in edges if e["dst"].startswith("tool:")})
    env_ids = sorted({e["dst"] for e in edges if e["dst"].startswith("env:")})
    pylib_ids = sorted({e["dst"] for e in edges if e["dst"].startswith("pylib:")})

    # Merge manually-curated dynamic edges into each node's internal_steps
    # BEFORE to_dict() runs below (it sorts+snapshots internal_steps) -- so
    # the drill-down view sees these alongside the regex-extracted ones,
    # not appended out of order afterward.
    for e in MANUAL_DYNAMIC_EDGES:
        if e["src"] in nodes:
            nodes[e["src"]].internal_steps.append(dict(
                function=e.get("function") or "(script body)", type=e["type"],
                target=e["dst"], line=0, note=e["note"], manual=True))

    graph_nodes = [n.to_dict() for n in nodes.values()]
    for tid in tool_ids:
        name = tid.split(":", 1)[1]
        graph_nodes.append(dict(id=tid, type="external_tool", name=name,
                                 toolkit=EXTERNAL_TOOLS.get(name, "unknown"),
                                 description=TOOL_INFO.get(name)))
    for eid in env_ids:
        graph_nodes.append(dict(id=eid, type="conda_env", name=eid.split(":", 1)[1]))
    for pid in pylib_ids:
        graph_nodes.append(dict(id=pid, type="py_library", name=pid.split(":", 1)[1]))

    install_nodes, install_edges = build_install_nodes_and_edges()
    graph_nodes.extend(install_nodes)
    edges.extend(install_edges)

    # data-directory nodes referenced by the manual dynamic edges
    data_dir_ids = sorted({e["dst"] for e in MANUAL_DYNAMIC_EDGES})
    for did in data_dir_ids:
        graph_nodes.append(dict(id=did, type="data_dir", name=did))
    for e in MANUAL_DYNAMIC_EDGES:
        edges.append(dict(src=e["src"], dst=e["dst"], type=e["type"],
                           resolved=False, source="manual", note=e["note"]))

    # Final deterministic ordering -- so two runs over identical source
    # produce byte-identical graph.json regardless of set/dict iteration
    # order or filesystem traversal order. This is what makes "diff the
    # regenerated file against the committed one" a meaningful staleness
    # check (in CI or by hand) instead of noise.
    graph_nodes.sort(key=lambda n: n["id"])
    edges.sort(key=lambda e: (e["src"], e["dst"], e["type"], e.get("line", 0)))
    unresolved.sort(key=lambda u: (u["src"], u["raw"], u["line"]))

    graph = dict(
        meta=dict(
            generated_by="codebase_map/tools/extract_graph.py",
            node_count=len(graph_nodes),
            edge_count=len(edges),
            unresolved_count=len(unresolved),
            projects=list(PROJECT_DIRS.keys()),
        ),
        nodes=graph_nodes,
        edges=edges,
        unresolved=unresolved,
    )

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(graph, indent=1) + "\n")
    print(f"nodes={len(graph_nodes)} edges={len(edges)} unresolved={len(unresolved)}")
    print(f"tools={len(tool_ids)} envs={len(env_ids)} pylibs={len(pylib_ids)}")
    print(f"wrote {OUT_PATH}")

    missing_purpose = sorted(n.id for n in nodes.values() if n.id not in NODE_PURPOSE)
    missing_tool_desc = sorted(t.split(":", 1)[1] for t in tool_ids if t.split(":", 1)[1] not in TOOL_INFO)
    if missing_purpose:
        print(f"\n{len(missing_purpose)} code node(s) missing a NODE_PURPOSE entry in curated_metadata.py:")
        for m in missing_purpose:
            print(f"  {m}")
    if missing_tool_desc:
        print(f"\n{len(missing_tool_desc)} tool(s) missing a TOOL_INFO entry in curated_metadata.py:")
        for m in missing_tool_desc:
            print(f"  {m}")

    if args.strict and (missing_purpose or missing_tool_desc):
        print("\n--strict: failing because of the missing metadata above.")
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true",
                         help="exit non-zero if any code file or external tool is missing a "
                              "curated_metadata.py entry (used by CI; not needed for local iteration)")
    args = parser.parse_args()
    main()
