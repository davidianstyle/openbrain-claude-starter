#!/usr/bin/env python3
"""pii-scan — local PII detector using Microsoft Presidio + spaCy.

    pii-scan [--mode gate|review] [--format json|text] FILE     (or - for stdin)
    pii-scan --selftest
    pii-scan --list-entities

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
"""
import argparse
import io
import json
import os
import sys
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


def cannot_check(msg):
    print(f"pii-scan CANNOT-CHECK: {msg}", file=sys.stderr)
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


def run(args):
    analyzer = build_analyzer()

    if args.list_entities:
        print("\n".join(sorted(analyzer.get_supported_entities())))
        return EXIT_CLEAN

    preset = MODES[args.mode]
    threshold, noise = preset["threshold"], preset["noise"]

    if args.selftest:
        why = canary_ok(analyzer, threshold, noise)
        if why:
            return cannot_check(why)
        print(f"pii-scan selftest OK — model {SPACY_MODEL}, mode {args.mode}")
        return EXIT_CLEAN

    if not args.input:
        return cannot_check("no input given (pass a file path or '-' for stdin)")

    try:
        text, source = read_input(args.input)
    except OSError as exc:
        return cannot_check(f"could not read input: {exc}")
    except UnicodeDecodeError as exc:
        return cannot_check(f"input is not valid UTF-8 text: {exc}")

    if "\x00" in text:
        return cannot_check(
            f"input {source} contains NUL bytes — it is almost certainly UTF-16 "
            f"or binary, not UTF-8 text. It would decode into gibberish that "
            f"scans as clean while hiding real identifiers.")

    if not text.strip() and not args.allow_empty:
        return cannot_check(
            f"input {source} is empty — nothing was scanned. An empty read "
            f"usually means the producer failed (bad git ref, mis-quoted path). "
            f"Pass --allow-empty if emptiness is genuinely expected.")

    why = canary_ok(analyzer, threshold, noise)
    if why:
        return cannot_check(why)

    findings = scan(analyzer, text, threshold, noise)
    summary = Counter(f["entity_type"] for f in findings)

    if args.format == "json":
        json.dump({"source": source, "char_count": len(text),
                   "model": SPACY_MODEL, "mode": args.mode,
                   "findings": findings, "summary": dict(summary)},
                  sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(f"PII scan: {source} ({len(text)} chars, {SPACY_MODEL}, mode {args.mode})")
        if not findings:
            print("  no findings")
        else:
            print(f"  {len(findings)} findings:")
            for t, c in summary.most_common():
                print(f"    {c:>3}x {t}")
            print("\n  detail:")
            for f in findings:
                snip = f["text"].replace("\n", " ")
                snip = snip[:57] + "..." if len(snip) > 60 else snip
                print(f"    [{f['score']:.2f}] {f['entity_type']:<20} "
                      f"@{f['start']:>5}: {snip}")
    sys.stdout.flush()

    return EXIT_FINDINGS if (findings and not args.exit_zero) else EXIT_CLEAN


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
    args = p.parse_args()

    # Anything unanticipated is CANNOT-CHECK. Without this an uncaught error
    # exits 1, which the contract defines as "PII was seen" — a scan that never
    # ran would be reported as a finding, or worse, acted on as a normal result.
    try:
        rc = run(args)
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
