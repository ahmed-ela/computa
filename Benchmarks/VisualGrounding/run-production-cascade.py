#!/usr/bin/env python3
"""Replay the retained 91-case corpus through the shipped worker protocol."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import select
import shutil
import signal
import statistics
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
DEFAULT_HOME = Path.home() / "Library/Application Support/LocalCodex/VisualGrounding"
METHOD_VERSION = "goclick-guiowl-showui-agreement-v2"
EXPECTED_REFUSAL = ("heldout", "zoom90", "preferences", "workspace-name")


def percentile(values, fraction):
    values = sorted(values)
    index = (len(values) - 1) * fraction
    low, high = math.floor(index), math.ceil(index)
    if low == high:
        return values[low]
    return values[low] * (high - index) + values[high] * (index - low)


def load_manifest(directory):
    items = json.loads((directory / "manifest.source.json").read_text())
    for item in items:
        item = dict(item)
        item["image"] = str((directory / Path(item["image"]).name).resolve(strict=True))
        yield item


def contains(box, point):
    return (
        box["x"] <= point["x"] <= box["x"] + box["width"]
        and box["y"] <= point["y"] <= box["y"] + box["height"]
    )


def read_line(stream, timeout, label):
    readable, _, _ = select.select([stream], [], [], timeout)
    if not readable:
        raise TimeoutError(f"timed out waiting for {label}")
    line = stream.readline()
    if not line:
        raise RuntimeError(f"worker exited while waiting for {label}")
    return line


def stop_process(process):
    if process.poll() is not None:
        return
    for action, timeout in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=timeout)
            return
        except subprocess.TimeoutExpired:
            continue
    raise RuntimeError("visual-grounding worker did not exit after SIGKILL")


def stderr_tail(handle, limit=16 * 1024):
    handle.flush()
    handle.seek(0, os.SEEK_END)
    size = handle.tell()
    handle.seek(max(0, size - limit))
    return handle.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, default=DEFAULT_HOME / "venv/bin/python")
    parser.add_argument("--model-root", type=Path, default=DEFAULT_HOME / "models")
    parser.add_argument(
        "--worker",
        type=Path,
        default=PROJECT / "Sources/Computa/Resources/VisualGrounding/worker.py",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--expected-hits", type=int, default=90)
    parser.add_argument("--expected-refusals", type=int, default=1)
    args = parser.parse_args()

    corpus = [
        *(dict(item, cohort="development") for item in load_manifest(ROOT / "development")),
        *(dict(item, cohort="heldout") for item in load_manifest(ROOT / "heldout")),
    ]
    with tempfile.TemporaryDirectory(prefix="localcodex-grounder-requests-") as directory:
        request_root = Path(directory)
        command = [
            str(args.python),
            str(args.worker),
            "--model-root", str(args.model_root),
            "--request-root", str(request_root),
            "--warmup-image", str(ROOT / "development/base-dashboard.png"),
        ]
        started = time.perf_counter()
        stderr_log = (request_root / "worker.stderr.log").open("w+", encoding="utf-8")
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_log,
            text=True,
            bufsize=1,
            start_new_session=True,
            env={
                "HOME": str(args.model_root.parent),
                "TMPDIR": str(request_root),
                "PATH": f"{args.model_root.parent}/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PYTHONUNBUFFERED": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1",
                "PYTHONPATH": "",
                "HF_HUB_OFFLINE": "1",
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "TOKENIZERS_PARALLELISM": "false",
            },
        )
        try:
            ready = json.loads(read_line(process.stdout, 30, "worker readiness"))
            if ready.get("type") != "ready" or ready.get("method_version") != METHOD_VERSION:
                raise RuntimeError(f"unexpected ready response: {ready}")
            ready_wall_seconds = time.perf_counter() - started
            rows = []
            for index, item in enumerate(corpus):
                image = request_root / f"{index:03d}.png"
                shutil.copyfile(item["image"], image)
                request_id = str(uuid.uuid4())
                request = {
                    "id": request_id,
                    "method": "ground",
                    "image_path": str(image),
                    "target": item["instruction"],
                }
                request_started = time.perf_counter()
                process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
                process.stdin.flush()
                response = json.loads(read_line(process.stdout, 65, f"response {index}"))
                request_latency_ms = (time.perf_counter() - request_started) * 1000
                if response.get("id") != request_id:
                    raise RuntimeError(f"worker response ID mismatch: {response}")
                accepted = response.get("ok") is True
                error_code = None if accepted else response.get("error_code")
                point = response.get("point") if accepted else None
                hit = accepted and contains(item["target_box"], point)
                safe_refusal = error_code == "no_pair_agreement"
                row = {
                    "cohort": item["cohort"],
                    "variant": item["variant"],
                    "screen": item["screen"],
                    "target": item["target"],
                    "instruction": item["instruction"],
                    "target_box": item["target_box"],
                    "point": point,
                    "hit": hit,
                    "safe_refusal": safe_refusal,
                    "error_code": error_code,
                    "error": response.get("error") if not accepted else None,
                    "used_showui": response.get("used_showui"),
                    "selected_pair": response.get("selected_pair"),
                    "worker_latency_ms": response.get("latency_ms"),
                    "request_latency_ms": request_latency_ms,
                }
                rows.append(row)
                print(
                    json.dumps(
                        {
                            "index": index,
                            "cohort": row["cohort"],
                            "variant": row["variant"],
                            "target": row["target"],
                            "hit": hit,
                            "safe_refusal": row["safe_refusal"],
                            "used_showui": row["used_showui"],
                            "request_latency_ms": request_latency_ms,
                        }
                    ),
                    flush=True,
                )
            shutdown_id = str(uuid.uuid4())
            process.stdin.write(json.dumps({"id": shutdown_id, "method": "shutdown"}) + "\n")
            process.stdin.flush()
            shutdown = json.loads(read_line(process.stdout, 20, "shutdown response"))
            process.wait(timeout=20)
            if process.returncode != 0 or shutdown.get("ok") is not True:
                raise RuntimeError(
                    stderr_tail(stderr_log) or f"worker shutdown failed: {shutdown}"
                )
        finally:
            stop_process(process)
            for stream in (process.stdin, process.stdout):
                stream.close()
            stderr_log.close()

    request_latencies = [row["request_latency_ms"] for row in rows]
    worker_latencies = [
        row["worker_latency_ms"] for row in rows if row["worker_latency_ms"] is not None
    ]
    payload = {
        "schema_version": 1,
        "method_version": ready["method_version"],
        "tasks": len(rows),
        "hits": sum(row["hit"] for row in rows),
        "safe_refusals": sum(row["safe_refusal"] for row in rows),
        "showui_calls": sum(row["used_showui"] is True for row in rows),
        "request_latency_p50_ms": statistics.median(request_latencies),
        "request_latency_p95_ms": percentile(request_latencies, 0.95),
        "worker_latency_p50_ms": statistics.median(worker_latencies),
        "worker_latency_p95_ms": percentile(worker_latencies, 0.95),
        "worker_load_seconds": ready.get("load_seconds"),
        "worker_warmup_seconds": ready.get("warmup_seconds"),
        "ready_wall_seconds": ready_wall_seconds,
        "wall_seconds": time.perf_counter() - started,
        "rows": rows,
    }
    if args.output:
        args.output.write_text(json.dumps(payload, indent=2) + "\n")
    print("SUMMARY=" + json.dumps({k: v for k, v in payload.items() if k != "rows"}))
    refusals = {
        (row["cohort"], row["variant"], row["screen"], row["target"])
        for row in rows
        if row["safe_refusal"]
    }
    unexpected_errors = [
        row for row in rows if not row["hit"] and not row["safe_refusal"]
    ]
    if (
        payload["hits"] != args.expected_hits
        or payload["safe_refusals"] != args.expected_refusals
        or refusals != {EXPECTED_REFUSAL}
        or unexpected_errors
    ):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
