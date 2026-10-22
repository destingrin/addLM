#!/usr/bin/env python3
"""context-calc.py - determine the optimal llama-server context size, fully offline.

How it works
------------
1. Read the GGUF header to get the model's *trained* context length. That is the
   quality ceiling: a context longer than the model was trained on degrades
   quality (or needs RoPE scaling).

2. Ask llama.cpp itself how much VRAM a given context size needs, by running the
   bundled `llama-fit-params.exe --fit-print on`. This tool knows about
   hybrid / sliding-window-attention architectures, KV cache quantisation and
   compute buffers. A hand-written formula does not - naive KV math overestimates
   by ~4x for hybrid models such as Qwen3.5/3.8 (full_attention_interval = 4)
   and Gemma 4 (per-layer sliding_window_pattern).

3. Pick the largest context that fits in the currently free VRAM, never exceeding
   the trained context length.

Everything runs locally; no network access is required.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

# --------------------------------------------------------------------------- GGUF


class Reader:
    """Minimal GGUF header reader (metadata only, never touches tensor data)."""

    def __init__(self, f):
        self.f = f

    def read(self, n):
        b = self.f.read(n)
        if len(b) != n:
            raise EOFError("unexpected end of file")
        return b

    def u8(self):
        return self.read(1)[0]

    def i8(self):
        return int.from_bytes(self.read(1), "little", signed=True)

    def u16(self):
        return int.from_bytes(self.read(2), "little")

    def i16(self):
        return int.from_bytes(self.read(2), "little", signed=True)

    def u32(self):
        return int.from_bytes(self.read(4), "little")

    def i32(self):
        return int.from_bytes(self.read(4), "little", signed=True)

    def u64(self):
        return int.from_bytes(self.read(8), "little")

    def i64(self):
        return int.from_bytes(self.read(8), "little", signed=True)

    def f32(self):
        return int.from_bytes(self.read(4), "little", signed=False)

    def f64(self):
        return int.from_bytes(self.read(8), "little", signed=False)

    def boolean(self):
        return self.read(1)[0] != 0

    def string(self):
        return self.read(self.u64()).decode("utf-8", "replace")

    def value(self, t):
        if t == 0:
            return self.u8()
        if t == 1:
            return self.i8()
        if t == 2:
            return self.u16()
        if t == 3:
            return self.i16()
        if t == 4:
            return self.u32()
        if t == 5:
            return self.i32()
        if t == 6:
            return self.f32()
        if t == 7:
            return self.boolean()
        if t == 8:
            return self.string()
        if t == 9:
            et, n = self.u32(), self.u64()
            return [self.value(et) for _ in range(n)]
        if t == 10:
            return self.u64()
        if t == 11:
            return self.i64()
        if t == 12:
            return self.f64()
        raise ValueError(f"unknown gguf value type {t}")


def read_gguf(path):
    """Return (version, n_tensors, metadata dict)."""
    with open(path, "rb") as f:
        r = Reader(f)
        if r.read(4) != b"GGUF":
            raise ValueError("not a GGUF file")
        version = r.u32()
        n_tensors = r.u64()
        n_kv = r.u64()
        meta = {}
        for _ in range(n_kv):
            key = r.string()
            meta[key] = r.value(r.u32())
        return version, n_tensors, meta


# ------------------------------------------------------------------- VRAM / tool

CANDIDATES = [262144, 131072, 65536, 49152, 32768, 24576, 16384, 12288, 8192, 6144, 4096]

# llama-fit-params prints:  "<device> <model> <context> <compute>"  in MiB
ROW_RE = re.compile(r"^(CUDA\d+|Vulkan\d+|HIP\d+|Host)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", re.M)


def find_llama_dir(explicit=None):
    if explicit:
        p = Path(explicit)
        return p.parent if p.is_file() else p
    here = Path(__file__).resolve().parent
    for cand in (here / "llama.cpp", here.parent / "llama.cpp", Path.cwd() / "llama.cpp"):
        if (cand / "llama-fit-params.exe").exists():
            return cand
    return None


def find_fit_tool(llama_dir):
    if not llama_dir:
        return None
    for name in ("llama-fit-params.exe", "llama-fit-params"):
        p = Path(llama_dir) / name
        if p.exists():
            return p
    return None


def free_vram_mib():
    """(free, total, used) MiB for the GPU with the most free memory.

    Uses memory.free rather than total - used: on Windows/WDDM part of the
    driver overhead is reserved and not reported as "used", so total - used
    overestimates what CUDA can actually allocate.
    """
    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "--query-gpu=memory.total,memory.used,memory.free",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
    except Exception:
        return None

    best = None
    for line in out.strip().splitlines():
        try:
            total, used, free = (int(x) for x in line.split(","))
        except ValueError:
            continue
        if best is None or free > best[0]:
            best = (free, total, used)
    return best


def free_system_ram_mib():
    """(free, total) MiB of system RAM, or None if it cannot be read.

    Needed for the CPU fallback: without a GPU the model lives in RAM, and
    the old code compared the required RAM against the *VRAM* capacity
    (which is 0 without nvidia-smi), so the check degenerated into
    "host <= host" and always passed.
    """
    try:
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            return None
        mib = 1024 * 1024
        return (stat.ullAvailPhys // mib, stat.ullTotalPhys // mib)
    except Exception:
        return None


def gpu_available(llama_dir):
    """True if llama-server can actually see the GPU.

    This matters: without the CUDA runtime DLLs the ggml CUDA backend fails to
    load and llama-fit-params reports the model on "Host" instead of "CUDA0".
    Sizing against the host would produce a wildly optimistic context size that
    then fails to start on the GPU.
    """
    if not llama_dir:
        return False
    server = Path(llama_dir) / "llama-server.exe"
    if not server.exists():
        server = Path(llama_dir) / "llama-server"
    if not server.exists():
        return False
    try:
        r = subprocess.run([str(server), "--list-devices"], capture_output=True,
                           text=True, timeout=120)
        blob = (r.stdout or "") + "\n" + (r.stderr or "")
    except Exception:
        return False
    return bool(re.search(r"(CUDA\d|Vulkan\d|HIP\d)", blob))


def measure(tool, model, ctx, kv_dtype="f16", n_gpu_layers="all"):
    """(gpu_mib, host_mib) required for `ctx` tokens, or None if the tool failed."""
    cmd = [str(tool), "-m", str(model), "-c", str(ctx),
           "-ngl", str(n_gpu_layers), "--fit-print", "on"]
    if kv_dtype != "f16":
        cmd += ["--cache-type-k", kv_dtype, "--cache-type-v", kv_dtype]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except Exception:
        return None

    blob = (r.stdout or "") + "\n" + (r.stderr or "")
    gpu = host = 0
    seen_gpu = False
    for m in ROW_RE.finditer(blob):
        dev = m.group(1)
        model_mib, ctx_mib, compute_mib = int(m.group(2)), int(m.group(3)), int(m.group(4))
        if dev.lower() == "host":
            host += model_mib + ctx_mib + compute_mib
        else:
            seen_gpu = True
            gpu += model_mib + ctx_mib + compute_mib
    if not seen_gpu:
        # everything landed on the host -> the GPU backend is not active
        return (0, host) if host else None
    return (gpu, host)


# --------------------------------------------------------------------- analysis


def trained_context(model):
    try:
        _, _, meta = read_gguf(Path(model))
    except Exception:
        return None, None
    arch = meta.get("general.architecture", "?")
    ctx = meta.get(f"{arch}.context_length") or meta.get("general.context_length")
    return ctx, arch


def architecture_notes(meta):
    """Human readable notes about hybrid / sliding-window attention layouts."""
    arch = meta.get("general.architecture", "?")
    notes = []
    interval = meta.get(f"{arch}.full_attention_interval")
    if interval:
        notes.append(f"hybrid (full attention every {interval} layers -> KV cost is NOT linear in layers)")
    pattern = meta.get(f"{arch}.attention.sliding_window_pattern")
    if pattern:
        n_full = sum(1 for x in pattern if not x)
        notes.append(f"hybrid sliding-window ({n_full}/{len(pattern)} full-attention layers)")
    sw = meta.get(f"{arch}.attention.sliding_window")
    if sw:
        notes.append(f"sliding window {sw}")
    return notes


def analyse(model, tool, free_mib, total_mib, margin_mib, kv_dtype="f16",
            verbose=True, gpu_ok=True, used_mib=0, ram_mib=None):
    model = Path(model)
    trained, arch = trained_context(model)

    try:
        _, _, meta = read_gguf(model)
        notes = architecture_notes(meta)
    except Exception:
        notes = []

    if not gpu_ok:
        notes.append("GPU backend NOT active - sizing against system RAM instead of VRAM")

    allowed = [c for c in CANDIDATES if trained is None or c <= trained]
    ceiling = max(allowed or [4096])

    # How much VRAM the model may occupy.
    #
    # The server is the only heavy GPU user once it starts, but the desktop and
    # browser keep a few hundred MiB reserved. We therefore allow the model to
    # use (total - reserved_for_desktop) and require it to fit in what is free
    # RIGHT NOW only as a soft signal - a busy desktop must not make a model
    # look unlaunchable.
    #
    # The hard constraint is: weights + KV + compute must fit in
    # (total - desktop_reserve - margin).
    #
    # `margin` is the user's explicit "leave this much VRAM free" request
    # (--margin, default 1024 MiB). It was previously accepted and then
    # silently ignored, so tuning it had no effect at all.
    desktop_reserve = 1024
    if used_mib:
        # whatever the desktop is using, but never more than the reserve
        desktop_reserve = max(desktop_reserve, min(used_mib, 2048))
    margin = max(0, int(margin_mib or 0))
    capacity = total_mib - desktop_reserve - margin

    # System RAM budget for the CPU fallback. Without a GPU the model has to
    # fit in RAM, so the RAM figure is what the capacity check must use -
    # not the (zero) VRAM capacity.
    if ram_mib:
        ram_free, ram_total = ram_mib
        ram_capacity = max(0, ram_total - margin)
    else:
        ram_free = ram_total = 0
        ram_capacity = 0
        notes.append("Could not read system RAM - the CPU fallback cannot be sized")

    chosen = None
    chosen_gpu = None
    chosen_host = None
    tried = []
    smallest = min(allowed or [4096])
    for ctx in sorted(allowed or [4096], reverse=True):
        m = measure(tool, model, ctx, kv_dtype)
        if m is None:
            continue
        gpu, host = m
        tried.append((ctx, gpu))
        if verbose:
            print(f"    ctx {ctx:>7}: GPU {gpu:>6} MiB   (host {host} MiB)")
        # when the model lands on the host, the "GPU" column is 0 -> the host
        # figure is what actually has to fit, so compare it against free RAM
        if gpu <= 0:
            if not host:
                continue
            if ram_capacity <= 0:
                # No RAM reading available. Refuse to claim the model fits
                # rather than silently recommending a context that cannot
                # start - the old "host <= host" check always passed.
                if verbose:
                    print(f"    ctx {ctx:>7}: needs {host} MiB in RAM, but free RAM "
                          f"is unknown - cannot confirm it fits")
                continue
            if host <= ram_capacity:
                chosen, chosen_gpu, chosen_host = ctx, 0, host
                break
        elif gpu <= capacity:
            chosen, chosen_gpu, chosen_host = ctx, gpu, host
            break
        if ctx == smallest:
            break

    return {
        "model": model.name,
        "arch": arch,
        "trained_ctx": trained,
        "notes": notes,
        "kv_dtype": kv_dtype,
        "gpu_active": gpu_ok,
        "free_vram_mib": free_mib,
        "used_vram_mib": used_mib,
        "total_vram_mib": total_mib,
        "capacity_mib": capacity,
        "margin_mib": margin,
        "ram_capacity_mib": ram_capacity,
        "recommended_ctx": chosen,
        "gpu_mib_at_recommended": chosen_gpu,
        "host_mib_at_recommended": chosen_host,
        "does_not_fit": tried[-1] if (chosen is None and tried) else None,
        "measurements": tried,
    }


def main():
    ap = argparse.ArgumentParser(
        description="Offline context-size calculator for llama.cpp models")
    ap.add_argument("models", nargs="*", help="GGUF files or folders (default: ./models)")
    ap.add_argument("--llama-dir",
                    help="path to the llama.cpp folder (holds llama-fit-params.exe). "
                         "Optional - the script folder, the project root and the current "
                         "directory are searched automatically")
    ap.add_argument("--kv-dtype", default="f16", choices=["f16", "q8_0", "q4_0"],
                    help="KV cache dtype used for the estimate (default f16)")
    ap.add_argument("--margin", type=int, default=1024, help="VRAM to leave free (MiB)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    # --llama-dir is optional. When it is not given, find_llama_dir() searches
    # the script folder, then the project root, then the current directory.
    llama_dir = find_llama_dir(args.llama_dir)
    tool = find_fit_tool(llama_dir)
    if not tool:
        if args.llama_dir:
            print(f"ERROR: llama-fit-params.exe not found in {args.llama_dir}.", file=sys.stderr)
        else:
            print("ERROR: llama-fit-params.exe not found. Searched the script folder, "
                  "the project root and the current directory. Pass --llama-dir <path> "
                  "to point at it explicitly.", file=sys.stderr)
        return 2
    gpu_ok = gpu_available(llama_dir)
    if not gpu_ok:
        print("WARN: no GPU backend detected by llama-server. The CUDA runtime DLLs "
              "(cudart64_12.dll, cublas64_12.dll, cublasLt64_12.dll) may be missing - "
              "context sizes will be sized for system RAM instead of VRAM.",
              file=sys.stderr)

    vram = free_vram_mib()
    if vram:
        free_mib, total_mib, used_mib = vram
    else:
        free_mib = total_mib = used_mib = 0
        print("WARN: nvidia-smi unavailable; cannot size to VRAM.", file=sys.stderr)

    # System RAM is the budget for the CPU fallback. Read it regardless of
    # whether a GPU is present, so the fallback path has a real number to
    # compare against instead of comparing RAM against itself.
    ram = free_system_ram_mib()
    if ram:
        print(f"System RAM: {ram[0]} MiB free of {ram[1]} MiB", file=sys.stderr)
    else:
        print("WARN: could not read system RAM; the CPU fallback cannot be sized.",
              file=sys.stderr)

    files = []
    # The default "models" is resolved the same way the rest of the project
    # resolves it: next to the script, or one level up (the project root).
    # A bare relative path would only work when the script happened to be run
    # from the project root.
    default_models = [str(Path(__file__).resolve().parent / "models"),
                      str(Path(__file__).resolve().parent.parent / "models")]
    for a in (args.models or default_models):
        p = Path(a)
        if not p.exists():
            continue
        if p.is_file():
            files.append(p)
        else:
            files += [q for q in p.rglob("*.gguf") if not q.name.startswith("mmproj-")]
    files = sorted(set(files), key=lambda x: x.stat().st_mtime, reverse=True)

    results = []
    for f in files:
        if not args.quiet and not args.json:
            print(f"\n=== {f.name} ===")
        r = analyse(f, tool, free_mib, total_mib, args.margin, args.kv_dtype,
                    verbose=(not args.quiet) and not args.json, gpu_ok=gpu_ok,
                    used_mib=used_mib, ram_mib=ram)
        results.append(r)
        if not args.quiet and not args.json:
            for n in r["notes"]:
                print(f"    note: {n}")
            # Report against the resource that actually limits the fit.
            # Without a GPU the model lives in system RAM, so quoting the VRAM
            # figures here would be misleading (it printed "GPU 0 MiB of
            # 9155 MiB usable" while sizing against a 31595 MiB RAM budget).
            cpu_mode = not r["gpu_active"]
            if r["recommended_ctx"]:
                if cpu_mode:
                    print(f"  >>> RECOMMENDED --ctx-size {r['recommended_ctx']}"
                          f"   (RAM {r['host_mib_at_recommended']} MiB of "
                          f"{r['ram_capacity_mib']} MiB usable)")
                else:
                    print(f"  >>> RECOMMENDED --ctx-size {r['recommended_ctx']}"
                          f"   (GPU {r['gpu_mib_at_recommended']} MiB of "
                          f"{r['capacity_mib']} MiB usable)")
            else:
                ctx, need = r["does_not_fit"] or (0, 0)
                if cpu_mode:
                    print(f"  >>> DOES NOT FIT: even ctx {ctx} needs {need} MiB"
                          f" (only {r['ram_capacity_mib']} MiB usable RAM)")
                else:
                    print(f"  >>> DOES NOT FIT: even ctx {ctx} needs {need} MiB"
                          f" (only {r['capacity_mib']} MiB usable)")
                print("      -> use a smaller quant, a smaller KV cache type (q8_0),"
                      " or --no-kv-offload")

    if args.json:
        print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
