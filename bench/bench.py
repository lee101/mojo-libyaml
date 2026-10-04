"""Benchmark the Mojo port against upstream libyaml.

Two levels, both timed through ctypes on identical buffers:

  kernel  the C ABI alone -- libyaml_scan_all / libyaml_parse_events against
          ref_scan / ref_parse.  bench/ref_driver.c mirrors src/capi.mojo
          exactly: the same flat int64 records and the same flat payload
          arena, so neither side gets a copy the other pays for.  This is the
          apples-to-apples number.
  api     the Python surface the package exposes, my.scan(data) and
          my.parse_events(data), against PyYAML's bundled libyaml CParser
          running yaml.parse on the same bytes.  Object construction on the
          Python side is included, which is where the Mojo port's own overhead
          shows up.

Upstream libyaml is built once from the vendored source into bench/.cache and
reused; later runs only load it.
"""

from __future__ import annotations

import ctypes
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

CACHE = ROOT / "bench" / ".cache"
UPSTREAM = Path(
    os.environ.get("LIBYAML_SRC", "/nvme0n1-disk/code/vendor-src/libyaml")
)

CAPACITY = 1 << 16
FIELDS = 16
PAYLOAD = 1 << 22

I = ctypes.c_int64


def _build_reference() -> Path:
    prefix = CACHE / "libyaml"
    lib = prefix / "lib" / "libyaml.so"
    driver = CACHE / "libref_driver.so"
    if lib.exists() and driver.exists():
        return driver
    CACHE.mkdir(parents=True, exist_ok=True)
    if not lib.exists():
        build = CACHE / "build"
        build.mkdir(exist_ok=True)
        subprocess.run(
            [
                "cmake",
                str(UPSTREAM),
                "-DCMAKE_BUILD_TYPE=Release",
                "-DBUILD_SHARED_LIBS=ON",
                f"-DCMAKE_INSTALL_PREFIX={prefix}",
            ],
            cwd=build,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["make", "-j", "8", "install"],
            cwd=build,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    subprocess.run(
        [
            "cc",
            "-O3",
            "-fPIC",
            "-shared",
            "-o",
            str(driver),
            str(ROOT / "bench" / "ref_driver.c"),
            f"-I{prefix / 'include'}",
            f"-L{prefix / 'lib'}",
            "-lyaml",
        ],
        check=True,
    )
    return driver


def _reference() -> ctypes.CDLL:
    handle = ctypes.CDLL(str(_build_reference()))
    kernel_args = [
        ctypes.c_void_p,
        I,
        ctypes.c_void_p,
        I,
        ctypes.c_void_p,
        I,
    ]
    handle.ref_scan.argtypes = kernel_args
    handle.ref_scan.restype = I
    handle.ref_parse.argtypes = kernel_args
    handle.ref_parse.restype = I
    handle.ref_arena_used.restype = I
    handle.ref_version.restype = I
    return handle


# --------------------------------------------------------------------------
# Corpus
# --------------------------------------------------------------------------

WORDS = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliett", "kilo", "lima", "mike", "november", "oscar", "papa",
]


def plain_map(entries: int) -> bytes:
    return "".join(
        f"key_{i}: value_{WORDS[i % 16]}_{i}\n" for i in range(entries)
    ).encode()


def flow_doc(entries: int) -> bytes:
    body = ", ".join(
        f"{{name: {WORDS[i % 16]}, value: {i}, tags: [{i}, {i + 1}]}}"
        for i in range(entries)
    )
    return ("root: [" + body + "]\n").encode()


def quoted_doc(entries: int) -> bytes:
    return "".join(
        f'item_{i}: "a \\"quoted\\" value {WORDS[i % 16]} '
        f"with \\u00e9 and \\t tab {i}\"\n"
        for i in range(entries)
    ).encode()


def block_scalar(entries: int) -> bytes:
    out = ["header: value\n", "literal: |\n"]
    out += [f"  line {i} of {WORDS[i % 16]} block scalar text\n" for i in range(entries)]
    out.append("folded: >\n")
    out += [f"  folded line {i} text\n" for i in range(entries)]
    return "".join(out).encode()


def anchors_doc(entries: int) -> bytes:
    return "".join(f"- &a{i} value_{i}\n- *a{i}\n" for i in range(entries)).encode()


def comments_doc(entries: int) -> bytes:
    return "".join(
        f"# comment {i} about {WORDS[i % 16]}\nkey_{i}: {i}  # trailing\n"
        for i in range(entries)
    ).encode()


def unicode_doc(entries: int) -> bytes:
    out = ["\u00e9t\u00e9: caf\u00e9\n"]
    out += [
        f"ligne_{i}: valeur \u00e0 \u00e9 \u00fc \u4e2d\u6587 {i}\n"
        for i in range(entries)
    ]
    return "".join(out).encode()


def mixed_doc(entries: int) -> bytes:
    return b"".join(
        [
            plain_map(entries),
            flow_doc(entries),
            quoted_doc(entries),
            comments_doc(entries),
            b"--- \n",
        ]
    )


CORPUS = [
    ("plain_map_2k", plain_map(2000)),
    ("plain_map_50k", plain_map(50000)),
    ("flow_500", flow_doc(500)),
    ("quoted_2k", quoted_doc(2000)),
    ("block_scalar_1k", block_scalar(1000)),
    ("anchors_1k", anchors_doc(1000)),
    ("comments_2k", comments_doc(2000)),
    ("unicode_2k", unicode_doc(2000)),
    ("mixed_800", mixed_doc(800)),
]


# --------------------------------------------------------------------------
# Timing
# --------------------------------------------------------------------------


def _time(fn, repeat: int, budget: float) -> float:
    fn()
    best = float("inf")
    deadline = time.perf_counter() + budget
    rounds = 0
    while rounds < repeat or time.perf_counter() < deadline:
        start = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - start)
        rounds += 1
    return best


def bench_kernels(mojo, ref, repeat: int, budget: float) -> list[dict]:
    rows = []
    for name, document in CORPUS:
        copies = max(1, min(64, (4 << 20) // max(len(document), 1)))
        buffer = np.frombuffer(document + b"\x00", dtype=np.uint8)
        src, rec, st, pay = (
            buffer.ctypes.data,
            records.ctypes.data,
            status.ctypes.data,
            payload.ctypes.data,
        )
        length = len(document)

        def mojo_run(fn):
            def inner():
                for _ in range(copies):
                    fn(src, length, rec, CAPACITY, pay, PAYLOAD, st)

            return inner

        def ref_run(fn):
            def inner():
                for _ in range(copies):
                    fn(src, length, rec, CAPACITY, pay, PAYLOAD)

            return inner

        for kind, fn in (("scan", mojo.libyaml_scan_all),
                         ("parse", mojo.libyaml_parse_events)):
            ours = _time(mojo_run(fn), repeat, budget) / copies
            theirs = (
                _time(ref_run(getattr(ref, "ref_" + kind)), repeat, budget)
                / copies
            )
            rows.append(
                {
                    "doc": name,
                    "kind": kind,
                    "bytes": length,
                    "mojo": ours,
                    "ref": theirs,
                    "mojo_mibs": length / ours / (1024 * 1024),
                    "ref_mibs": length / theirs / (1024 * 1024),
                }
            )
    return rows


def bench_api(repeat: int, budget: float) -> list[dict]:
    import yaml

    import mojolibyaml as my

    rows = []
    for name, document in CORPUS:
        copies = max(1, min(8, (2 << 20) // max(len(document), 1)))

        def mine(kind):
            def inner():
                fn = my.scan if kind == "scan" else my.parse_events
                for _ in range(copies):
                    fn(document)

            return inner

        def theirs():
            def inner():
                for _ in range(copies):
                    list(yaml.parse(document, Loader=yaml.CSafeLoader))

            return inner

        scan = _time(mine("scan"), repeat, budget) / copies
        parse = _time(mine("parse"), repeat, budget) / copies
        reference = _time(theirs(), repeat, budget) / copies
        rows.append(
            {
                "doc": name,
                "bytes": len(document),
                "scan_api": scan,
                "parse_api": parse,
                "pyyaml_parse": reference,
            }
        )
    return rows


def main() -> None:
    repeat = int(os.environ.get("BENCH_REPEAT", "15"))
    budget = float(os.environ.get("BENCH_BUDGET", "0.3"))
    import mojolibyaml as my

    ref = _reference()
    print(f"upstream libyaml version code: {ref.ref_version()}  cpus: {os.cpu_count()}")
    print()

    kernels = bench_kernels(my.lib(), ref, repeat, budget)
    print("== kernel: C ABI only, identical record layout ==")
    print(
        f"{'document':<18}{'kind':<7}{'bytes':>9}{'mojo us':>10}{'ref us':>10}"
        f"{'mojo MiB/s':>12}{'ref MiB/s':>11}{'speedup':>9}"
    )
    speedups = []
    for row in kernels:
        speedup = row["ref"] / row["mojo"]
        speedups.append(speedup)
        print(
            f"{row['doc']:<18}{row['kind']:<7}{row['bytes']:>9}"
            f"{row['mojo'] * 1e6:>10.1f}{row['ref'] * 1e6:>10.1f}"
            f"{row['mojo_mibs']:>12.1f}{row['ref_mibs']:>11.1f}{speedup:>8.2f}x"
        )
    print(f"\ngeometric mean speedup: {statistics.geometric_mean(speedups):.2f}x\n")

    api = bench_api(repeat, budget)
    print("== python api: object construction included ==")
    print(
        f"{'document':<18}{'bytes':>9}{'scan us':>10}{'parse us':>10}"
        f"{'pyyaml parse us':>17}"
    )
    for row in api:
        print(
            f"{row['doc']:<18}{row['bytes']:>9}{row['scan_api'] * 1e6:>10.1f}"
            f"{row['parse_api'] * 1e6:>10.1f}{row['pyyaml_parse'] * 1e6:>17.1f}"
        )


if __name__ == "__main__":
    main()