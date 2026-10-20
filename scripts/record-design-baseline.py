"""Record an existing performance runner with explicit scope and resource bounds."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("runner", type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--large", action="store_true", help="Mixed 4K/8K fixture, not a frame-rate measurement")
parser.add_argument("--widescreen", action="store_true", help="Use 3840x2160 and 7680x4320 GPU scenes with --large")
parser.add_argument("--timeout", type=float, default=120)
parser.add_argument("--rss-limit-mib", type=int, default=4096)
args = parser.parse_args()
if not math.isfinite(args.timeout) or args.timeout <= 0 or args.rss_limit_mib <= 0:
    parser.error("Resource bounds must be positive.")
runner = args.runner.resolve(strict=True)
command = [str(runner)] + (["--large"] if args.large else []) + (["--widescreen"] if args.widescreen else [])
started = time.monotonic()
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
stop_reason = None
maximum_sample = 0
try:
    while process.poll() is None:
        elapsed = time.monotonic() - started
        if elapsed > args.timeout:
            stop_reason = "timeout"
        sample = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)],
                                capture_output=True, text=True, timeout=5)
        if sample.returncode == 0 and sample.stdout.strip():
            maximum_sample = max(maximum_sample, int(sample.stdout.strip()) * 1024)
        if maximum_sample > args.rss_limit_mib * 1024 * 1024:
            stop_reason = "rss_budget"
        if stop_reason:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
            break
        time.sleep(0.2)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
stdout, stderr = process.communicate(timeout=10)
wall = time.monotonic() - started
usage = resource.getrusage(resource.RUSAGE_CHILDREN)
# Darwin reports ru_maxrss in bytes; Linux reports KiB.
peak_rss = usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
metadata = {"system": platform.system(), "systemRelease": platform.release(), "architecture": platform.machine()}
if sys.platform == "darwin":
    for key in ["hw.model", "hw.memsize", "machdep.cpu.brand_string"]:
        value = subprocess.run(["sysctl", "-n", key], capture_output=True, text=True, timeout=5)
        if value.returncode == 0:
            metadata[key] = value.stdout.strip()
    version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=5)
    metadata["macOS"] = version.stdout.strip()
result = {
    "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
    "runnerName": runner.name,
    "runnerSHA256": hashlib.sha256(runner.read_bytes()).hexdigest(),
    "scenario": "widescreen-3840-2160-7680-4320" if args.large and args.widescreen else "mixed-square-4096-8192" if args.large else "square-4096-sparse-history-and-regressions",
    "exitCode": process.returncode,
    "stopReason": stop_reason,
    "wallSeconds": wall,
    "maximumResidentSetSizeBytes": peak_rss,
    "sampledMaximumRSSBytes": maximum_sample,
    "rssLimitMiB": args.rss_limit_mib,
    "timeoutSeconds": args.timeout,
    "metadata": metadata,
    "stdout": stdout,
    "stderr": stderr,
    "limitations": [
        "Fixture setup and regression checks are included; this is not input-to-photon or frame timing.",
        "RSS does not measure total GPU allocation or the application's full physical footprint.",
        "The large runner contains multiple scenes; flushed STAGE markers identify the last reached phase.",
    ],
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(f"Recorded {result['scenario']}: exit={process.returncode}, stop={stop_reason}, wall={wall:.3f}s, peak RSS={peak_rss / 1024 / 1024:.1f} MiB")
print(stdout, end="")
if process.returncode != 0 or stop_reason:
    raise SystemExit(1)
