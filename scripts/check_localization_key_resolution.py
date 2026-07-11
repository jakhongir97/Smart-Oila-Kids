#!/usr/bin/env python3
"""Fail if any `L10n.tr("literal")` key referenced in Swift is undefined in en.lproj.

Guards against the "raw localization key shown to the user" class of bug: `L10n.tr` resolves an
unknown key to the key string itself, so an undefined key surfaces as e.g. "error.timeout" in the
UI. Only statically-literal keys are checked — interpolated/dynamic keys can't be resolved here.

A small, documented allowlist covers the dormant legacy media-WebSocket telemetry inbox bodies
(`MediaTelemetryInboxBridge`). That media-WS system points at the dead legacy host and never
connects, and the recording/streaming feature is deferred; the copy for those notifications — which
carries covert-recording implications — is a product decision made with that feature, not guessed.
"""
import argparse
import re
from pathlib import Path
from typing import Iterable, List, Set

# Dormant: legacy media-WS telemetry bodies (dead host, feature deferred). See module docstring.
ALLOWLIST: Set[str] = {
    "notifications.media.recording_started_body",
    "notifications.media.recording_completed_body",
    "notifications.media.recording_upload_queued_body",
    "notifications.media.recording_discarded_body",
    "notifications.media.recording_failed_body",
    "notifications.media.recording_cancelled_body",
    "notifications.media.stream_started_body",
    "notifications.media.stream_stopped_body",
    "notifications.media.stream_failed_body",
    "notifications.media.stream_delivery_failed_body",
}

L10N_CALL_RE = re.compile(r'L10n\.tr\(\s*"([a-zA-Z0-9_.]+)"')
DEFINED_RE = re.compile(r'^"([a-zA-Z0-9_.]+)"\s*=', re.MULTILINE)


def referenced_keys(source_dir: Path) -> Set[str]:
    keys: Set[str] = set()
    for file in source_dir.rglob("*.swift"):
        keys |= set(L10N_CALL_RE.findall(file.read_text(encoding="utf-8", errors="ignore")))
    return keys


def defined_keys(strings_file: Path) -> Set[str]:
    return set(DEFINED_RE.findall(strings_file.read_text(encoding="utf-8")))


def missing_keys(
    source_dir: Path,
    strings_file: Path,
    allowlist: Iterable[str] = ALLOWLIST,
) -> List[str]:
    return sorted(referenced_keys(source_dir) - defined_keys(strings_file) - set(allowlist))


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Fail if a referenced L10n key is undefined.")
    parser.add_argument("--source", type=Path, default=repo_root / "SmartOilaKids")
    parser.add_argument(
        "--strings",
        type=Path,
        default=repo_root / "SmartOilaKids/Resources/Localization/en.lproj/Localizable.strings",
    )
    args = parser.parse_args()

    missing = missing_keys(args.source, args.strings)
    print("Localization key-resolution gate")
    print(f"- Source: {args.source}")
    print(f"- Strings: {args.strings}")
    if missing:
        print("Result: FAIL")
        print("- Referenced but undefined (and not allow-listed):")
        for key in missing:
            print(f"  - {key}")
        raise SystemExit(1)
    print("Result: PASS")


if __name__ == "__main__":
    main()
