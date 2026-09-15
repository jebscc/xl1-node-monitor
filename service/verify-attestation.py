#!/usr/bin/env python3
"""Check a node attestation against the hash the chain recorded.

Standard library only, and deliberately so. The point of an attestation is that
a stranger can check it without trusting the site that published it -- and a
verifier that needs the publisher's SDK, or the publisher's word about what the
SDK does, is not much of a check. Everything here is sha256 and JSON.

    python verify-attestation.py attestation.json
    python verify-attestation.py attestation.json --hash <expected>

The file is whatever /attest returned, or whatever the site publishes for an
attestation. What matters is the `payload` object; the rest is convenience.

What a match proves, precisely: the payload you are holding is the one whose
hash was anchored. It does not prove the readings inside it were true when they
were taken -- nothing can prove that -- only that they have not been edited
since, because editing any part of them changes the hash.

What it does not prove on its own: who anchored it. That is the transaction's
signer on chain, and tying that signer to the producer is what the delegation
record is for.
"""
import argparse
import hashlib
import json
import sys


def canonical_hash(payload):
    """The hash XYO's PayloadBuilder produces, reimplemented in four lines.

    Sorted keys, no whitespace, sha256 of the UTF-8 bytes. Confirmed against
    PayloadBuilder.hash rather than taken from documentation -- the two agree
    exactly, which is what makes this file worth having.
    """
    # `ensure_ascii=False` IS LOAD-BEARING. Python escapes non-ASCII by
    # default, so a title containing an accent is re-serialised here as
    # "Caf\u00e9" while the SDK hashed the raw UTF-8 bytes of "Café". The
    # hashes then differ and this file reports a good attestation as edited.
    # It cost nothing for node attestations, which are addresses, ISO
    # timestamps and numbers -- but the Frontier adventure anchor puts a
    # player's own title and summary in the payload, and one accent, curly
    # quote or emoji was enough. Found 2026-09-14 by a test that hashes an
    # awkward payload both ways; ASCII payloads are byte-identical either
    # way, so no attestation that verified before verifies differently now.
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", help="attestation JSON, or - for stdin")
    ap.add_argument("--hash", dest="expected",
                    help="hash to check against; defaults to contentHash in the file")
    args = ap.parse_args()

    raw = sys.stdin.read() if args.file == "-" else open(args.file, encoding="utf-8").read()
    try:
        doc = json.loads(raw)
    except ValueError as e:
        print("not JSON: %s" % e)
        return 2

    payload = doc.get("payload")
    if not isinstance(payload, dict):
        print("no `payload` object in the file -- nothing to hash")
        return 2

    expected = args.expected or doc.get("contentHash")
    if not expected:
        print("no hash to check against: pass --hash, or include contentHash")
        return 2

    actual = canonical_hash(payload)
    ok = actual == expected.lower().strip()

    print("payload salt bytes : %d" % len(payload.get("salt", "")))
    print("recomputed hash    : %s" % actual)
    print("expected hash      : %s" % expected)
    print("MATCH              : %s" % ("yes" if ok else "NO"))

    # Print the readings, so a person can see what they just verified rather
    # than being told a hash matched something they never looked at.
    salt = payload.get("salt")
    if isinstance(salt, str):
        try:
            record = json.loads(salt)
        except ValueError:
            record = None
        if isinstance(record, dict):
            print("\nwhat this attests:")
            for key in ("producer", "network", "observedAt"):
                if record.get(key) is not None:
                    print("  %-14s %s" % (key, record[key]))
            for group in ("chain", "machine"):
                block = record.get(group)
                if isinstance(block, dict):
                    print("  %s:" % group)
                    for k, v in block.items():
                        print("    %-16s %s" % (k, v))

    if not ok:
        print("\nThe payload does not hash to the expected value. Either it was"
              "\nedited after anchoring, or it is not the payload that hash"
              "\nbelongs to.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
