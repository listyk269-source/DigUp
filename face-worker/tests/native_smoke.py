"""Real-model integration check. Python is a test driver, never an app dependency.

Uses the official NASA S69-31739 crew fixture (no names/identity labels). Supply
the already downloaded fixture and pinned models/runtime; this script has no
network calls, simulated embeddings or substitutes for a failed GPU.
"""
import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import zlib

FIXTURE_SHA = "ba9ccc7c8accc044ebe71fbe402255d45f4cb0fec67f2c9afbfb4ed71d671784"
MODEL_ID = "yunet-2023mar-sface-2021dec-rgbraw-align112-v1"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def cosine(a, b):
    return sum(x * y for x, y in zip(a, b))


def blank_png(path):
    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))
    pixels = (b"\x00" + b"\x00" * (512 * 3)) * 512
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 512, 512, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def run(worker, models, runtime, device, image, blank, corrupt, overrides=None):
    env = os.environ.copy()
    win = env.get("SystemRoot", r"C:\Windows")
    env["PATH"] = str(Path(win) / "System32") + os.pathsep + win
    for key in ("DIGUP_CPU_ONLY", "DIGUP_FACE_DISABLE_GPU", "DIGUP_FACE_GPU_DEVICE"):
        env.pop(key, None)
    env.update(overrides or {})
    requests = [
        {"id": 1, "op": "analyze", "path": str(image)},
        {"id": 2, "op": "analyze", "path": str(image), "max_faces": 2},
        {"id": 3, "op": "analyze", "path": str(blank)},
        {"id": 4, "op": "analyze", "path": str(corrupt)},
        {"id": 5, "op": "info"},
    ]
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    payload += "x" * 17000 + "\n" + json.dumps({"id": 6, "op": "info"}) + "\n" + json.dumps({"id": 7, "op": "quit"}) + "\n"
    started = time.monotonic()
    completed = subprocess.run([str(worker), "--models", str(models), "--runtime", str(runtime), "--device", device], input=payload, capture_output=True, text=True, encoding="utf-8", env=env, timeout=120)
    require(completed.returncode == 0, "worker process failed: " + completed.stdout[:200])
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    ready = lines[0]
    require(ready.get("event") == "ready" and ready.get("ok"), "worker did not become ready")
    require(ready["model_id"] == MODEL_ID and ready["dimension"] == 128, "incompatible model identity")
    responses = {r["id"]: r for r in lines[1:] if r.get("id") is not None}
    require(responses[1]["ok"] and len(responses[1]["faces"]) == 3, "expected three actual crew faces")
    require(responses[2]["ok"] and len(responses[2]["faces"]) == 2, "max_faces was not respected")
    require(responses[3]["ok"] and not responses[3]["faces"], "blank PNG produced a face")
    require(not responses[4]["ok"] and responses[5]["ok"], "damaged JPEG terminated the worker")
    require(any(not r.get("ok") and r.get("id") is None for r in lines), "oversized line was not rejected")
    require(responses[6]["ok"] and responses[7]["ok"], "worker did not recover after oversized line")
    faces = responses[1]["faces"]
    for face in faces:
        require(len(face["embedding"]) == 128, "invalid feature dimension")
        require(all(math.isfinite(v) for v in face["embedding"]), "nonfinite embedding")
        require(abs(math.sqrt(cosine(face["embedding"], face["embedding"])) - 1.0) < 1e-5, "embedding was not normalized")
        require(all(0 <= v <= 1 for v in face["bbox"] + face["landmarks"]), "geometry not normalized")
    distinct = [cosine(a["embedding"], b["embedding"]) for a, b in itertools.combinations(faces, 2)]
    require(max(distinct) < 0.363, "the three fixture subjects were not separated")
    actual = responses[1]
    return {"device": actual["device"], "backend": actual["backend"], "fallback_reason": actual["fallback_reason"], "startup_device": ready["device"], "final_device": responses[5]["device"], "model_id": actual["model_id"], "faces": len(faces), "seconds": time.monotonic() - started, "different_face_cosines": distinct, "stderr_empty": not completed.stderr}, faces


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--require-gpu", action="store_true")
    args = parser.parse_args()
    for name in ("worker", "models", "runtime", "image", "output"):
        setattr(args, name, getattr(args, name).resolve())
    require(hashlib.sha256(args.image.read_bytes()).hexdigest() == FIXTURE_SHA, "use the pinned official NASA S69-31739 fixture")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="face native ", dir=args.output.parent) as temp:
        directory = Path(temp)
        image = directory / "Фото с пробелами и Unicode 漢字.jpg"
        shutil.copyfile(args.image, image)
        blank = directory / "пустой.png"
        corrupt = directory / "поврежденный.jpg"
        blank_png(blank)
        corrupt.write_bytes(b"\xff\xd8bad truncated JPEG\x00")
        report = {"fixture_sha256": FIXTURE_SHA, "network": False, "path_limited_to_windows": True, "checks": ["three real faces", "distinct subjects", "unit embeddings", "maximum face count", "blank image", "corrupt image recovery", "bounded JSONL recovery", "Unicode and space paths"]}
        cpu, reference = run(args.worker, args.models, args.runtime, "cpu", image, blank, corrupt)
        gpu, gpu_faces = run(args.worker, args.models, args.runtime, "gpu", image, blank, corrupt)
        if args.require_gpu:
            require(gpu["device"] == "gpu" and gpu["final_device"] == "gpu" and gpu["backend"] == "directml", "required actual DirectML inference was unavailable or fell back")
        pairs = []
        for face in reference:
            other = min(gpu_faces, key=lambda f: sum((f["bbox"][i] - face["bbox"][i]) ** 2 for i in range(4)))
            pairs.append(cosine(face["embedding"], other["embedding"]))
        require(min(pairs) > 0.999, "CPU and GPU features are incompatible")
        disabled, _ = run(args.worker, args.models, args.runtime, "gpu", image, blank, corrupt, {"DIGUP_FACE_DISABLE_GPU": "1"})
        override, _ = run(args.worker, args.models, args.runtime, "gpu", image, blank, corrupt, {"DIGUP_CPU_ONLY": "1", "DIGUP_FACE_DISABLE_GPU": "1", "DIGUP_FACE_GPU_DEVICE": "invalid ignored with CPU override"})
        require(disabled["device"] == "cpu" and "DIGUP_FACE_DISABLE_GPU" in disabled["fallback_reason"], "explicit fallback was not reported")
        require(override["device"] == "cpu" and override["fallback_reason"] == "DIGUP_CPU_ONLY override", "CPU override did not win")
        invalid_adapter, _ = run(args.worker, args.models, args.runtime, "gpu", image, blank, corrupt, {"DIGUP_FACE_GPU_DEVICE": "31"})
        require(invalid_adapter["device"] == "cpu" and invalid_adapter["fallback_reason"], "unavailable actual DirectML adapter did not fall back to CPU")
        # An actual unavailable DirectML dependency, without disabling inference.
        # The system may have DirectML installed itself; record that case honestly.
        runtime_dir = directory / "runtime without DirectML"
        runtime_dir.mkdir()
        runtime = runtime_dir / args.runtime.name
        shutil.copyfile(args.runtime, runtime)
        shared = args.runtime.parent / "onnxruntime_providers_shared.dll"
        if shared.is_file():
            shutil.copyfile(shared, runtime_dir / shared.name)
        absent, _ = run(args.worker, args.models, runtime, "gpu", image, blank, corrupt)
        if absent["device"] == "cpu":
            require(absent["fallback_reason"], "real provider failure had no fallback reason")
        report.update({"passed": True, "cpu": cpu, "gpu": gpu, "cpu_gpu_cosines": pairs, "disabled_gpu": disabled, "cpu_override": override, "unavailable_directml_adapter": invalid_adapter, "missing_packaged_directml": absent})
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"passed": True, "cpu_faces": cpu["faces"], "gpu_device": gpu["device"], "minimum_cpu_gpu_cosine": min(pairs), "missing_dll_device": absent["device"], "report": str(args.output)}, ensure_ascii=True))


if __name__ == "__main__":
    main()
