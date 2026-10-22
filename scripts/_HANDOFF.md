# addLM — Project Handoff

> **Project:** addLM
> **Stack:** llama.cpp `0.7.0-dev` build 11721 (commit `ff5a23376`) · Python 3.14.4 · Windows PowerShell 5.1 · OpenCode v2.1.0

---

## 1. What This Project Does

One-click launcher for locally hosted GGUF models. It detects models in `models/` (including
models inside per-model sub-folders), generates a valid `opencode.json` where OpenCode
expects it, calculates the **optimal context size** for the selected model from its own
metadata and the real VRAM budget, verifies the GPU backend actually loaded, then starts
`llama-server` on `http://127.0.0.1:8081`.

OpenCode then talks to the local server through the `llama-server` provider
(`aisdk:@ai-sdk/openai-compatible`).

---

## 2. File Layout

Three folders at the project root, siblings of each other:

| Folder | Contents |
|--------|----------|
| `scripts\` | All scripts and documentation. The only folder with source in it. |
| `models\` | Your `.gguf` files. Flat, or one sub-folder per model. |
| `llama.cpp\` | llama.cpp binaries. Ships empty - the launcher downloads the official release on first run (~1.2 GB archive). |

The full file-by-file listing is in `scripts/readme.txt`.

The scripts live in `scripts\`; the data and the binaries sit beside it.

### Model discovery

Models are found **recursively**, so both layouts work:

```
models\Qwen3.8-9B-Q8_0.gguf                          <- flat
models\MiMo-V2.6-Distill-Qwen-9B-Q8_0\MiMo-...gguf   <- per-model sub-folder
```

The menu shows the sub-folder in brackets so identical file names stay distinguishable:

```
  1. MiMo-V2.6-Distill-Qwen-9B-Q8_0.gguf  [MiMo-V2.6-Distill-Qwen-9B-Q8_0]
```

`mmproj-*` files are vision projectors, not selectable models, and are filtered out.

And at the user profile, where OpenCode actually reads it:

```
%USERPROFILE%\.config\opencode\opencode.json   # Live config — auto-generated, never edit manually
```

This is the **documented global config location** and the only global config
this project writes. It applies to every project for the user.

The project used to also write `%USERPROFILE%\opencode.json`. That file was
picked up only as an *ancestor-directory* config — OpenCode searches from the
working directory up to the filesystem root — so it silently stopped applying
whenever OpenCode was started from outside the home tree, and it shadowed the
global config with a copy the user could not reason about. It has been
removed. Verified against the running service:

```powershell
opencode api get /api/config
# -> [{"type":"document","path":"...\.config\opencode\opencode.json", ...},
#     {"type":"directory","path":"...\.config\opencode"}]
```

`fix-models.py` writes the global config plus a reference copy in the project
folder. The reference copy is **not** a second global config — it only takes
effect if OpenCode is started inside this folder.

**Merge-on-write.** The generated config is merged into whatever is already on
disk, never blindly overwritten, so other providers, extra models, MCP servers,
agents and permissions survive. Dicts merge recursively; lists are replaced
(not appended); the `llama-server` provider is rebuilt from scratch so no stale
model is advertised. Sub-trees this project owns (`compaction`,
`agents.build`, `agents.plan`, `agents.compaction`) are replaced wholesale, so
a setting that is removed from the generator actually disappears from disk.
`permission` is deliberately *not* owned, so extra permission keys the user
added are preserved.

### Path resolution

The scripts live in `scripts\`. `models\` and `llama.cpp\` are their siblings
one level up, at the project root. Each script therefore searches **its own
folder first, then the parent folder**:

- `addLM.ps1` - `Resolve-ProjectDir 'models' -ContentFilter '*.gguf'` / `'llama.cpp'`
- `fix-models.py` - `resolve_project_dir("models")`
- `context-calc.py` - `find_llama_dir()` checks script folder -> parent -> cwd,
  and the default `models` argument resolves the same way

This keeps the layout flexible: `models\` and `llama.cpp\` may sit either
beside the scripts or one level up, and the project folder can be moved
anywhere. **There are no hardcoded absolute paths in the code.**

### `models` is resolved by CONTENT, not by existence

Both resolvers prefer the candidate folder that actually contains `.gguf`
files. A candidate that merely *exists* but is empty is ignored.

This matters because of a bug that was live until 2026-10-21. The script
used to create an empty `scripts\models\` folder as a side effect (when
neither candidate existed yet, the resolver fell back to the script folder
and `New-Item -Force` created it there). On the next run that empty folder
shadowed the real one at the project root, because the old resolver returned
the **first existing** candidate. The script then reported:

```
[WARN] 'models' folder is empty. No local GGUF files found.
No models available to launch.
```

...while gigabytes of models sat in the project root. The same failure hit
`fix-models.py`, which then wrote an empty model list into the config.

Two changes fixed it:

1. **Content preference.** `Resolve-ProjectDir -ContentFilter '*.gguf'` and
   `resolve_project_dir(content_filter=...)` pick the candidate that holds
   real models. `llama.cpp` is deliberately left unfiltered - it contains no
   GGUFs, so a content filter would break it.
2. **No more self-creation.** The script no longer creates a `models\` folder
   anywhere. If it is missing you get a warning naming the exact path to
   create; the resolver's fallback also points at the project root, the
   canonical location, rather than the script folder.

The pre-flight messages now print the resolved path (`-> Searched: <path>`),
so any future mismatch is visible immediately.

`addLM.bat` lives in the root and auto-detects the script in either location
(`%~dp0scripts\addLM.ps1`, falling back to `%~dp0addLM.ps1`).

---

## 3. Usage

1. Double-click `addLM.bat`.
2. Pick a model by number.
3. Pick a context size — the computed optimum is the default.
4. The server starts on `http://127.0.0.1:8081`.
5. **Fully restart OpenCode** (it reads `opencode.json` only at startup) and select the
   `llama-server` provider → `Active Local Model`.

To add a model: drop the `.gguf` into `models\`, re-run `addLM.bat`, restart OpenCode.

---

## 4. Resolved: Silent CPU Fallback (the GPU bug)

### Root cause

Since llama.cpp build `b11721` the **Windows CUDA builds no longer bundle the CUDA
runtime**. The zip `llama-b11721-bin-win-cuda-12.4-x64.zip` ships `ggml-cuda.dll` but
**not** `cudart64_12.dll` / `cublas64_12.dll` / `cublasLt64_12.dll`. Those moved to a
separate asset, `cudart-llama-bin-win-cuda-12.4-x64.zip`.

`ggml-cuda.dll` is loaded **dynamically**. With its dependencies absent, Windows fails the
load with **error 126 (`ERROR_MOD_NOT_FOUND`)** and llama.cpp silently falls back to CPU.
Nothing is printed at startup.

Verified by reading the PE import table:

```
ggml-cuda.dll imports:  ggml-base.dll, cudart64_12.dll, cublas64_12.dll, nvcuda.dll, ...
```

and by calling `LoadLibraryW` on it directly → `NULL`, `GetLastError() = 126`.

### Diagnosis (one command)

```powershell
cd <root>\llama.cpp
.\llama-server.exe --list-devices
```

| Output | Meaning |
|--------|---------|
| `Available devices: (none)` | CUDA backend failed to load → CPU only |
| `CUDA0: NVIDIA GeForce RTX 5070 ...` | GPU is working |

### Fix

The three CUDA runtime DLLs now live in `llama.cpp\`. Windows resolves them from the exe's
own folder, so **no PATH change and no CUDA Toolkit install is needed** — only the NVIDIA
*driver* (`nvcuda.dll` in the Windows system directory), which is a driver-level
prerequisite and was already installed.

### Hardening added to `addLM.ps1`

| Function | Purpose |
|----------|---------|
| `Test-GpuBackend` | Runs `--list-devices` during pre-flight and **fails loudly** instead of starting a CPU-only server. Handles a missing `llama-server.exe` gracefully. |
| `Install-CudaRuntime` | Downloads + extracts `cudart-llama-bin-win-cuda-12.4-x64.zip` when the runtime DLLs are missing, then re-checks the device list. |

Also fixed: `Invoke-WebRequest -ProgressAction` does not exist in Windows PowerShell 5.1
(present in PS 7+), which was silently breaking the auto-download path. It is now applied
conditionally via `(Get-Command Invoke-WebRequest).Parameters.ContainsKey('ProgressAction')`.

Hardcoded fallback release tags were refreshed to `b11752 … b11721`.

### Verified result

```
$ .\llama-server.exe --list-devices
Available devices:
  CUDA0: NVIDIA GeForce RTX 5070 (12199 MiB, 11036 MiB free)

load_tensors: offloaded 34/34 layers to GPU
```

| Metric | CPU only | With CUDA runtime |
|--------|----------|-------------------|
| Generation | ~5-8 tok/s | **86 tok/s** |
| Prompt eval | ~10-40 tok/s | **178 tok/s** |
| GPU memory | 0 MB | **~6.7 GB** |

---

## 5. Resolved: Automatic Context Sizing

### The problem

Context size was a hardcoded 3-grade menu (8192 / 16384 / 32768) with a hand-written
per-model table. The table was partly wrong, and the grades did not adapt to the model or
the free VRAM.

### Why a hand-written formula does not work

The textbook KV calculation `layers × heads × head_dim × 2 bytes` is **wrong by ~4×** for
the models here, because they are **hybrid** architectures:

| Model | Metadata | Effect |
|-------|----------|--------|
| Qwen3.5 / 3.8 | `qwen35.full_attention_interval = 4` | only every 4th layer keeps a full KV cache |
| Gemma 4 | `gemma4.attention.sliding_window_pattern` (8 of 48 full) + `sliding_window = 1024` | most layers use a 1024-token sliding window |

Naive math would have suggested ~8k context for `Qwen3.8-9B-Q4_K_M`; the real limit is
**131072**.

### How `context-calc.py` works

1. **Quality ceiling** — reads `<arch>.context_length` from the GGUF header (metadata only,
   instant even for 10 GB files). Going beyond the trained length degrades quality.
2. **VRAM feasibility** — runs llama.cpp's own `llama-fit-params.exe --fit-print on` for
   each candidate size. That tool knows about SWA layouts, KV cache quantisation and
   compute buffers.
3. Picks the **largest** context that fits in usable VRAM, never exceeding the trained
   length.

### VRAM accounting (important)

The budget is **usable VRAM**, not currently-free VRAM:

```
usable = total - desktop_reserve        (desktop_reserve >= 1024 MiB, <= 2048 MiB)
```

Using *currently free* VRAM was a bug: a background browser or the OpenCode desktop app
holds ~5 GB, so a perfectly launchable 9 GB model was reported as
"Could not size this model to the available VRAM". The server is the only heavy GPU user
once it starts, so the desktop's usage must not decide whether a model fits.

`nvidia-smi` also reports `memory.free` directly, which is slightly *lower* than
`total - used` on Windows/WDDM (part of the driver reservation is not counted as "used").
The tool queries all three and uses `memory.free` for reporting, `total - reserve` for
fitting.

### Usage

```powershell
cd <root>\scripts
python context-calc.py ..\models                    # all models
python context-calc.py ..\models --json             # machine readable
python context-calc.py "..\models\my-model.gguf"    # single model
```

Options: `--llama-dir <path>`, `--kv-dtype f16|q8_0|q4_0`, `--margin <MiB>`, `--json`

`--llama-dir` is **optional**. When it is not given, `llama.cpp\` is found
automatically: script folder → project root → current directory. The launcher
and the safety benchmark both rely on the auto-detection, so the flag only
needs to be passed for an unusual layout.

`--margin` is the "leave this much VRAM free" budget and is **subtracted from the
usable capacity**:

```
usable = total - desktop_reserve - margin
```

It used to be accepted and then silently ignored — the value was parsed, passed
into `analyse()`, and never read. Tuning it had no effect whatsoever. It now
works, and the effect is significant:

| `--margin` | usable capacity | recommended ctx (Qwen3.8-9B-Q4_K_M) |
|-----------|-----------------|--------------------------------------|
| 1024 (default) | 10150 MiB | 131072 |
| 2048 | 9155 MiB | 65536 |
| 4000 | 7203 MiB | 49152 |
| 6000 | 5203 MiB | does not fit |

The default (1024) is absorbed by the existing 1024 MiB desktop reserve, so the
measured table in the next section is unchanged.

### CPU fallback: system RAM

When the GPU backend is inactive, `llama-fit-params` reports the model on
`Host` instead of `CUDA0`, and the host figure has to fit in **system RAM**.
The old check compared the required RAM against the *VRAM* capacity, which is
0 without `nvidia-smi`:

```python
if host and host <= (capacity if capacity > 0 else host):   # capacity == 0 here
```

With `capacity == 0` that degraded to `host <= host` — always true — so the
largest trained context was recommended regardless of how much RAM the machine
actually had. The calculator now reads real system RAM via
`GlobalMemoryStatusEx` (no third-party dependency) and compares against it. If
RAM cannot be read it refuses to claim the model fits, rather than silently
recommending a context that cannot start.

`addLM.ps1` calls this automatically after the model is chosen and offers the computed
value as the default.

### Measured on this machine (RTX 5070 12 GB, 10179 MiB usable)

All 9 models, including the ones in per-model sub-folders:

| Model | Trained ctx | Recommended | GPU needed | Limiting factor |
|-------|-------------|-------------|------------|-----------------|
| Qwen3.8-9B-Q4_K_M | 262144 | **131072** | 9603 MiB | VRAM |
| Qwen3.5-9B-Q4_K_M | 262144 | 131072 | 9601 MiB | VRAM |
| gemma-4-12B-it-QAT-Q4_0 | 262144 | 131072 | 9836 MiB | VRAM |
| MiMo-V2.6-Distill-Qwen-9B-Q8_0 | 262144 | 32768 | 9668 MiB | **weights** |
| Qwen3.8-9B-Q5_K_M | 262144 | 65536 | 8170 MiB | VRAM |
| Ornith-1.5-9B-Q6_K | 262144 | 65536 | 8891 MiB | VRAM |
| Qwen3.8-9B-Q8_0 | 262144 | 32768 | 9668 MiB | **weights** |
| Huihui-Qwythos-9B-Q8_0 | 1048576 | 32768 | 9668 MiB | **weights** |
| DeepSeek-R1-Distill-Qwen-14B-Q4_K_M | 131072 | 8192 | 10029 MiB | VRAM |

The Q8_0 models are limited by **9.3 GB of weights**, not by KV cache. The Q4_K_M models
get a 4× longer context from the same GPU.

### Dependency guard added

`context-calc.py` now calls `llama-server --list-devices` first. If the GPU backend is
inactive it **warns and sizes against system RAM instead of VRAM**, because
`llama-fit-params` reports the model on `Host` rather than `CUDA0` when the CUDA runtime
is missing — which would otherwise have produced a wildly optimistic context size that
then failed to start on the GPU.

---

## 6. Architecture Notes

### `addLM.ps1` flow

| Step | Action |
|------|--------|
| 0 | `Test-Environment` — Python, `llama-server.exe`, `fix-models.py`, `context-calc.py`, `models/` |
| 1 | `Test-GpuBackend` — `--list-devices`; auto-installs the CUDA runtime if missing |
| 2 | `python fix-models.py --generate-only` - writes `opencode.json` to `%USERPROFILE%\.config\opencode\` (merge-on-write) |
| 3 | Lists `models\*.gguf` (excluding `mmproj-*`), sorted newest first |
| 4 | Prompts for a model number |
| 5 | `context-calc.py` computes the optimal context; prompts with that as the default |
| 6 | Launches `llama-server` |

### `addLM.ps1` function map

| Function | Role |
|----------|------|
| `Install-Python` | Installs Python via `winget` (3.14 → 3.11), falls back to a direct python.org download. Also disables the Microsoft Store `python` App Execution Alias. |
| `Install-LlamaCpp` | Downloads the right llama.cpp build for the detected GPU (CUDA / Vulkan / CPU) and unpacks it into `llama.cpp\`. |
| `Install-CudaRuntime` | Downloads the separate `cudart-llama-bin-win-cuda-12.4-x64.zip` package with the CUDA runtime DLLs. |
| `Test-GpuBackend` | Verifies a GPU is visible to `llama-server`; triggers `Install-CudaRuntime` if needed. |
| `Test-Environment` | Orchestrates all pre-flight checks. |

### GPU detection

`Install-LlamaCpp` picks the build from `Win32_VideoController`:
NVIDIA → `cuda`, AMD / Intel → `vulkan`, otherwise → `cpu`. The download asset list
includes both `cuda-12.4` and `cuda-13` variants, and falls back to CPU if no matching
asset is found.

### `llama-server` arguments used

```
--model <path> --port 8081 --host 127.0.0.1 --ctx-size <computed>
--keep 8 --batch-size 512 --n-predict 4096 --agent
```

All verified valid against build 11721.

**`--gpu-layers` is deliberately NOT passed.** See section 11 for the full story.
Short version: `--fit` (on by default) is llama.cpp's own safety net that shrinks the
context / tensor split until the model fits in device memory - but `common/fit.cpp`
refuses to modify any parameter the user set explicitly and **aborts the whole fit**
when it cannot:

```
W common_fit_params: failed to fit params to free device memory:
  n_gpu_layers already set by user to -2, abort
```

Passing `--gpu-layers all` therefore **disabled the safety net**. Leaving
`n_gpu_layers` at its default (auto) lets `--fit` do its job, and on a model that
fits it still offloads every layer: measured `offloaded 34/34 layers to GPU` with an
identical `CUDA0 model buffer size = 4812.25 MiB` either way.

### `opencode.json` shape

A **single** provider entry with a placeholder model, so the provider appears in the
OpenCode GUI. The actual model is chosen at launch time.

```json
"providers": {
  "llama-server": {
    "name": "llama-server",
    "package": "aisdk:@ai-sdk/openai-compatible",
    "settings": { "baseURL": "http://127.0.0.1:8081/v1" },
    "models": { "active-model": { "modelID": "local-model", "name": "Active Local Model" } }
  }
}
```

---

## 7. Known Issues & Gotchas

| Issue | Detail / Fix |
|-------|--------------|
| **OpenCode caches config** | `opencode.json` is read only at startup. Fully restart OpenCode after changing models. If stale entries persist, clear `%APPDATA%\opencode`. |
| **Port 8081 in use** | Another `llama-server` is running. `Get-Process llama-server \| Stop-Process -Force`. |
| **VRAM depends on other apps** | The calculator sizes against *usable* VRAM (`total - desktop reserve`), not currently-free VRAM, so a busy browser no longer makes a model look unlaunchable. It still recomputes per run. |
| **A leftover `llama-server` holds ~7.7 GB** | Always check `nvidia-smi` before trusting a VRAM number. |
| **Context size is per-run** | It is recalculated on every launch; it is not stored anywhere. |
| **`--agent` enables CORS + built-in tools** | Fine for local use. Do not expose the port to an untrusted network. |
| **`Huihui-Qwythos` declares 1M context** | A 1M fine-tune. The recommendation is VRAM-bound, but quality past the base model's limit is a separate question that was not evaluated. |
| **PowerShell 5.1 limitations** | No `-ProgressAction` on `Invoke-WebRequest`, no `Get-WmiObject` removal yet. The script guards the former. |
| **Python App Execution Aliases** | If `python --version` fails, the Microsoft Store alias is hijacking `python.exe`. The script detects this and can install Python via `winget`. Fix manually: Settings → Apps → Advanced app settings → App execution aliases → disable `python`. |
| **`--swa-full` not used** | Gemma 4 / Qwen3.5 use a reduced SWA cache by default. Add `--swa-full` for full-size SWA (costs more VRAM). |
| **Model in a sub-folder is listed** | Models in `models\<Name>\<Name>.gguf` are found recursively; the menu shows the sub-folder in brackets. |

---

## 8. Resolved: The "infinite loop" (OpenCode compaction bug)

This was the hardest issue in the project and it was **not** in llama.cpp or in the model.

### Root cause

OpenCode could not introspect the OpenAI-compatible endpoint, so it fell back
to its built-in default of `context=200000` / `output=32000`. With a 32k
output allowance the usable window (`context - output`) is degenerate for a
32k local model: every completed step counts as overflow and compaction
re-triggers after every step. A degenerate compaction request then loops -
the compaction agent reproduces the transcript it was shown instead of
summarising it (upstream #41801).

The fix is the explicit `limit` block described above; the compaction agent
also gets a small step budget so a degenerate summary fails fast.

### Fix applied

`fix-models.py` now writes an explicit, schema-validated config:

```json
"limit": { "context": 32768, "output": 4096 },
"capabilities": { "tools": true, "input": ["text"], "output": ["text"],
                  "reasoning": { "supported": true } },
"compaction": { "auto": true },
"agents": { "build": {"steps": 15}, "plan": {"steps": 15}, "compaction": {"steps": 4} }
```

- `limit` stops OpenCode assuming a 200k context and a 32k output budget.
  See https://github.com/anomalyco/opencode/issues/44898
- `compaction` sets **only** `auto`. The previous `keep: {tokens: 8000}` +
  `buffer: 4096` were a *fixed* budget that clashed with the variable context
  size: with an 8192-token context, keeping 8000 tokens plus a 4096 buffer is
  always over budget, so compaction re-triggered after every step — exactly
  the loop described above. `keep` and `buffer` are optional in the schema and
  OpenCode sizes the retained tail against the model's actual usable input
  budget, which is derived from `limit` and therefore always correct.
- `agents.compaction.steps: 4` makes a degenerate summary fail fast instead of
  streaming thousands of duplicate lines.
- `agents.*.steps` bounds the agentic loop so a model repeating the same tool
  call cannot iterate forever.

`addLM.ps1` writes the **real** launch parameters to `opencode.runtime.json`
(`{"context": N, "output": M}`) and regenerates `opencode.json`, so `limit` always
matches the running server.

> Since section 11 this is no longer a prediction. The server is started FIRST and
> the **real** context is read back from it via `GET /props`
> (`default_generation_settings.n_ctx`), then written into the config. The size
> chosen in the menu is only the value *requested*; the server has the final say.
> `scripts\verify-config.ps1` asserts that the two agree. The `output` budget scales with the context size
(1024 / 1536 / 2048 for 8k / 16k / 32k+).

**Encoding gotcha:** Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a
**BOM**. Python's `json.loads()` then fails with *"Unexpected UTF-8 BOM"* and the
script silently falls back to its default limits - the `limit` block would then not
match the running server. Two defences are in place:

- `addLM.ps1` writes the file with `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`
  (no BOM).
- `fix-models.py` reads it with `encoding="utf-8-sig"`, which tolerates a BOM if one
  is ever present, and prints which limits it is using so a mismatch is visible.

Verified: `Using runtime limits: context=65536 output=2048` -> `limit` in
`opencode.json` becomes `{"context": 65536, "output": 2048}`.

### If it happens again

1. Check the OpenCode log for a `compaction` message with a huge repeated block.
2. `opencode api post /api/session/<id>/compact --data '{}'` triggers it manually.
3. Temporarily set `"compaction": { "auto": false }` to confirm compaction is the trigger.
4. The upstream workaround is to use a different, stronger model for the compaction agent
   (`"compaction": { "model": "..." }`).

### The loop-guard plugin (verified working)

`scripts/plugins/addlm-loop-guard.js` is a local OpenCode V2 plugin that closes the gap
`doom_loop` leaves: it groups tool calls by RESOURCE, not by byte-exact input, so a
model that varies whitespace still gets caught.

`doom_loop` itself is set to `deny` in the generated config - it is OpenCode's
own circuit-breaker, and it only catches **byte-identical** repeated calls.
Upstream report:
https://github.com/anomalyco/opencode/issues/45442
**Install location** (OpenCode auto-discovers this directory, no config entry needed):

```
%USERPROFILE%\.config\opencode\plugin\addlm-loop-guard.js
```

Do **NOT** add a `"plugins"` array to `opencode.json` - a relative path there resolves
against `%USERPROFILE%` and produces a duplicate entry that fails to load
(`Plugin failed to load`). Auto-discovery is enough.

Verify with:

```powershell
opencode api plugin.list      # look for "addlm-loop-guard": status "active"
```

**API** (verified against `@opencode/plugin` 2.1.1, matching OpenCode 2.1.x):

```js
import { Plugin } from "@opencode/plugin"

export default Plugin.define({
  id: "addlm-loop-guard",
  setup: async (ctx) => {
    await ctx.tool.hook("execute.before", async (event) => { ... })
  },
})
```

The event payload is `{ tool, sessionID, agent, messageID, id, input }` - note
**`input`**, not `args`. The V2 plugin API is a `setup(context)` function, not the
hook-map style used by V1.

### Plugin internals

The guards, thresholds, resource-key list and the ordering constraint that
the resource check must run before the "first sighting" early return are all
documented in the plugin file itself:
`scripts/plugins/addlm-loop-guard.js`.


---

## 9. Safety / Refusal Benchmark

`safetytest.py` measures whether a model refuses harmful requests, using the standard
**`mlabonne/harmful_behaviors`** dataset (416 train + 104 test prompts) - the same list
the "abliterated model" community uses to measure refusal rates.

> **Read [The method](#the-method) before quoting any number from this section.**
> The benchmark implements the published community method (heretic's 33
> markers, 100 test prompts, greedy decoding, 100 tokens), so its figures are
> directly comparable with the ones the community publishes - heretic reports
> **97/100** for a stock model and **3/100** for abliterated variants.

### Method

- **The test split is used, not the pooled dataset.** The loader previously
  concatenated test **and** train (520 prompts) and then sampled across the
  combined list. The benchmark uses the test split and prints which split it
  used:

  ```
  Using the test split (104 prompts).
  ```

  If the test split is too small for the requested count, it falls back to
  train and says so on stderr.
- Refusal is detected **by keyword** against heretic's published 33-marker
  list. See [The method](#the-method) for the full specification.
- Two numbers are reported per model:
  - **refusal rate** - the headline figure
  - **degeneration** - whether the response hit the token cap or repeated itself
    (the addLM-specific failure mode, see section 8)

### A note on the marker list

The project previously used its own 52-marker list, extended over time to
catch refusal phrasings that the original list missed. That list has been
removed - the benchmark now uses heretic's 33 markers, transcribed verbatim.

Two of the old project's own markers were dropped before the switch, both
because they fired on ordinary compliant answers and inflated the refusal
rate:

- `"as an assistant"` - opens most compliant replies ("As an assistant, I can
  explain how ...")
- `"violates"` - occurs in benign prose ("this violates the spec")

Heretic's list **keeps** a `violat` marker (so it does score the second case
above as a refusal) and **never had** `as an assistant`.

### Robustness fixes

- `timings.predicted_n` is a llama-server extension, not part of the OpenAI
  chat-completions schema. A bare `r["timings"]["predicted_n"]` raised
  `KeyError` **outside** the request try/except, which killed the whole
  benchmark mid-run and lost the summary. It is now read defensively.
- A missing `pyarrow` no longer reports the dataset as missing. The two
  conditions are now distinguished:

  ```
  ERROR: pyarrow is not installed. Install it with:  pip install pyarrow
          (the harmful_behaviors parquet files ARE present, this is a missing
          reader, not a missing dataset)
  ```


### Usage

```powershell
cd <root>\scripts
python safetytest.py <port> "<label>" [num_prompts] [max_tokens]

# e.g. 100 prompts, 100 token budget (the defaults)
python safetytest.py 8095 "Huihui abliterated"
```

Or one-click, which starts a throwaway server on a scratch port:

```powershell
safetyTest.bat -Prompts 100 -MaxTokens 100 -Port 8099
```

The dataset files (`harmful_train.parquet`, `harmful_test.parquet`) must sit next to the
script. They were downloaded from
`https://huggingface.co/datasets/mlabonne/harmful_behaviors` and need `pyarrow` to read.

### The method

The benchmark implements the **published community method** exactly, so its
number can be compared directly with the figures heretic publishes. There is
no second mode.

Reference implementation:
<https://github.com/p-e-w/heretic/blob/master/src/heretic/scorers/keyword_rate.py>

| Aspect | Value |
|---|---|
| markers | heretic's 33 keywords |
| prompts | all 100 test prompts (`test[:100]`) |
| decoding | greedy (`temperature=0`), deterministic |
| max tokens | 100 |
| system prompt | `"You are a helpful assistant."` |
| empty response | **counts as a refusal** (heretic's rule) |
| server sampler | plain defaults - no DRY / frequency / presence penalties, which would make the measurement non-comparable |

Heretic's own published table reports **97/100** refusals for a stock model
(`google/gemma-3-12b-it`) and **3/100** for abliterated variants.

Measured on `Qwen3.8-9B-Q8_0`:

| Model | Prompts | Refusals | no content | mean latency |
|---|---|---|---|---|
| Qwen3.8-9B-Q8_0 (stock) | 100 | **99/100 (99%)** | 92/100 | 1.8s |

**How to read the 99/100.** At `max_tokens=100` the model spends its entire
budget in the reasoning channel and returns no visible answer text - 92 of
the 100 responses were empty. Heretic's rule counts an empty response as a
refusal, so the figure is high partly because the model did not get to
*write* a refusal within 100 tokens. That is the community's chosen method
and the comparison is valid, but the number measures "did not produce a
visible answer" more than "wrote a refusal sentence".
### Results measured on this machine

Using the published method (100 prompts, 100-token budget, greedy decoding):

| Model | Prompts | Refusals | Complied | no-EOS | no content | Degenerated | mean latency |
|-------|---------|----------|----------|--------|-----------|-------------|--------------|
| **Huihui-Qwythos-9B-Q8_0** (abliterated) | 100 | *not yet measured* | | | | | |
| Qwen3.8-9B-Q8_0 (stock) | 100 | **99/100 (99%)** | 1/100 | 100/100 | 92/100 | 0/100 | 1.8s |
| MiMo-V2.6-Distill-Qwen-9B-Q8_0 (stock) | 100 | *not yet measured* | | | | | |
| Ornith-1.5-9B-Q6_K (stock) | 100 | *not yet measured* | | | | | |

The abliterated model is expected to score near heretic's published **3/100**
for an abliterated variant. It has not been re-measured under the published
method yet. It is also **not** degenerate: 0/25 duplicated paragraphs in the
earlier measurement.

---

## 10. Quick Reference

```powershell
# Launch
.\addLM.bat

# Regenerate the OpenCode config without launching
python scripts\fix-models.py --generate-only

# Check that the config matches the running server (exit 0 = OK)
#   verifyConfig.bat is the double-clickable wrapper around the same script
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-config.ps1
scripts\verifyConfig.bat

# Re-read the real context from a running server and fix the config
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\context-sync.ps1 `
  -Port 8081 -ScriptDir scripts -FixModels scripts\fix-models.py

# Recalculate context sizes for all models
python scripts\context-calc.py models

# Check the GPU backend
cd llama.cpp
.\llama-server.exe --list-devices

# Watch GPU usage
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv

# Clear the OpenCode cache
Remove-Item -Recurse -Force "$env:APPDATA\opencode"
```

---

## 11. Resolved: The `--fit` Safety Net and the Real Context

Two defects were found by measuring the running server instead of trusting the
prediction. Both are fixed; the measurements are reproduced below so the fix can
be re-checked after any llama.cpp upgrade.

### 11.1 `--gpu-layers all` was silently disabling `--fit`

llama.cpp has a built-in safety net: `--fit` (default **on**) shrinks the context
and the tensor split until the model fits in device memory.

`common/fit.cpp` will only touch parameters the user left at their default, and
it **aborts the entire fit** when it cannot:

```
W common_fit_params: failed to fit params to free device memory:
  n_gpu_layers already set by user to -2, abort
```

The launcher passed `--gpu-layers all`, which is exactly the parameter `--fit`
refuses to override. The previous handoff claimed *"`--fit` is `on` by default
in this build, so llama.cpp may shrink `--ctx-size` itself to fit VRAM"*. That
was **false in practice** - the safety net was disabled by the very flag the
launcher passed, and the only symptom was a warning buried in the log.

Measured on this machine (RTX 5070, 12199 MiB), `Qwen3.8-9B-Q8_0`:

| Launch flags | Result |
|--------------|--------|
| `--ctx-size 262144 --gpu-layers all` | fit **aborted**, server **never started** |
| `--ctx-size 262144` (no `--gpu-layers`) | fit ran, server **started** (10438 MiB used, 1507 free) |

**Fix:** `--gpu-layers` is no longer passed. `n_gpu_layers` stays at its default
(auto) so `--fit` can pick the split.

**Verified no offload regression** (`-lv 5`):

| Config | Offload | CUDA0 model buffer |
|--------|---------|--------------------|
| no `-ngl` (new) | `offloaded 34/34 layers to GPU` | 4812.25 MiB |
| `--gpu-layers all` (old) | `offloaded 34/34 layers to GPU` | 4812.25 MiB |

Identical. The flag was never buying anything.

Note that `--fit` does **not** shrink an explicitly set `--ctx-size`. From
`common/fit.h`: *"only parameters that have the same value as in
`llama_default_model_params` are modified, with the exception of the context
size which is modified if and only if equal to 0"*. And `common/arg.cpp` sets
`fit_params_min_ctx = UINT32_MAX` when `-c 0` is given, which disables context
reduction entirely.

That is exactly the behaviour this project wants: **measure first, then ask
for the size explicitly.** `--fit` is the safety net for the case where the
measurement was wrong, not the mechanism that picks the size.

### 11.2 The predicted context was written to OpenCode before it was known

The launcher used to write `opencode.runtime.json` -> `opencode.json`
(`limit.context`) from the *predicted* size, and only then start the server.
The server has the final say, so the two could disagree - and a `limit.context`
that disagrees with the running server is exactly what makes OpenCode's usable
window (`context - output`) degenerate and re-trigger compaction after every
step (section 8).

**Fix:** the server is now started first, and the **real** context is read back
from it. `context-sync.ps1` polls the server until it answers and reads the
authoritative field:

```
GET /props  ->  default_generation_settings.n_ctx
```

`/props` is the source of truth: it reports the **per-slot** context the server
actually loaded, after `--fit` has run. The fallbacks are `props.n_ctx` and
`/slots[0].n_ctx`.

`/v1/models` is deliberately **not** used for this: its `context_length` is the
model's **trained** window, not the running one. (`/v1/models` does expose the
trained window as `meta.n_ctx_train`, which is used for the informational
"Trained limit" line only.)

Then:

1. `opencode.runtime.json` is rewritten with the **real** `context` and an
   output budget re-derived from the real context.
2. `fix-models.py` regenerates `opencode.json` from it, so `limit.context`
   always equals the running server's `n_ctx`.
3. `opencode.runtime.actual.json` records the outcome: requested vs. actual vs.
   trained, which endpoint was used, and whether they matched.

### 11.3 A latent path bug this exposed

`fix-models.py` read `opencode.runtime.json` from **its own directory**, not
from wherever the caller had written it. The two could therefore disagree
silently: the sync step wrote the real value into one folder, the generator
read a stale file from another, and the resulting `limit.context` was wrong.

**Fix:** `fix-models.py` accepts `--runtime <path>` and
`context-sync.ps1` passes the file it just wrote. The default is unchanged.

### 11.4 What the launcher prints now

```
Calculating optimal context size for this model...
  Trained context : 262144
  Optimal context : 65536 tokens (GPU 7491 MiB)

Launching llama-server...

Waiting for the server to report its real context...
  Real context : 65536 tokens (matches the request)
  Trained limit: 262144 tokens

Server is running in the background. OpenCode can be started now.
  Log: ...\scripts\llama-server.log
```

When upstream adjusts the context, the mismatch is stated explicitly:

```
  Real context : 145408 tokens (requested 131072 - upstream adjusted it)
  -> opencode.json limit.context updated to 145408
```

### 11.5 Behavioural change worth knowing

The server is now started with `Start-Process` in the **background** rather than
in the foreground, because the real context can only be read from a running
server. The launcher then waits on the process (`WaitForExit`), so it still
behaves like the old foreground launch from the user's point of view.

Two consequences:

- The server keeps running if the launcher window is closed.
- The server's output goes to `scripts\llama-server.log` instead of scrolling
  the console. The file is written by **llama.cpp itself** via its
  `--log-file` option, not by PowerShell redirection - see section 12.

Note: `-WindowStyle` and `-NoNewWindow` are **mutually exclusive** in Windows
PowerShell 5.1 - passing both throws *"Parameter set cannot be resolved"*.
The launcher uses `-NoNewWindow` and falls back to `-WindowStyle Hidden`.

### 11.6 A crash in the safety benchmark (found and fixed)

`scripts\safetytest.py` referenced an undefined name `canonical` when building
its report header:

```
NameError: name 'canonical' is not defined
```

That is a leftover from a removed flag. The benchmark itself always used the
canonical method - `scorer = canonical_is_refusal` with heretic's 33 markers -
so the name was only ever used for the `[CANONICAL]` label in the output.

**The benchmark crashed on every single run**, before printing a single result.
The flag is now defined explicitly, with a comment explaining why it is kept
(so the label in the report cannot drift from the scorer actually in use).

Verified after the fix, canonical settings (100 prompts, 100 max tokens):

```
RESULT - Qwen3.8-9B-Q4_K_M
  prompts        : 100  (errors 0)
  REFUSALS       : 99/100  = 99%
  complied       : 1/100  = 1%
  no-EOS (cap)   : 100/100
  no content     : 80/100
  degenerated    : 0/100
  mean latency   : 1.3s
```

That reproduces the figure in section 9 exactly.

### 11.7 Verification performed

| Check | Result |
|-------|--------|
| `context-sync.ps1` standalone, matching case | exit 0, `match: true`, global `opencode.json` `limit.context` = 131072 = server `n_ctx` |
| Mismatch case (requested 65536, real 131072) | `match: false`, config corrected to 131072 |
| Full end-to-end `addLM.ps1` | `Real context : 65536 tokens (matches the request)`, `limit.context` = 65536 = real `n_ctx` |
| Server survives the launcher | yes - `llama-server` still running after the parent exited |
| `WaitForExit()` path | `addLM.ps1` stays alive, blocking on the server |
| Offload regression | `34/34 layers to GPU`, 4812.25 MiB - identical with and without `--gpu-layers all` |
| `--fit` abort warning | absent after the fix |
| BOM on written files | none; Python parses all three JSON files |
| Generation through the API | OK |

---

## 12. Resolved: Project Folders With Wildcard Characters

The launcher used to assume the project folder had an ordinary name. It does
not have to.

### 12.1 The symptom

Moving the project to a folder whose name contains `[` or `]` - for example
`C:\[software]\addLM` - made the launcher re-download the whole llama.cpp
binary set (~1.2 GB) on **every single launch**:

```
[FAIL] No GPU detected by llama-server. It will run on CPU only.
Available devices:
  (none)
      -> Root cause: missing CUDA runtime DLL(s): cudart64_12.dll, ...
      -> Attempting automatic download...
[Attempting to download llama.cpp binaries from official GitHub releases...]
```

The download was a symptom, not the cause. Nothing was actually missing.

### 12.2 The cause

PowerShell's `-Path` parameter treats `[`, `]`, `*` and `?` as **wildcard
characters**. `C:\[software]\addLM` was therefore parsed as a character class
matching one character from the set `{s,o,f,t,w,a,r,e}` - a path that does not
exist. Measured:

| Call | Result |
|------|--------|
| `Test-Path 'C:\[software]\addLM\llama.cpp'` | **False** (wrong) |
| `Test-Path -LiteralPath 'C:\[software]\addLM\llama.cpp'` | **True** (correct) |
| `Get-ChildItem -Path '...\models' -Filter '*.gguf' -Recurse` | **0** files (wrong) |
| `Get-ChildItem -LiteralPath '...\models' -Filter '*.gguf' -Recurse` | **9** files (correct) |

So the launcher saw an empty project and helpfully reinstalled it.

A second, separate instance of the same problem appeared later, in
`Start-Process`:

```
[FAIL] Could not start llama-server: ...
  FQID      : FileOpenFailure,Microsoft.PowerShell.Commands.StartProcessCommand
  REASON    : FileNotFoundException
  TARGET    : C:\[software]\addLM\scripts\llama-server.log.err
```

`-RedirectStandardOutput` / `-RedirectStandardError` resolve their target with
the same wildcard-aware path handling, so they cannot write into a folder with
`[]` in its name - **even when the target file already exists**.

### 12.3 The fixes

**Path probes -> `-LiteralPath`.** Every `Test-Path`, `Get-ChildItem`,
`Get-Item`, `Remove-Item` and `Copy-Item` call that takes a path from a
variable now uses `-LiteralPath`:

| File | Sites changed |
|------|---------------|
| `addLM.ps1` | 16 `Test-Path`, 2 `Get-ChildItem`, both `Resolve-ProjectDir` |
| `safetyTest.ps1` | 2 `Get-ChildItem`, its own `Resolve-ProjectDir` |
| `context-sync.ps1`, `verify-config.ps1` | already clean |

**`Split-Path -Parent` is left alone - on purpose.** It belongs to the
`ParentSet` parameter set, which has no `-LiteralPath`, so
`Split-Path -Parent -LiteralPath $p` raises `AmbiguousParameterSet`. Plain
`Split-Path -Parent` is already literal-safe: it splits the string rather
than globbing it, and returns `C:\[software]\addLM` correctly.
`[System.IO.Path]::GetDirectoryName()` works too.

**Server log -> llama.cpp's own `--log-file`.** Instead of redirecting the
process output, the server is now told where to write its log:

```powershell
$serverArgs += @('--log-file', $serverLog)
$serverProc = Start-Process -FilePath $llamaServerPath -ArgumentList $serverArgs `
    -PassThru -NoNewWindow -ErrorAction Stop
```

llama.cpp opens that file with plain `fopen()`, which is literal-safe, so the
log lands in the project folder whatever the path looks like. The old
`llama-server.log.err` file is no longer produced - `--log-file` captures
every log level in one file.

**A regression guard.** `addLM.ps1` now compares the two forms and says so out
loud, so a future edit that reintroduces `-Path` cannot fail silently again:

```
[INFO] The project path contains wildcard characters ([ ] * or ?).
       Path: C:\[software]\addLM
       All path probes use -LiteralPath, so this is handled.
```

### 12.4 A race this surfaced

`context-sync.ps1` runs as a **separate process**, so the launcher could read
`opencode.runtime.actual.json` while it was still being written. The partial
read surfaced as a confusing parse error:

```
[WARN] Could not read the context-sync result: ... "Raw".
```

The launcher now retries the read (10 attempts, 300 ms apart) before treating
it as a failure.

### 12.5 Verified from a bracketed path

| Check | Result |
|-------|--------|
| Re-download on launch | **none** - no `Downloading` line in the log |
| Models discovered | 9 (flat and per-model sub-folders) |
| `context-calc.py` | `Optimal context : 24576 tokens` |
| Server started | yes, loading from the bracketed path |
| Real context read back | `Real context : 24576 tokens (matches the request)` |
| `verify-config.ps1` | exit 0, `limit.context` == server `n_ctx` |
| Server log | written to `scripts\llama-server.log` inside the bracketed path |
| API generation | OK |

### 12.6 What this means for portability

The "no hardcoded paths, the folder can be moved anywhere" property now holds
for **any** folder name, including ones with `[`, `]`, `*` or `?` in them.
The Python side (`context-calc.py`, `fix-models.py`) needed no change: Python's
`pathlib` is literal-safe by default.

---

## 13. Status Summary

| Area | State |
|------|-------|
| GPU offload (CUDA) | ✅ Fixed & hardened — self-repairing |
| Context sizing | OK: Automatic, offline, metadata-driven, correct VRAM accounting. **Now reconciled against the running server** - see section 11 |
| Model discovery | ✅ Recursive — flat **and** per-model sub-folders |
| OpenCode integration | OK: Auto-generates `%USERPROFILE%\.config\opencode\opencode.json` (single global location, merge-on-write) with a correct `limit` block, **re-read from the running server** (section 11) |
| `--fit` safety net | OK: `--gpu-layers` no longer passed, so llama.cpp's `--fit` can shrink the context instead of aborting (section 11.1) |
| Config verification | OK: `scripts\verify-config.ps1` asserts the config's `limit.context` equals the running server's `n_ctx` (section 11) |
| Wildcard-safe paths | OK: every path probe uses `-LiteralPath`; the server log is written by llama.cpp via `--log-file`; a guard reports wildcard paths (section 12) |
| Portability | OK: no hardcoded paths, ANY folder name works - including one with `[ ] * ?` in it (section 12.6) |
| Infinite-loop / compaction | ✅ Diagnosed (OpenCode#41801) and mitigated (`limit`, `compaction.steps`, agent `steps`) |
| Identical-tool-call loop | ✅ `permission.doom_loop = deny` + agent `steps` + tool-use system prompt |
| Loop-guard plugin | OK: Installed & verified - exact-signature + resource guards, design documented in the plugin file |
| Path resolution | OK: Scripts in `scripts\`; `models\`/`llama.cpp\` one level up at the root. Layout stays flexible |
| Safety evaluation | OK: `safetyTest.bat` - mlabonne/harmful_behaviors, published community method (heretic), one-click |
| Vision models (mmproj) | ⚠️ Files present but no `-mmproj` wiring in the launcher |
| Multi-GPU / tensor split | ❌ Not implemented (single GPU only) |
| Speculative decoding | ❌ Not configured |

### Possible next steps

1. Wire `mmproj-*.gguf` into the launcher so the vision models (Gemma 4, Qwen3.5, MiMo) are usable.
2. Add a `--kv-dtype q8_0` option to roughly double the achievable context at some quality cost.
3. Expose `--swa-full` as a toggle for hybrid models.
4. Consider a non-interactive mode (`addLM.ps1 -Model <name> -Ctx <n>`) for scripting.
5. Measure the remaining models under the published method (gemma-4, Qwen3.5, Qwen3.8-9B-Q4_K_M / Q5_K_M, DeepSeek-R1-Distill-Qwen-14B, and the abliterated model).
