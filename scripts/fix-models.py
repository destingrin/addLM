#!/usr/bin/env python3
"""Auto-detect GGUF models and generate opencode.json with SINGLE llama-server entity."""
import sys
import json
from pathlib import Path

# Directory where this script (and addLM.bat) lives
script_dir = Path(__file__).parent.resolve()
# The project root may be the script folder itself, or its parent
# (layout: <root>\scripts\fix-models.py with <root>\models and
# <root>\scripts\llama.cpp - or <root>\llama.cpp).
root_dir = script_dir.parent


def resolve_project_dir(name: str, content_filter: str = "*.gguf") -> Path:
    """Locate a project folder next to the script or one level up.

    A candidate that actually holds matching files wins over one that merely
    exists. Without this, an empty stray folder (scripts/models, left behind by
    an earlier run) shadows the real one at the project root and every model
    looks missing.
    """
    candidates = [base / name for base in (script_dir, root_dir)]
    existing = [c for c in candidates if c.exists()]
    if content_filter:
        for candidate in existing:
            if any(candidate.rglob(content_filter)):
                return candidate
    if existing:
        return existing[0]
    # Neither exists yet -> point at the project root, the canonical location.
    # The script folder is not used as a fallback: an empty folder there would
    # shadow the real one at the project root.
    return root_dir / name


model_base = resolve_project_dir("models")
hash_file = script_dir / ".models_last_hash.txt"

# Home directory where OpenCode looks for opencode.json
#
# OpenCode v2 loads config from (lowest -> highest precedence):
#   1. ~/.config/opencode/opencode.json   <- the documented GLOBAL config
#   2. <ancestor dir>/opencode.json        <- searched from cwd up to the root
#   3. <ancestor dir>/.opencode/opencode.json
#
# The project writes to the documented global location ONLY.
#
# It used to also write ~/opencode.json. That file is picked up by rule 2, but
# ONLY when the working directory happens to be under the home directory -
# so it silently stopped applying as soon as OpenCode was started from
# somewhere else, and it shadowed the global config with an ancestor-level
# copy that a user could not easily reason about. Verified against the
# running service:
#   opencode api get /api/config
#     -> [{"type":"document","path":"...\\.config\\opencode\\opencode.json", ...},
#         {"type":"directory","path":"...\\.config\\opencode"}]
#
# One location, one source of truth, and it applies to every project.
home_dir = Path.home()
opencode_json_global = home_dir / ".config" / "opencode" / "opencode.json"
opencode_json_llm = script_dir / "opencode.json"

# The global config (what OpenCode actually reads) and a reference copy that
# lives with the project. The reference copy is NOT a second global config -
# it only takes effect if OpenCode is started inside this folder.
opencode_json_targets = [opencode_json_global, opencode_json_llm]

# Find all GGUF models
models = list(model_base.rglob("*.gguf"))
models.sort(key=lambda m: m.stat().st_mtime, reverse=True)

# Separate core models from mmproj files
selection_models = [m for m in models if not m.name.startswith("mmproj-")]

# Detect changes
#
# The hash must include the file SIZE as well as the name. With names alone,
# replacing a model with a different file of the same name (a re-quant, a
# different download, a different model reusing the filename) was completely
# invisible - the config was never regenerated.
#
# The relative path is included too, so moving a model between sub-folders is
# also detected. The mtime is deliberately NOT used: touching a file without
# changing it should not trigger a rebuild, and mtime is not stable across
# copies or downloads.
def model_fingerprint(path):
    """(relative path, size) for one model - stable across touches."""
    try:
        rel = path.relative_to(model_base).as_posix()
    except ValueError:
        rel = path.name
    try:
        size = path.stat().st_size
    except OSError:
        size = -1
    return f"{rel}:{size}"


current_hash = "|".join(model_fingerprint(m) for m in selection_models)
if hash_file.exists():
    last_hash = hash_file.read_text(encoding="utf-8").strip()
    if current_hash != last_hash:
        print("Models changed! Updating configuration...", file=sys.stderr)
else:
    print("First run! Building model list...", file=sys.stderr)

# --- BUILD opencode.json (single llama-server entity) ---
# We use a placeholder model so the provider actually shows up in the OpenCode GUI.
# The actual model selection is handled by the addLM script.
#
# IMPORTANT: `limit` and `capabilities` MUST be declared explicitly.
# OpenCode cannot introspect an OpenAI-compatible endpoint, so a model without
# them falls back to the built-in default of context=200000 / output=32000.
# With a 32k output allowance, OpenCode's usable window (context - output)
# becomes tiny, auto-compaction fires constantly, and the compaction summary
# request is what degenerates into a repeated-paragraph loop.
# See https://github.com/anomalyco/opencode/issues/44898 and issue #31433.
#
# The values below are written by addLM.ps1 from the real llama-server launch
# parameters. If they are missing, fall back to safe local-model defaults.
CONTEXT_LIMIT = 32768
OUTPUT_LIMIT = 4096

# Where to read the runtime limits from.
#
# By default this is opencode.runtime.json next to THIS script. It can be
# overridden with --runtime <path>, which context-sync.ps1 uses to point at
# the file it just wrote. Without the override the two can silently disagree:
# the runtime file is written to one folder while this script reads the one
# next to itself, and the generated limit ends up stale.
runtime_path = script_dir / "opencode.runtime.json"
if "--runtime" in sys.argv:
    _i = sys.argv.index("--runtime")
    if _i + 1 < len(sys.argv):
        runtime_path = Path(sys.argv[_i + 1]).expanduser()

try:
    # utf-8-sig tolerates a BOM, which Windows PowerShell 5.1 writes by default.
    _cfg = json.loads(runtime_path.read_text(encoding="utf-8-sig"))
    CONTEXT_LIMIT = int(_cfg.get("context", CONTEXT_LIMIT))
    OUTPUT_LIMIT = int(_cfg.get("output", OUTPUT_LIMIT))
    print(f"Using runtime limits: context={CONTEXT_LIMIT} output={OUTPUT_LIMIT} "
          f"(from {runtime_path})", file=sys.stderr)
except Exception as e:
    print(f"{runtime_path} not usable ({e}); using defaults "
          f"context={CONTEXT_LIMIT} output={OUTPUT_LIMIT}", file=sys.stderr)

# Added to the build/plan agents.
#
# Small local models sometimes try to reach a tool through OpenCode's `execute`
# tool with a Python import:
#     from tools["you-com"]["you-contents"] import you_contents
# The Code Mode runtime rejects that with "Unexpected token (1:5)" - the
# `from X import Y` form is not valid there. A model that gets this error tends
# to retry the same broken call rather than change strategy, which burns the
# whole step budget and ends with "unable to complete this task because the
# maximum number of steps allowed has been reached".
#
# Telling the model to emit a plain tool call avoids the failure mode entirely.
TOOL_USE_SYSTEM = (
    "When you need a tool, emit a normal tool call for it directly. "
    "Do not attempt to call tools from inside the `execute` tool with Python "
    "`from ... import ...` syntax - that form is not supported and fails with a "
    "syntax error. Never repeat a tool call that has already failed; if a tool "
    "errors, change your approach and try a different one."
)

opencode_content = {
    "$schema": "https://opencode.ai/config.json",
    "permission": {
        "websearch": "allow",
        "webfetch": "allow",
        # doom_loop fires when the same tool call repeats 3x with identical input.
        # The default is "ask", which does NOT protect unattended sessions, and
        # any config that sets a blanket "allow" also auto-approves it - so the
        # loop keeps running. "deny" is a hard circuit-breaker: the 3rd identical
        # call is blocked and the agent gets an error telling it to change
        # approach.
        # See https://github.com/anomalyco/opencode/issues/45442
        # and https://github.com/anomalyco/opencode/issues/43800
        "doom_loop": "deny",
    },
    "mcp": {
        "you-com": {
            "type": "remote",
            "url": "https://api.you.com/mcp?profile=free"
        }
    },
    # NOTE: the loop-guard plugin does NOT need an entry here.
    #
    # OpenCode auto-discovers plugins from the config directory
    # (~/.config/opencode/plugin/ and ~/.config/opencode/plugins/), so
    # addlm-loop-guard.js is picked up on its own. Adding a relative path to the
    # "plugins" array resolves it against %USERPROFILE% instead and produces a
    # duplicate entry that FAILS to load.
    #
    # To install it, copy scripts\plugins\addlm-loop-guard.js to
    # %USERPROFILE%\.config\opencode\plugin\ and restart OpenCode.
    # Verify with:  opencode api plugin.list  -> look for "addlm-loop-guard"
    # Compaction.
    #
    # Only `auto` is set. The previous `keep: {tokens: 8000}` + `buffer: 4096`
    # were a FIXED budget that clashed with the variable context size: with an
    # 8192-token context, keeping 8000 tokens plus a 4096 buffer is always
    # over budget, so compaction re-triggered after every step - exactly the
    # loop this project is fighting (see HANDOFF section 8).
    #
    # `keep` and `buffer` are optional in the schema, and OpenCode sizes the
    # retained tail against the model's actual usable input budget, which is
    # derived from the `limit` block below and therefore always correct.
    "compaction": {
        "auto": True
    },
    "agents": {
        # Bound the agentic loop. Without this a model that keeps calling the
        # same tool can iterate until the client gives up, which looks like a
        # frozen UI.
        #
        # NOTE: agent.steps is a SOFT limit in OpenCode - it injects a "stop
        # using tools" message but still passes the tools to the provider, and
        # non-Claude models routinely ignore it. It is a backstop, not the
        # primary defence - the primary defence is permission.doom_loop = deny.
        # See https://github.com/anomalyco/opencode/issues/3743
        "build": {
            "steps": 15,
            # Small local models sometimes try to reach MCP tools through
            # OpenCode's `execute` tool using a Python import
            # (`from tools["ns"]["name"] import fn`), which the Code Mode
            # runtime rejects with "Unexpected token (1:5)". The model then
            # retries the same broken call dozens of times. Telling it to emit
            # a plain tool call avoids the whole failure mode.
            # Observed in a real session - 42 identical failed calls.
            "system": TOOL_USE_SYSTEM,
        },
        "plan": {
            "steps": 15,
            "system": TOOL_USE_SYSTEM,
        },
        # The compaction agent gets its own budget. If the summary request
        # degenerates (a known OpenCode bug with smaller models), a lower
        # output budget makes it fail fast instead of streaming thousands of
        # duplicated lines. See https://github.com/anomalyco/opencode/issues/41801
        "compaction": {"steps": 4}
    },
    "providers": {
        "llama-server": {
            "name": "llama-server",
            "package": "aisdk:@ai-sdk/openai-compatible",
            "settings": {
                "baseURL": "http://127.0.0.1:8081/v1"
            },
            "models": {
                "active-model": {
                    "modelID": "local-model",
                    "name": "Active Local Model",
                    "capabilities": {
                        "tools": True,
                        "input": ["text"],
                        "output": ["text"],
                        "reasoning": {"supported": True}
                    },
                    "limit": {
                        "context": CONTEXT_LIMIT,
                        "output": OUTPUT_LIMIT
                    }
                }
            }
        }
    }
}

# --- WRITE (merge-on-write) -------------------------------------------------
#
# The config is MERGED into whatever is already on disk, never blindly
# overwritten. A blind write would silently destroy anything the user has
# configured themselves - other providers, extra models under a provider, MCP
# servers, agents, permissions.
#
# Merge rules:
#   * dicts are merged key-by-key (recursively)
#   * lists are REPLACED, not concatenated - otherwise the model list, the
#     permission rules and the agent list would grow on every run
#   * scalars are replaced
#
# This applies to the global config (which the user may have edited) as well
# as to the project copy.
#
# The one place a replace beats a merge is the `llama-server` provider: its
# `models` map must contain exactly the one placeholder model, otherwise a
# stale entry from an older run would keep advertising a model that is not
# being served. That provider is therefore rebuilt from scratch, while every
# OTHER provider the user has is preserved.
PROJECT_PROVIDER = "llama-server"

# Sub-trees this script OWNS. A merge preserves keys that the new config no
# longer sets, which is correct for the user's own settings but wrong for
# ours: when `compaction.keep` / `compaction.buffer` were removed, a plain
# merge would have kept the stale values forever. For an owned sub-tree the
# new value REPLACES the old one wholesale, so removals actually take effect.
#
# Everything NOT listed here is preserved from the on-disk config.
#
# `permission` is deliberately NOT owned: the project only sets three of the
# permission keys, and owning the block would delete any extra key (e.g.
# "bash": "ask") the user added. Merging it keeps both.
OWNED_PATHS = [
    ("compaction",),
    ("agents", "build"),
    ("agents", "plan"),
    ("agents", "compaction"),
]


def merge_config(base, incoming, owned_path=()):
    """Deep-merge `incoming` into `base`.

    Lists are replaced, not appended. If the current path is owned, the
    incoming value replaces the base value entirely.
    """
    if not isinstance(base, dict) or not isinstance(incoming, dict):
        return incoming
    if owned_path in OWNED_PATHS:
        return incoming
    result = dict(base)
    for key, value in incoming.items():
        child_path = owned_path + (key,)
        if (key in result and isinstance(result[key], dict)
                and isinstance(value, dict) and child_path not in OWNED_PATHS):
            result[key] = merge_config(result[key], value, child_path)
        else:
            result[key] = value
    return result


def read_json(path):
    """Read a JSON config, tolerating a BOM, an empty file and a broken file."""
    if not path.exists():
        return {}
    try:
        text = path.read_text(encoding="utf-8-sig").strip()
    except Exception:
        return {}
    if not text:
        return {}
    try:
        data = json.loads(text)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def build_final(existing):
    """Merge the generated config over the on-disk config."""
    merged = merge_config(existing, opencode_content)
    # Rebuild our own provider so no stale model survives.
    merged["providers"] = dict(merged.get("providers", {}))
    merged["providers"][PROJECT_PROVIDER] = opencode_content["providers"][PROJECT_PROVIDER]
    return merged


for target in opencode_json_targets:
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        existing = read_json(target)
        final = build_final(existing)
        with open(target, "w", encoding="utf-8") as f:
            json.dump(final, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"Wrote {target}", file=sys.stderr)
    except Exception as e:
        print(f"Error writing to {target}: {e}", file=sys.stderr)

# Save hash
hash_file.write_text(current_hash, encoding="utf-8")

# If --generate-only flag is passed, exit without launching
if "--generate-only" in sys.argv:
    print("opencode.json generated successfully!", file=sys.stderr)
    sys.exit(0)

# This script is only for generating config. Model selection and launch is in addLM.ps1
print("Configuration generated. Use addLM.ps1 or addLM.bat to select and launch a model.", file=sys.stderr)
