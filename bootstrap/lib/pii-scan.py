#!/usr/bin/env python3
"""pii-scan — local PII detector using Microsoft Presidio + spaCy.

    pii-scan [--mode gate|review] [--format json|text] FILE     (or - for stdin)
    pii-scan --selftest
    pii-scan --list-entities
    pii-scan --serve REQ_FIFO RESP_FIFO CALLER_PID   (warm server for one caller; protocol below)

EXIT CODES ARE THE CONTRACT:
    0  scanned, no findings
    1  scanned, FINDINGS PRESENT   <- the only code meaning PII was seen
    2  CANNOT-CHECK — the scan did not happen, or cannot be trusted

2 never means clean. A caller mapping 2 onto 0 has built a fail-open gate.

WHY THERE ARE ALMOST NO OPTIONS. Every silent-blindness bug this tool has had
came from a knob that narrowed the scan to nothing: an entity allowlist that
omitted US_PASSPORT, a confidence threshold above the 0.85 NER ceiling, an
--entities list cancelled by an --exclude-entities list. Guarding each knob
grows the defect surface; deleting them ends it. So the scan is two fixed
presets, and neither caller can tune it into blindness.

AND ONE INVARIANT COVERS THE REST. Before reporting any result, the exact
configured pipeline scans a canary containing a known name and email address. If the
configuration cannot find those, the configuration is blind and the answer is
CANNOT-CHECK — whatever the cause, including causes nobody anticipated.

--serve keeps the model loaded for one caller and scans one file per request,
through the same scan_one() as a cold run, so the bytes are identical. Mode is
fixed to gate/json. Protocol (bootstrap/PII-SCAN-CONTRACT.md):
    after the model loads and one canary passes:  READY<TAB><pid><LF>
    request  <seq><TAB><input-path><TAB><out-prefix><LF>
    the server writes <out-prefix>.json and .err in full, closes them, then
    reply    <seq><TAB><rc><LF>   (one os.write, < PIPE_BUF, so never half a line)
A malformed request ends the server (exit 2); EOF on the request FIFO ends it
(exit 0); it also ends when CALLER_PID goes away or the server's parent does
(exit 2, polled every 0.5 s from before the FIFOs are opened, so a caller killed
before it opened its end cannot strand the server in open()). The
caller trusts only rc 0/1 with a non-empty .json; everything else reruns cold.
"""
import argparse
import io
import json
import os
import sys
import threading
import time
from collections import Counter

EXIT_CLEAN, EXIT_FINDINGS, EXIT_CANNOT_CHECK = 0, 1, 2

SPACY_MODEL = os.environ.get("PII_SCAN_SPACY_MODEL", "en_core_web_lg")

# spaCy's NER cap is 1M chars; scan longer input in overlapping windows.
# Windows are kept small because peak RSS scales with window size, not file size.
CHUNK_SIZE, CHUNK_OVERLAP = 100_000, 2_000

# Synthetic, RFC-2606. Every scan proves the live pipeline still finds these.
CANARY = "Contact Jane Q. Doe at jane.doe@example.com, 1400 Maple Avenue."
# PERSON is the NER-dependent assertion; EMAIL_ADDRESS is a pattern recognizer
# and would fire even with no model, so it alone proves nothing.
CANARY_REQUIRED = ("PERSON", "EMAIL_ADDRESS")

# Types that fire constantly on ordinary prose and code and carry no
# genericization signal (ORGANIZATION is the noisiest on source; measurements:
# PII-SCAN-CONTRACT.md, "Precision"). URL is deliberately NOT here: a signed,
# tokenized or internal link is a leak class a publishing gate exists to catch.
GATE_NOISE = ("DATE_TIME", "NRP", "ORGANIZATION")

# Two presets, no free-form tuning.
#   gate   — publishing gate: suppress noise so a human can read the findings.
#   review — human privacy review of one document: show everything. A date of
#            birth or a tracking URL is signal here even though it is noise above.
MODES = {
    "gate": {"threshold": 0.4, "noise": GATE_NOISE},
    "review": {"threshold": 0.3, "noise": ()},
}


def cannot_check(msg, err=None):
    print(f"pii-scan CANNOT-CHECK: {msg}", file=err or sys.stderr)
    return EXIT_CANNOT_CHECK


def build_analyzer():
    """Presidio against the pinned, already-installed model.

    The is_package check must happen first: Presidio's spaCy engine calls
    spacy.cli.download() for a missing model, which would turn a scan — or an
    unattended gate — into an unannounced ~430MB fetch.
    """
    import spacy

    if not spacy.util.is_package(SPACY_MODEL):
        raise RuntimeError(
            f"spaCy model '{SPACY_MODEL}' is not installed, and auto-download "
            f"is refused. Run bootstrap/lib/install-pii-scan.sh"
        )
    from presidio_analyzer import AnalyzerEngine
    from presidio_analyzer.context_aware_enhancers import LemmaContextAwareEnhancer
    from presidio_analyzer.nlp_engine import NlpEngineProvider

    engine = NlpEngineProvider(nlp_configuration={
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": SPACY_MODEL}],
    }).create_engine()
    # Context words count on either side: "000123456 is my ssn" (label after the number) scores like
    # "my ssn is 000123456" (the number is illustrative: Presidio never scores a 000- area, so a fixture that must
    # fire uses a harness-only value). Presidio's default looks back 5 words and ahead 0.
    return AnalyzerEngine(nlp_engine=engine, context_aware_enhancer=LemmaContextAwareEnhancer(
        context_prefix_count=5, context_suffix_count=5))


def scan(analyzer, text, threshold, noise):
    """Analyze text of any length. Returns findings, noise already dropped."""
    raw = []
    start = 0
    while True:
        window = text[start:start + CHUNK_SIZE]
        for r in analyzer.analyze(text=window, language="en",
                                  score_threshold=threshold):
            raw.append((r.entity_type, r.start + start, r.end + start, r.score))
        if start + CHUNK_SIZE >= len(text):
            break
        start += CHUNK_SIZE - CHUNK_OVERLAP

    # Drop spans contained in a longer span of the same type: a window edge can
    # truncate an entity that the next window sees whole.
    raw.sort(key=lambda f: (f[0], f[1], -(f[2] - f[1])))
    kept = []
    for f in raw:
        if any(k[0] == f[0] and k[1] <= f[1] and f[2] <= k[2] for k in kept):
            continue
        kept.append(f)
    kept.sort(key=lambda f: f[1])

    return [
        {"entity_type": t, "start": s, "end": e, "score": round(sc, 3),
         "text": text[s:e]}
        for (t, s, e, sc) in kept if t not in noise
    ]


def canary_ok(analyzer, threshold, noise):
    """Does THIS configuration still detect known PII? Returns None or a reason."""
    found = {f["entity_type"] for f in scan(analyzer, CANARY, threshold, noise)}
    missing = [e for e in CANARY_REQUIRED if e not in found]
    if missing:
        return (f"this configuration did not detect {missing} in the canary "
                f"(saw {sorted(found) or 'nothing'}). The scan would have been "
                f"blind, so its result cannot be trusted.")
    return None


def read_input(path):
    if path == "-":
        if sys.stdin is None:
            raise OSError("stdin is closed")
        # Pin UTF-8: inheriting the locale's encoding makes the same bytes scan
        # differently (and sometimes clean) depending on the environment.
        return io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8").read(), "<stdin>"
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read(), path


def scan_one(analyzer, args, path, out, err):
    """Scan one input and write its result to the given streams. Cold runs pass
    sys.stdout/sys.stderr; --serve passes the files it opened. One code path,
    so a warm answer is byte-identical to a cold one."""
    preset = MODES[args.mode]
    threshold, noise = preset["threshold"], preset["noise"]

    try:
        text, source = read_input(path)
    except OSError as exc:
        return cannot_check(f"could not read input: {exc}", err)
    except UnicodeDecodeError as exc:
        return cannot_check(f"input is not valid UTF-8 text: {exc}", err)

    if "\x00" in text:
        return cannot_check(
            f"input {source} contains NUL bytes — it is almost certainly UTF-16 "
            f"or binary, not UTF-8 text. It would decode into gibberish that "
            f"scans as clean while hiding real identifiers.", err)

    if not text.strip() and not args.allow_empty:
        return cannot_check(
            f"input {source} is empty — nothing was scanned. An empty read "
            f"usually means the producer failed (bad git ref, mis-quoted path). "
            f"Pass --allow-empty if emptiness is genuinely expected.", err)

    why = canary_ok(analyzer, threshold, noise)
    if why:
        return cannot_check(why, err)

    findings = scan(analyzer, text, threshold, noise)
    summary = Counter(f["entity_type"] for f in findings)

    if args.format == "json":
        json.dump({"source": source, "char_count": len(text),
                   "model": SPACY_MODEL, "mode": args.mode,
                   "findings": findings, "summary": dict(summary)},
                  out, indent=2)
        out.write("\n")
    else:
        print(f"PII scan: {source} ({len(text)} chars, {SPACY_MODEL}, mode {args.mode})", file=out)
        if not findings:
            print("  no findings", file=out)
        else:
            print(f"  {len(findings)} findings:", file=out)
            for t, c in summary.most_common():
                print(f"    {c:>3}x {t}", file=out)
            print("\n  detail:", file=out)
            for f in findings:
                snip = f["text"].replace("\n", " ")
                snip = snip[:57] + "..." if len(snip) > 60 else snip
                print(f"    [{f['score']:.2f}] {f['entity_type']:<20} "
                      f"@{f['start']:>5}: {snip}", file=out)
    out.flush()

    return EXIT_FINDINGS if (findings and not args.exit_zero) else EXIT_CLEAN


def run(args):
    analyzer = build_analyzer()

    if args.list_entities:
        print("\n".join(sorted(analyzer.get_supported_entities())))
        return EXIT_CLEAN

    if args.selftest:
        preset = MODES[args.mode]
        why = canary_ok(analyzer, preset["threshold"], preset["noise"])
        if why:
            return cannot_check(why)
        print(f"pii-scan selftest OK — model {SPACY_MODEL}, mode {args.mode}")
        return EXIT_CLEAN

    if not args.input:
        return cannot_check("no input given (pass a file path or '-' for stdin)")

    return scan_one(analyzer, args, args.input, sys.stdout, sys.stderr)


def _open_out(name):
    # mode 0600 whatever the umask; truncate, as a shell `>` would
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    return io.open(fd, "w", encoding="utf-8", errors="backslashreplace")


def serve(args):
    """Warm server for exactly one caller. Strict lock-step: one request in,
    one reply out. Anything off ends the server; the caller then scans cold."""
    req_path, resp_path, caller = args.serve
    parent = os.getppid()   # first, before the model import: an orphan must not outlive its caller
    if not caller.isdigit() or not caller.isascii() or int(caller) <= 1:
        return cannot_check(f"--serve: CALLER_PID must be a pid, got {caller!r}")
    caller = int(caller)

    def caller_gone():
        if os.getppid() != parent or parent == 1:
            return True
        try:
            os.kill(caller, 0)
        except ProcessLookupError:
            return True
        except PermissionError:      # exists, owned by someone else: a reused pid, but not proof of absence
            return False
        return False

    def watchdog():
        while True:
            if caller_gone():
                os._exit(EXIT_CANNOT_CHECK)
            time.sleep(0.5)
    if caller_gone():                # the caller died before we even got here
        return cannot_check("--serve: the caller is already gone")
    threading.Thread(target=watchdog, daemon=True).start()   # before the blocking FIFO opens below

    req = open(req_path, "rb")
    resp = os.open(resp_path, os.O_WRONLY)

    def reply(line):
        data = line.encode("ascii")
        if len(data) >= 512 or os.write(resp, data) != len(data):
            raise RuntimeError("could not send a whole reply line")

    analyzer = build_analyzer()
    preset = MODES[args.mode]
    why = canary_ok(analyzer, preset["threshold"], preset["noise"])
    if why:
        return cannot_check(why)
    reply(f"READY\t{os.getpid()}\n")

    while True:
        line = req.readline()
        if not line:
            return EXIT_CLEAN               # the caller closed its end
        try:
            fields = line.decode("utf-8").split("\t")
        except UnicodeDecodeError:
            fields = []
        if (len(fields) != 3 or not line.endswith(b"\n") or not fields[0].isdigit()
                or not fields[0].isascii() or "\r" in line.decode("utf-8", "replace")
                or fields[1] in ("", "-") or fields[2] == "\n"):
            return cannot_check(f"malformed request {line[:200]!r}")
        seq, path, prefix = fields[0], fields[1], fields[2][:-1]
        rc = EXIT_CANNOT_CHECK
        try:
            with _open_out(prefix + ".json") as out, _open_out(prefix + ".err") as err:
                try:
                    rc = scan_one(analyzer, args, path, out, err)
                except BaseException as exc:    # per request, as main() does for a cold run
                    rc = cannot_check(f"{type(exc).__name__}: {exc}", err)
        except Exception as exc:              # the outputs could not be written or closed
            print(f"pii-scan --serve: request {seq}: {type(exc).__name__}: {exc}", file=sys.stderr)
            rc = EXIT_CANNOT_CHECK
        reply(f"{seq}\t{rc}\n")


def main():
    p = argparse.ArgumentParser(description="Local PII scan via Presidio")
    p.add_argument("input", nargs="?", help="Text file path, or '-' for stdin")
    p.add_argument("--mode", choices=sorted(MODES), default="gate",
                   help="gate (default): publishing gate, noise suppressed. "
                        "review: human document review, shows everything.")
    p.add_argument("--format", choices=("json", "text"), default="json")
    p.add_argument("--allow-empty", action="store_true",
                   help="Treat empty input as clean instead of CANNOT-CHECK.")
    p.add_argument("--exit-zero", action="store_true",
                   help="Exit 0 even with findings (2 still means CANNOT-CHECK). "
                        "For reports, never for gates.")
    p.add_argument("--selftest", action="store_true",
                   help="Verify the pipeline detects known PII; exit 0 or 2.")
    p.add_argument("--list-entities", action="store_true")
    p.add_argument("--serve", nargs=3, metavar=("REQ_FIFO", "RESP_FIFO", "CALLER_PID"),
                   help="Warm server for one caller over two FIFOs; gate/json only.")
    args = p.parse_args()
    if args.serve:
        clash = [f for f, on in (("--selftest", args.selftest), ("--list-entities", args.list_entities),
                                 ("--exit-zero", args.exit_zero), ("--allow-empty", args.allow_empty),
                                 ("an input path", args.input is not None),
                                 ("--mode other than gate", args.mode != "gate"),
                                 ("--format other than json", args.format != "json")) if on]
        if clash:
            p.error("--serve takes no " + ", ".join(clash))

    # Anything unanticipated is CANNOT-CHECK. Without this an uncaught error
    # exits 1, which the contract defines as "PII was seen" — a scan that never
    # ran would be reported as a finding, or worse, acted on as a normal result.
    try:
        rc = serve(args) if args.serve else run(args)
    except SystemExit:
        raise
    except BaseException as exc:
        cannot_check(f"{type(exc).__name__}: {exc}")
        # Bypass interpreter shutdown: a partially-filled stdout buffer would be
        # flushed there, and on a closed pipe that re-raises and forces exit 120.
        os._exit(EXIT_CANNOT_CHECK)

    # Same reason, on the success path. `pii-scan f | grep -q` and `| head` are
    # exactly how a gate consumes this, and both close the pipe early.
    try:
        sys.stdout.flush()
    except BaseException:
        print("pii-scan CANNOT-CHECK: could not write output (broken pipe)",
              file=sys.stderr)
        os._exit(EXIT_CANNOT_CHECK)
    return rc


if __name__ == "__main__":
    sys.exit(main())
