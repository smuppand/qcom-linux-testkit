#!/usr/bin/env python3
# send_to_lava.py — parse *.res files and report to LAVA robustly
# SPDX-License-Identifier: BSD-3-Clause-Clear

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1B\[[0-9;]*[ -/]*[@-~]")

# Patterns we support:
# 1) Pre-existing signal line:
# <<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=name RESULT=PASS>>>
SIGNAL_RE = re.compile(
    r".*LAVA_SIGNAL_TESTCASE.*TEST_CASE_ID=([^\s>]+).*RESULT=([A-Za-z]+)", re.I
)

# 2) Key=Value line:
# TEST_CASE_ID=name RESULT=PASS [noise...]
KV_RE = re.compile(
    r".*TEST_CASE_ID=([^\s>]+).*RESULT=([A-Za-z]+)", re.I
)

# 3) "NAME: RESULT"
NAME_COLON_RE = re.compile(
    r"^\s*([^:\s][^:]*)\s*:\s*([A-Za-z]+)", re.I
)

# 4) "NAME RESULT"
NAME_SPACE_RE = re.compile(
    r"^\s*([^\s]+)\s+([A-Za-z]+)", re.I
)

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)

def normalize_result(token: str) -> str:
    # Keep only leading letters, map common aliases
    t = re.match(r"^[A-Za-z]+", token or "")
    res = (t.group(0) if t else "").upper()
    if res in {"PASS", "FAIL", "SKIP"}:
        return res
    if res == "XFAIL":
        return "PASS"
    if res in {"ERROR", "ABORT"}:
        return "FAIL"
    return ""

def parse_line(line: str):
    """Return (testcase, result) or None if not parseable."""
    if not line:
        return None
    s = strip_ansi(line).strip()
    if not s:
        return None

    # Pre-existing signal
    m = SIGNAL_RE.match(s)
    if m:
        tc, res = m.group(1), normalize_result(m.group(2))
        return (tc, res) if (tc and res) else None

    # TEST_CASE_ID=... RESULT=...
    m = KV_RE.match(s)
    if m:
        tc, res = m.group(1), normalize_result(m.group(2))
        return (tc, res) if (tc and res) else None

    # NAME: RESULT
    m = NAME_COLON_RE.match(s)
    if m:
        tc, res = m.group(1).strip(), normalize_result(m.group(2))
        return (tc, res) if (tc and res) else None

    # NAME RESULT
    m = NAME_SPACE_RE.match(s)
    if m:
        tc, res = m.group(1).strip(), normalize_result(m.group(2))
        return (tc, res) if (tc and res) else None

    return None

def emit_signal(name: str, result: str, prefix: str):
    # Guard with blank lines so log glue doesn't break parsing
    sys.stdout.write(
        f"\n<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID={prefix}{name} RESULT={result}>>>\n\n"
    )
    sys.stdout.flush()

def emit_result(name: str, result: str, prefix: str, force_signal: bool):
    use_lava_cmd = (not force_signal) and (shutil.which("lava-test-case") is not None)
    if use_lava_cmd:
        # Call lava-test-case; don't fail script if it returns non-zero
        import subprocess
        mapped = {"PASS": "pass", "FAIL": "fail", "SKIP": "skip"}[result]
        try:
            subprocess.run(
                ["lava-test-case", f"{prefix}{name}", "--result", mapped],
                check=False,
            )
        except Exception as exc:
            eprint(f"[WARN] lava-test-case failed: {exc}; falling back to signal")
            emit_signal(name, result, prefix)
    else:
        emit_signal(name, result, prefix)

def collect_files(root: Path, files_cli):
    files = []
    if files_cli:
        for f in files_cli:
            p = Path(f)
            if p.is_file():
                files.append(p)
    else:
        for p in root.rglob("*.res"):
            if p.is_file():
                files.append(p)
    return files

def main():
    ap = argparse.ArgumentParser(
        description="Parse .res files and report results to LAVA",
        add_help=False,
    )
    ap.add_argument("-r", dest="root", default=".", help="Root to search (default: .)")
    ap.add_argument("-f", dest="files", action="append", help="Result file (repeatable)")
    ap.add_argument("-p", dest="prefix", default="", help="Prefix for test names")
    ap.add_argument("--no-exit-on-fail", dest="exit_on_fail", action="store_false",
                    help="Do not exit(1) when any test FAILs")
    ap.add_argument("--quiet", dest="quiet", action="store_true",
                    help="Reduce stderr chatter")
    ap.add_argument("--no-summary", dest="no_summary", action="store_true",
                    help="Do not print summary")
    ap.add_argument("--force-signal", dest="force_signal", action="store_true",
                    help="Emit raw signals even if lava-test-case exists")
    ap.add_argument("-h", "--help", action="help", help="Show help and exit")

    args, unknown = ap.parse_known_args()

    # Back-compat: treat any extra existing file args as -f
    extra_files = [u for u in unknown if Path(u).is_file()]
    if extra_files:
        if args.files is None:
            args.files = []
        args.files.extend(extra_files)

    root = Path(args.root)
    files = collect_files(root, args.files)

    if not args.quiet:
        eprint(f"Current working directory is {os.getcwd()}")
    if not files:
        if not args.quiet:
            eprint(f"No .res files found under '{root}'. Nothing to do.")
        return 0

    total = passes = fails = skips = 0

    for res_file in files:
        if not args.quiet:
            eprint(f"Parsing: {res_file}")
        try:
            with open(res_file, "r", encoding="utf-8", errors="replace") as fh:
                for raw in fh:
                    # Allow comments like '# ...'
                    if raw.lstrip().startswith("#"):
                        continue
                    parsed = parse_line(raw.rstrip("\n"))
                    if not parsed:
                        # Avoid spam unless very verbose; still warn once per malformed
                        # You can uncomment if you want strict mode:
                        # eprint(f"[WARN] Skipping malformed line: {raw.rstrip()}")
                        continue
                    name, res = parsed
                    if not res:
                        # Unknown/unsupported result token; skip
                        continue
                    emit_result(name, res, args.prefix, args.force_signal)
                    total += 1
                    if res == "PASS":
                        passes += 1
                    elif res == "FAIL":
                        fails += 1
                    elif res == "SKIP":
                        skips += 1
        except FileNotFoundError:
            eprint(f"[WARN] Not a file: {res_file}")
            continue

    if not args.no_summary and not args.quiet:
        mode = "lava-test-case" if (not args.force_signal and shutil.which("lava-test-case")) else "signals"
        eprint(f"Summary: TOTAL={total} PASS={passes} FAIL={fails} SKIP={skips} (mode: {mode})")

    if args.exit_on_fail is False:
        return 0
    return 1 if fails > 0 else 0

if __name__ == "__main__":
    sys.exit(main())
