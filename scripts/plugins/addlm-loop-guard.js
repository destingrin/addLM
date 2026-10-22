// addLM loop-guard plugin for OpenCode V2.
//
// Why this exists
// ---------------
// OpenCode's built-in `doom_loop` permission only catches a tool call that is
// BYTE-IDENTICAL to the previous one. A model that gets stuck often varies the
// call slightly (whitespace, a different argument order, an added comment) and
// therefore slips past it.
//
// Upstream report https://github.com/anomalyco/opencode/issues/45442 shows a
// subagent issuing 364 identical grep calls for ~50 minutes while doom_loop
// was already enabled but did not fire.
//
// A real session exported from this project showed the same class of failure:
// 42 attempts at one broken call, each differing only in whitespace, ending in
// "unable to complete this task because the maximum number of steps allowed".
//
// This plugin closes the gap. It groups calls by RESOURCE rather than by exact
// input, so "read the same file" and "grep the same pattern" are caught even
// when the arguments differ.
//
// Behaviour
// ---------
//   * On a repeated call it THROWS from the `tool.execute.before` hook, which
//     aborts that call and feeds the error back to the model as the tool
//     result. The model then sees "you already did this" and changes course.
//   * After RECOVERY_LIMIT recoveries for the same signature it keeps
//     refusing, so a stuck agent cannot burn the whole step budget.
//
// Two guards
// ----------
//   1. EXACT SIGNATURE - the normalised tool + full input. Catches a call
//      repeated verbatim (modulo whitespace / quote style).
//
//   2. RESOURCE - the tool + the values of its resource-identifying arguments
//      (path, command, pattern, url, ...), ignoring everything else. Catches
//      the same resource being hammered in slightly DIFFERENT ways, which the
//      exact signature misses because the other arguments drifted.
//
//      The resource guard deliberately requires that the calls were NOT all
//      identical (i.e. the exact signature varied). If every call to a
//      resource was byte-identical, the exact guard already reports it, and
//      the resource guard stays quiet so the model gets one clear message
//      rather than two overlapping ones.
//
//      It also requires a HIGH repeat count, because re-touching one resource
//      a few times is legitimate: reading the same file again after editing
//      it is normal work, not a loop.
//
//      A previous version of this guard keyed on the argument KEY SHAPE (the
//      key names, ignoring values) instead of the resource. That was wrong:
//      six `edit` calls to six DIFFERENT files and seven `read` calls to
//      seven DIFFERENT files are ordinary work, and the shape guard blocked
//      them. It is replaced by the resource guard below.
//
// Resource keys
// -------------
// The arguments that identify WHICH resource a call acts on. Everything else
// (limits, offsets, descriptions, ...) is ignored when building the resource
// signature, so "read a.txt" and "read a.txt with limit=50" are one resource.
//
//   path, filepath, file, filename, command, cmd, script, pattern, query,
//   url, uri, directory, dir, workdir, cwd, name, target, resource
//
// Ordering constraint - DO NOT MOVE THE RESOURCE CHECK
// -----------------------------------------------------
// The resource check must be evaluated BEFORE the `entry.count === 1` early
// return. In the scenario the guard exists for - same resource, drifting
// arguments - every individual call is a "first sighting" of its own exact
// signature, so an early return placed above the resource check swallows all
// of them and the guard NEVER FIRES. Verified by test: with the check in the
// wrong order, 8/8 drifting calls were allowed; with it in the right order,
// calls 1-5 pass and 6+ are blocked.
//
// Verified behaviour (unit-tested against the real hook logic)
// --------------------------------------------------------------
//   7 reads of 7 DIFFERENT files   -> never trips
//   7 edits of 7 DIFFERENT files   -> never trips
//   same file, drifting args, 8x   -> resource guard trips at call 6
//   identical calls, 6x            -> exact guard fires first
//                                    (recovery 1 -> 2 -> 3 -> dead)
//   same command, different workdir-> different resource, never trips
//
// Measured on a live session (prompt: "Run the command `ls -la` five times in
// a row"): 25 tool calls, 12 executed, 13 blocked, session finished with
// "stop" instead of burning the step budget.
//
// The model also found an escape hatch - it switched from the `shell` tool to
// `execute` with `tools.shell.execute(command="dir", workdir=".\")` - and the
// plugin caught that too, because the signature is tool-name + normalised
// input, so the same call through a different route is still a repeat.
//
// API (verified against @opencode/plugin 2.1.1, matching OpenCode 2.1.x)
// -----------------------------------------------------------------------
//   export default Plugin.define({ id, setup: async (ctx) => { ... } })
//   await ctx.tool.hook("execute.before", async (event) => { ... })
//
//   The tool.execute.before event is:
//     { tool, sessionID, agent, messageID, id, input }   <- `input`, not `args`
//
//   The session.context event is:
//     { sessionID, agent, model, kind, system, messages, options, tools }
//
// Install: copy this file into your OpenCode plugin directory:
//   %USERPROFILE%\.config\opencode\plugin\addlm-loop-guard.js
//
// OpenCode auto-discovers that directory. Do NOT add a "plugins" array to
// opencode.json - a relative path there resolves against %USERPROFILE% and
// produces a duplicate entry that fails to load.
//
// See addLM/HANDOFF - addLM.md for the full analysis.

import { Plugin } from "@opencode/plugin"

export default Plugin.define({
  id: "addlm-loop-guard",

  setup: async (ctx) => {
    // How many recoveries we allow per distinct signature before we just keep
    // refusing the call outright.
    const RECOVERY_LIMIT = 3

    // A signature seen this many times is a loop even if the call text varies.
    const REPEAT_THRESHOLD = 2

    // How many calls to the SAME RESOURCE are tolerated before the resource
    // guard trips. Deliberately high: hitting the same file a handful of
    // times can be legitimate (re-reading after an edit), so the guard only
    // acts on a persistent pattern.
    const RESOURCE_THRESHOLD = 6

    // Arguments that identify WHICH resource a call acts on. Everything else
    // (limits, offsets, descriptions, ...) is ignored when building the
    // resource signature, so "read a.txt" and "read a.txt with limit=50"
    // are the same resource.
    const RESOURCE_KEYS = [
      "path", "filepath", "file", "filename",
      "command", "cmd", "script",
      "pattern", "query", "url", "uri",
      "directory", "dir", "workdir", "cwd",
      "name", "target", "resource",
    ]

    // sessionID -> Map<signature, { count, recoveries }>
    const calls = new Map()
    // sessionID -> Map<resourceSignature, { count, sigs: Set<string> }>
    // Kept in a SEPARATE map so a resource key can never collide with an
    // exact signature.
    const resources = new Map()
    // sessionID -> Set<signature> that already exhausted recovery
    const dead = new Map()

    const state = (id) => {
      if (!calls.has(id)) {
        calls.set(id, new Map())
        resources.set(id, new Map())
        dead.set(id, new Set())
      }
      return {
        calls: calls.get(id),
        resources: resources.get(id),
        dead: dead.get(id),
      }
    }

    /**
     * Normalise a tool call into a resource-ish signature.
     *
     * Goals:
     *   - collapse whitespace / formatting differences
     *   - ignore quote style and path separators
     *   - keep the VALUES, because "read file A" and "read file B" differ
     */
    const signature = (tool, input) => {
      let body = ""
      try {
        body = JSON.stringify(input ?? {})
      } catch {
        body = String(input)
      }

      body = body
        .replace(/\s+/g, " ") // collapse whitespace runs
        .trim()
        .replace(/["']/g, "") // quote style
        .replace(/\\/g, "/") // windows path separators
        .replace(/,\s*/g, ",") // trailing commas
        .replace(/;$/, "")
        .replace(/\bfrom\s+tools\b/g, "fromtools")
        .replace(/\s*=\s*/g, "=")

      return `${tool}::${body}`
    }

    /**
     * The RESOURCE signature: the tool plus the values of the arguments that
     * identify what the call acts on, ignoring all other arguments.
     *
     *   read  {path:"a.txt", limit:50}   ->  read::path=a.txt
     *   read  {path:"a.txt"}              ->  read::path=a.txt    (same)
     *   read  {path:"b.txt"}              ->  read::path=b.txt    (different)
     *   edit  {path:"f1.js", old, new}    ->  edit::path=f1.js
     *
     * Returns null when no resource-identifying argument is present, in
     * which case the call is only tracked by its exact signature.
     */
    const resourceSignature = (tool, input) => {
      const parts = []
      try {
        for (const key of Object.keys(input ?? {}).sort()) {
          if (!RESOURCE_KEYS.includes(key.toLowerCase())) continue
          let value = input[key]
          if (typeof value !== "string") {
            try {
              value = JSON.stringify(value)
            } catch {
              value = String(value)
            }
          }
          parts.push(`${key}=${String(value).replace(/\s+/g, " ").trim()}`)
        }
      } catch {
        return null
      }
      if (!parts.length) return null
      return `${tool}::${parts.join("&")}`
    }

    await ctx.tool.hook("execute.before", async (event) => {
      const sessionID = event.sessionID
      if (!sessionID) return

      const tool = event.tool ?? "unknown"
      const st = state(sessionID)
      const sig = signature(tool, event.input)

      const entry = st.calls.get(sig) ?? { count: 0, recoveries: 0 }
      entry.count += 1
      st.calls.set(sig, entry)

      // RESOURCE GUARD.
      //
      // Checked BEFORE the `entry.count === 1` early return below. The whole
      // point of this guard is to catch calls that are each a "first sighting"
      // of their own exact signature but all hit the same resource - so an
      // early return placed above it would swallow every one of them.
      //
      // It only trips when the exact signature VARIED between the calls.
      // Identical repeats are the exact guard's job, and reporting both would
      // only give the model two overlapping messages.
      const resSig = resourceSignature(tool, event.input)
      if (resSig) {
        const res = st.resources.get(resSig) ?? { count: 0, sigs: new Set() }
        res.count += 1
        res.sigs.add(sig)
        st.resources.set(resSig, res)

        if (res.count >= RESOURCE_THRESHOLD && res.sigs.size > 1) {
          throw new Error(
            `[addlm-loop-guard] Blocking "${tool}" on the same resource - it has been ` +
              `called ${res.count} times (${res.sigs.size} different call forms) and the ` +
              `agent is not making progress. Stop repeating this call. Change approach: ` +
              `a different tool, a different resource, or answer without it.`,
          )
        }
      }

      // First sighting of this exact call: always allow.
      if (entry.count === 1) return

      // Not yet a loop, but nudge the model to vary its approach.
      if (entry.count < REPEAT_THRESHOLD) return

      // This signature has already burned through its recovery budget.
      if (st.dead.has(sig)) {
        throw new Error(
          `[addlm-loop-guard] Refusing to run "${tool}" again: this exact call has already been ` +
            `made ${entry.count} times with no progress. Change approach - a different tool, a ` +
            `different resource, different arguments, or answer without it.`,
        )
      }

      if (entry.recoveries >= RECOVERY_LIMIT) {
        st.dead.add(sig)
        throw new Error(
          `[addlm-loop-guard] Giving up on "${tool}" after ${entry.recoveries} recovery attempts: ` +
            `the agent keeps making the same call and is not making progress. ` +
            `Last input: ${JSON.stringify(event.input).slice(0, 200)}`,
        )
      }

      entry.recoveries += 1
      throw new Error(
        `[addlm-loop-guard] Blocked a repeated call to "${tool}" (attempt ${entry.count}). You ` +
          `already made this call with the same input and it did not get you closer to the ` +
          `answer. Do NOT repeat it. Change your approach: use a different tool, a different ` +
          `resource, different arguments, or answer without it.`,
      )
    })
  },
})
