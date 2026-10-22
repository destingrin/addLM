================================================================================
 addLM - local GGUF model launcher for OpenCode
================================================================================

QUICK START
-----------
1. Drop your .gguf files into the  models\  folder.
   Flat works, and so does a per-model sub-folder:
       models\MyModel.gguf
       models\MyModel-GGUF\MyModel.gguf
2. Double-click  addLM.bat
3. Pick a model, then a context size (the optimum is calculated for you).
4. The server starts on  http://127.0.0.1:8081
5. The launcher reads the context the server ACTUALLY loaded and writes that
   into the OpenCode config, so the two can never disagree.
6. Fully restart OpenCode and pick the "llama-server" provider.

No Python, no llama.cpp, no CUDA Toolkit? The script sets those up for you.
(Only the NVIDIA *driver* is required - not the full CUDA Toolkit.)


WHAT IT DOES
------------
- Detects every .gguf in models\, including models inside per-model
  sub-folders (ignores mmproj-* projector files)
- Writes opencode.json to %USERPROFILE%\.config\opencode\ so OpenCode can
  see the provider, including the correct context/output limits for your
  local model. The generated config is MERGED into what is already there, so
  your own providers, agents and permissions are preserved.
- Calculates the optimal context size from the model's own metadata
  and your actual VRAM budget - no hardcoded table
- READS BACK the real context from the running server and corrects the
  OpenCode config if upstream adjusted it (see CONTEXT SIZE below)
- Verifies the GPU backend really loaded, and installs the CUDA runtime
  DLLs automatically if they are missing
- Starts llama-server on port 8081


FOLDER STRUCTURE
----------------
  addLM.bat         entry point (double-click)
  scripts\          scripts + docs
    addLM.ps1       main script
    safetyTest.bat  safety/refusal evaluation (own scratch port 8099)
    safetyTest.ps1  backs safetyTest.bat
    safetytest.py   the mlabonne/harmful_behaviors benchmark
    harmful_*.parquet  benchmark dataset
    context-calc.py offline context-size calculator
    context-sync.ps1 reads the REAL context from the running server
    verify-config.ps1 checks the config against the running server
    verifyConfig.bat  one-click wrapper for verify-config.ps1
    fix-models.py   generates opencode.json for OpenCode
    readme.txt      this file
    plugins\        addlm-loop-guard.js (copy into
                    %USERPROFILE%\.config\opencode\plugin\ - see below)
  models\           your .gguf files
  llama.cpp\        llama-server binaries

models\ and llama.cpp\ sit at the project root, next to scripts\. The scripts
look for them next to themselves and one level up, so the layout is flexible
and the whole folder can be moved anywhere.

The models\ folder is found by CONTENT - the folder that actually holds .gguf
files wins, so a stray empty folder cannot hide your models. If models\ is
missing the script tells you the exact path to create and does not create one
itself.


GPU SUPPORT (NVIDIA)
--------------------
The llama.cpp Windows CUDA builds no longer bundle the CUDA runtime.
Without these three files in llama.cpp\ the server starts but runs on CPU
only, with the GPU sitting idle and no error message:

  cudart64_12.dll
  cublas64_12.dll
  cublasLt64_12.dll

addLM.ps1 checks this on every start and downloads them for you if needed.
To check manually:

  cd llama.cpp
  llama-server.exe --list-devices

  "Available devices: (none)"   ->  runtime missing, will run on CPU
  "CUDA0: NVIDIA GeForce ..."   ->  GPU is working

No CUDA Toolkit install is needed - only the NVIDIA driver must be present.


CONTEXT SIZE
------------
Calculated automatically from the GGUF header (trained context length) plus a
real VRAM measurement via llama.cpp's own llama-fit-params tool. Fully offline.

  python scripts\context-calc.py models
  python scripts\context-calc.py models --json
  python scripts\context-calc.py "models\my-model.gguf"

Options:  --llama-dir <path>   --kv-dtype f16|q8_0|q4_0   --margin <MiB>   --json

--llama-dir is optional. Without it, llama.cpp\ is found automatically:
script folder, then project root, then current directory.

--margin is the VRAM to leave free and IS applied - it is subtracted from the
usable budget (total - desktop reserve - margin). The default 1024 is absorbed
by the desktop reserve, so it does not change the default result.

If the GPU backend is not active, the model is sized against system RAM
instead, using the real free/total figures read from Windows.

Note: the models in models\ are hybrid (sliding-window attention), so a naive
KV-cache formula would be wrong by roughly 4x. The script uses llama.cpp's
own tooling instead, which handles it correctly.

The budget is USABLE vram (total minus a desktop reserve), not currently-free
vram - a busy browser must not make a launchable model look unlaunchable.


PREDICTED vs. REAL CONTEXT
--------------------------
The size chosen in the menu is a PREDICTION. The server has the final say, so
after the server starts, the launcher reads back the context it ACTUALLY
loaded and rewrites the OpenCode config with that value:

  GET http://127.0.0.1:8081/props  ->  default_generation_settings.n_ctx

/props reports the real per-slot context, after llama.cpp's own --fit pass has
run. If upstream adjusted the context, you will see it:

  Real context : 145408 tokens (requested 131072 - upstream adjusted it)
  -> opencode.json limit.context updated to 145408

This matters because OpenCode's usable window is (context - output). A
limit.context that disagrees with the server makes every step look like an
overflow and re-triggers compaction after every single step.

(/v1/models is NOT used for this: its "context_length" is the model's TRAINED
window, not the running one.)

The outcome of the last run is recorded in opencode.runtime.actual.json.

To check the config against a running server at any time:

  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-config.ps1

  Exit codes:  0 = OK   1 = mismatch   2 = server not running   3 = bad config


THE SERVER RUNS IN THE BACKGROUND
---------------------------------
The server is started with Start-Process so the real context can be read back
from it, then the launcher waits on it. Two consequences:

  - the server keeps running if you close the launcher window
  - its output goes to scripts\llama-server.log (one file, written by
  llama.cpp itself via --log-file)
    instead of scrolling the console

To stop the server:  Get-Process llama-server | Stop-Process -Force

The launcher does NOT pass --gpu-layers. llama.cpp's --fit (on by default) is
the safety net that shrinks the context until the model fits in VRAM, but it
aborts if the user set that parameter explicitly:

  W common_fit_params: failed to fit params to free device memory:
    n_gpu_layers already set by user to -2, abort

Leaving it alone lets --fit work, and the model still offloads every layer
(measured: "offloaded 34/34 layers to GPU" either way).


IF A REQUEST SEEMS TO HANG
---------------------------
There are two known loop classes, both in OpenCode itself (not in llama.cpp
or the model):

1) "maximum number of steps allowed has been reached"
   The agent kept issuing the SAME failing tool call. OpenCode ships a
   `doom_loop` permission for this, but it defaults to "ask", which does not
   protect unattended sessions. This project sets it to "deny", so the 3rd
   identical call is blocked and the agent is told to change approach.
   See https://github.com/anomalyco/opencode/issues/45442

2) The compaction summary request degenerates into repeated lines.
   See https://github.com/anomalyco/opencode/issues/41801

What this project does about it:
  - permission.doom_loop = deny  (hard circuit-breaker for identical calls)
  - agents.build/plan.steps = 15 (a SOFT backstop; OpenCode still passes the
    tools to the model after the limit, but most models stop anyway)
  - a system prompt telling the model to emit plain tool calls and to never
    repeat a call that already failed
  - declares a correct limit.context / limit.output for the local model
    (OpenCode otherwise assumes 200000/32000, which makes its usable window
    negative and re-triggers compaction after every single step)
  - sets a small step budget for the compaction agent so a degenerate
    summary fails fast instead of streaming thousands of duplicate lines
  - a loop-guard PLUGIN that groups repeated calls by resource rather than
    by byte-exact input (see LOOP-GUARD PLUGIN below)

If it still happens:
  - check the OpenCode log for a compaction message with a huge repeated block
  - temporarily set  "compaction": { "auto": false }  in opencode.json
  - the upstream workaround is a stronger model for the compaction agent


LOOP-GUARD PLUGIN
-----------------
scripts\plugins\addlm-loop-guard.js is an OpenCode V2 plugin that stops an agent
from repeating the same tool call. It closes the gap that doom_loop leaves:
doom_loop only catches BYTE-IDENTICAL calls, while this plugin groups by
RESOURCE, so calls that differ in whitespace are caught too.

INSTALL
  Copy the file into the OpenCode config plugin folder:

    %USERPROFILE%\.config\opencode\plugin\addlm-loop-guard.js

  OpenCode auto-discovers that folder, so do NOT add a "plugins" array to
  opencode.json - a relative path there resolves against %USERPROFILE% and
  creates a duplicate entry that fails to load.

VERIFY
  opencode api plugin.list

  Look for:  "addlm-loop-guard"  status "active"

WHAT IT DOES
  On a repeated call it throws from the tool.execute.before hook, so the call
  is aborted and the model receives the error as the tool result. After 3
  recovery attempts on the same call it keeps refusing.

  Two guards are active:
    - EXACT SIGNATURE: the normalised tool + full input.
    - RESOURCE: the tool + the values of the arguments that identify what the
      call acts on (path, command, pattern, url, ...). This catches the same
      resource being hammered in slightly different ways. It needs 6+ hits and
      only fires when the calls were not all identical, so reading several
      different files is never blocked.

  Measured on a test session ("run `ls -la` five times in a row"):
    25 tool calls, 12 executed, 13 blocked, session finished with "stop"

  Sample blocked result:
    [addlm-loop-guard] Blocked a repeated call to "shell" (attempt 2). You
    already made this call with the same input and it did not get you closer
    to the answer. Do NOT repeat it. Change your approach: use a different
    tool, a different resource, different arguments, or answer without it.


NOTE: TOOLS CAN VANISH MID-SESSION
----------------------------------
If a tool (e.g. shell) suddenly becomes "Unknown tool", that is normal OpenCode
v2 behaviour, not a broken config. The Code Mode tool catalog is regenerated
per session and changes on its own. Restart the session. The OpenCode API
still works:
  opencode api plugin.list
  curl http://127.0.0.1:45278/api/shell -X POST


SAFETY / REFUSAL BENCHMARK
--------------------------
safetyTest.bat evaluates a model's refusal behaviour using the standard
mlabonne/harmful_behaviors dataset - the same dataset the abliteration
community measures refusal rates on.

  cd scripts
  safetyTest.bat

It picks a model, starts a throwaway llama-server on port 8099 (so it does
not disturb a running addLM server on 8081), runs the benchmark and shuts
the server down again.

The benchmark uses the PUBLISHED community method, so its number can be
compared directly with the figures heretic publishes. There is no second
mode. The method is:
  - heretic's 33 refusal markers
  - all 100 test prompts (test[:100])
  - greedy decoding (temperature 0), 100 tokens per answer
  - the "You are a helpful assistant." system prompt
  - an empty answer counts as a refusal

Optional arguments (passed straight through):
  safetyTest.bat -Prompts 100 -MaxTokens 100 -Port 8099

To run the Python script directly against an already-running server:
  python scripts\safetytest.py <port> "<label>" [num_prompts] [max_tokens]

Results measured here:

  Qwen3.8-9B-Q8_0         (stock)        99/100 refusals  (99%)

Heretic's own published table reports 97/100 refusals for a stock model
(google/gemma-3-12b-it) and 3/100 for abliterated variants, on 100 prompts.
Reference implementation:
  https://github.com/p-e-w/heretic/blob/master/src/heretic/scorers/keyword_rate.py

One caveat on the 99/100: at a 100-token budget the model spends everything
in its reasoning and returns no visible answer (92 of 100 were empty), and
an empty answer counts as a refusal under this method. So the figure says
"did not get to write an answer" as much as "wrote a refusal". Give the
model more room with -MaxTokens if you want to see what it actually says.

Note: an abliterated model reasons for a long time before answering, so it hits
the token cap more often. Give it a large output budget or it looks stuck.

Caution: an abliterated model will answer harmful prompts. The launcher enables
llama-server's --agent tools (exec_shell_command, write_file) - consider removing
--agent when using one, and never expose the port to a network.

FOLDER NAMES WITH [ ] * OR ?
----------------------------
The project folder can have ANY name, including one containing the wildcard
characters [ ] * or ? - for example C:\[software]\addLM.

PowerShell's -Path parameter treats those as wildcards, so every path probe
in the launcher uses -LiteralPath instead. The server's log is written by
llama.cpp itself (via its --log-file option) rather than by PowerShell
redirection, because -RedirectStandardOutput cannot write into a folder whose
name contains [].

If the launcher ever prints:

    [INFO] The project path contains wildcard characters ([ ] * or ?).

that is informational, not an error - it means the path is being handled
correctly.


TROUBLESHOOTING
---------------
  Models missing in OpenCode
      OpenCode reads opencode.json only at startup - fully restart it.
      If stale entries remain:  Remove-Item -Recurse -Force "$env:APPDATA\opencode"
      The live config is at  %USERPROFILE%\.config\opencode\opencode.json

  "Could not size this model to the available VRAM"
      The model genuinely does not fit. Use a smaller quant, or a smaller
      KV cache type (--kv-dtype q8_0), or close other GPU apps.
      NOTE: this check uses usable VRAM (total - desktop reserve), so a busy
      browser alone will NOT trigger it.

  "Port 8081 already in use"
      Another server is running:
      Get-Process llama-server | Stop-Process -Force

  Slow / GPU idle
      nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv
      If VRAM used is ~0, the CUDA runtime is missing (see GPU SUPPORT).

  Context size differs between runs
      It is sized against the VRAM available at that moment. Close other GPU
      apps (browser, Discord, ...) and run it again.

  "parameter -File path does not exist"
      addLM.ps1 must be in the scripts\ subfolder next to addLM.bat, or
      directly beside it.

  Regenerate the OpenCode config without launching
      python scripts\fix-models.py --generate-only

  Check the config against the running server
      powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-config.ps1
      Exit code 0 = the limits match, 1 = they do not, 2 = no server running.

  The limits in OpenCode look wrong
      OpenCode reads opencode.json only at startup - fully restart it.
      Then run verify-config.ps1 to confirm the limits match the server.

  The server does not appear in the console
      It runs in the background. Its output is in scripts\llama-server.log.

  It re-downloads llama.cpp on every launch
      That used to happen when the project folder name contained [ ] * or ?,
      because PowerShell treated them as wildcards and the launcher could not
      see its own files. It is fixed. If it still happens, check the log for
      the [INFO] line about wildcard characters.


MORE INFORMATION
----------------
Full details, architecture notes and known issues:
  scripts\_HANDOFF.md
