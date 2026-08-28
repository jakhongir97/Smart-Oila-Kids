#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "SmartOilaKids.xcodeproj"
SCHEME = "SmartOilaKids"
DERIVED_DATA = ROOT / ".build" / "app-store-screenshots-derived-data"
# Kept OUT of DERIVED_DATA on purpose. `xcodebuild` re-clones every SPM dependency into whichever
# derived-data directory it is handed, and this project depends on client-sdk-swift, whose WebRTC
# submodule checkout takes 20+ minutes. Pinning the clones to one stable path means a capture run
# resolves packages once, ever, instead of once per run.
SPM_PACKAGES = ROOT / ".build" / "spm-packages"
OUTPUT_ROOT = ROOT / "Artifacts" / "app-store-shots" / f"{date.today().isoformat()}-generated"

# 6.9" is the only iPhone size App Store Connect still accepts as the primary set; the 6.5"
# slot is legacy and the live listing's existing 6.5" shots cannot be reused (pre-rebrand).
IPHONE_SIMULATOR = "iPhone 16 Pro Max"

IPAD_SIMULATOR = "iPad Pro 13-inch (M4)"

IPHONE_READY_SIZE = (1290, 2796)  # 6.9" portrait
IPAD_READY_SIZE = (2064, 2752)

# The iPad pass is NOT optional. v1.0 shipped `TARGETED_DEVICE_FAMILY = "1,2"`, and an update may not
# drop a device family the published version supported -- App Store Connect rejects the upload
# outright ("This bundle does not support one or more of the devices supported by the previous app
# version", QA1623). So iPad stays, and App Store Connect requires its 13" screenshot slot filled.

DEMO_DSN = "APPSTORE-DEMO-001"
DEMO_PROFILE = "Alex"

SWIFT_REFERENCE_DATE = datetime(2001, 1, 1, tzinfo=UTC)


@dataclass(frozen=True)
class Shot:
    name: str
    route: str
    delay: float
    setup_step: str | None = None
    # Extra `SIMCTL_CHILD_*` variables for capture-only surfaces that no debug route reaches: the
    # SOS confirm sheet and the live-session disclosure banner. Both are read only under `#if DEBUG`.
    extra_env: tuple[tuple[str, str], ...] = ()


# `route` MUST be a raw value of `DebugRoute` in Core/Config/AppRuntime.swift and `setup_step` a raw
# value of `DebugSetupStep`; anything else is silently ignored (`DebugRoute(rawValue:)` returns nil)
# and RootView falls through to the regular root, so every shot captures the same screen. The old
# `auth`/`main`/`chat`/`tasks`/`permissions`/`settings` values were exactly that -- pre-Bolajon
# route names that no longer exist. The SHOT_DIGESTS check below is what makes a repeat of that
# mistake fail loudly instead of shipping six copies of one screen to App Store Connect.
#
# Order is the App Store listing order and is deliberate: the live-check disclosure is the SECOND
# frame, so a reviewer looking for covert monitoring (Guideline 5.1.2 — the risk this app carries)
# sees the indicator before they go looking for it.
SHOTS = [
    Shot(name="01-home", route="home2", delay=2.8),
    Shot(
        name="02-live-check-disclosure",
        route="home2",
        delay=2.8,
        extra_env=(("SMARTOILA_DEBUG_INDICATOR", "1"),),
    ),
    Shot(name="03-parent-chat", route="chat2", delay=3.2),
    Shot(
        name="04-sos",
        route="home2",
        delay=3.0,
        extra_env=(("SMARTOILA_DEBUG_SOS", "1"),),
    ),
    Shot(name="05-tasks", route="tasks2", delay=2.8),
    Shot(name="06-permissions", route="perm2", delay=2.0),
    Shot(name="07-settings", route="settings2", delay=2.8),
    Shot(name="08-link-success", route="setup", delay=2.0, setup_step="success"),
]


def run(command: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=check,
        text=True,
        capture_output=True,
    )


def host(command: list[str], *, extra_env: dict[str, str] | None = None) -> None:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    completed = run(command, env=env)
    if completed.stdout.strip():
        print(completed.stdout.strip())


def simulator_udid(device_name: str) -> str:
    completed = run(["xcrun", "simctl", "list", "devices", "available", "--json"])
    payload = json.loads(completed.stdout)
    for runtime_devices in payload.get("devices", {}).values():
        for device in runtime_devices:
            if device.get("name") == device_name and device.get("isAvailable"):
                return device["udid"]
    raise RuntimeError(f"Simulator not found: {device_name}")


def boot_simulator(udid: str) -> None:
    run(["xcrun", "simctl", "boot", udid], check=False)
    host(["xcrun", "simctl", "bootstatus", udid, "-b"])


def override_status_bar(udid: str) -> None:
    run(
        [
            "xcrun",
            "simctl",
            "status_bar",
            udid,
            "override",
            "--time",
            "9:41",
            "--dataNetwork",
            "wifi",
            "--wifiMode",
            "active",
            "--wifiBars",
            "3",
            "--cellularMode",
            "active",
            "--cellularBars",
            "4",
            "--batteryState",
            "charged",
            "--batteryLevel",
            "100",
        ],
        check=False,
    )


def build_app(iphone_udid: str) -> tuple[Path, str]:
    # Deliberately NOT wiped between runs. The old `rmtree` cost a full SPM re-resolve every time
    # (see SPM_PACKAGES); an incremental rebuild of the same sources is what makes a re-capture
    # cheap enough to actually redo after a copy change.
    SPM_PACKAGES.mkdir(parents=True, exist_ok=True)

    print("Building SmartOilaKids for simulator capture...")
    host(
        [
            "xcodebuild",
            "-project",
            str(PROJECT),
            "-scheme",
            SCHEME,
            "-configuration",
            "Debug",
            "-sdk",
            "iphonesimulator",
            "-destination",
            f"id={iphone_udid}",
            "-derivedDataPath",
            str(DERIVED_DATA),
            "-clonedSourcePackagesDirPath",
            str(SPM_PACKAGES),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ]
    )

    app_path = DERIVED_DATA / "Build" / "Products" / "Debug-iphonesimulator" / "SmartOilaKids.app"
    if not app_path.exists():
        raise RuntimeError(f"Built app not found at {app_path}")

    plist_output = run(
        ["/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(app_path / "Info.plist")]
    )
    bundle_id = plist_output.stdout.strip()
    if not bundle_id:
        raise RuntimeError("Could not resolve app bundle identifier")

    return app_path, bundle_id


def uninstall_and_install(udid: str, bundle_id: str, app_path: Path) -> None:
    run(["xcrun", "simctl", "uninstall", udid, bundle_id], check=False)
    host(["xcrun", "simctl", "install", udid, str(app_path)])
    run(["xcrun", "simctl", "privacy", udid, "reset", "all", bundle_id], check=False)


def app_data_container(udid: str, bundle_id: str) -> Path:
    completed = run(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"])
    return Path(completed.stdout.strip())


def swift_seconds(value: datetime) -> float:
    return (value.astimezone(UTC) - SWIFT_REFERENCE_DATE).total_seconds()


def iso8601(value: datetime) -> str:
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def user_defaults_key(prefix: str, dsn: str) -> str:
    return f"{prefix}{dsn.strip().replace(' ', '_').replace('.', '_').replace('/', '_')}"


def json_data(payload: object) -> bytes:
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def grouped_chat_history(now: datetime) -> tuple[dict[str, list[dict[str, object]]], str]:
    timestamps = [
        now - timedelta(minutes=36),
        now - timedelta(minutes=31),
        now - timedelta(minutes=22),
        now - timedelta(minutes=14),
        now - timedelta(minutes=7),
        now - timedelta(minutes=3),
    ]
    messages = [
        {"userType": "parent", "text": "Where are you now?", "attachments": [], "time": iso8601(timestamps[0]), "senderName": "Parent"},
        {"userType": "child", "text": "Leaving school now.", "attachments": [], "time": iso8601(timestamps[1]), "senderName": DEMO_PROFILE},
        {"userType": "parent", "text": "Great. Please head straight home.", "attachments": [], "time": iso8601(timestamps[2]), "senderName": "Parent"},
        {"userType": "child", "text": "Okay. I will finish homework after snack.", "attachments": [], "time": iso8601(timestamps[3]), "senderName": DEMO_PROFILE},
        {"userType": "parent", "text": "Perfect. Send me a message when you arrive.", "attachments": [], "time": iso8601(timestamps[4]), "senderName": "Parent"},
        {"userType": "child", "text": "Will do.", "attachments": [], "time": iso8601(timestamps[5]), "senderName": DEMO_PROFILE},
    ]
    grouped: dict[str, list[dict[str, object]]] = {}
    for message in messages:
        grouped.setdefault(str(message["time"])[:10], []).append(message)
    return grouped, iso8601(timestamps[2])


def build_preferences() -> dict[str, object]:
    now = datetime.now(UTC)
    chat_history, last_read = grouped_chat_history(now)
    dsn_key = DEMO_DSN

    task_awards = [
        {
            "awardID": 101,
            "name": "After-school routine",
            "imageURL": None,
            "neededPoints": 30,
            "isCompleted": False,
            "collectedCoins": 20,
            "tasks": [
                {"taskID": 1001, "name": "Message parent after school", "isFinished": True, "pointsAmount": 10},
                {"taskID": 1002, "name": "Put backpack away", "isFinished": False, "pointsAmount": 10},
                {"taskID": 1003, "name": "Start homework timer", "isFinished": False, "pointsAmount": 10},
            ],
        },
        {
            "awardID": 102,
            "name": "Reading challenge",
            "imageURL": None,
            "neededPoints": 20,
            "isCompleted": False,
            "collectedCoins": 10,
            "tasks": [
                {"taskID": 2001, "name": "Read 20 pages", "isFinished": False, "pointsAmount": 10},
                {"taskID": 2002, "name": "Share one new word", "isFinished": False, "pointsAmount": 10},
            ],
        },
        {
            "awardID": 103,
            "name": "Evening wrap-up",
            "imageURL": None,
            "neededPoints": 10,
            "isCompleted": True,
            "collectedCoins": 10,
            "tasks": [
                {"taskID": 3001, "name": "Charge phone before bed", "isFinished": True, "pointsAmount": 10},
            ],
        },
    ]

    push_items = [
        {
            "id": "device-control-1",
            "title": "Focus time updated",
            "body": "Parent updated your schedule for homework time.",
            "event": "device_control_schedule_updated",
            "dsn": DEMO_DSN,
            "receivedAt": swift_seconds(now - timedelta(minutes=18)),
            "isRead": False,
            "fingerprint": "device_control_schedule_updated|appstore-demo-001|focus time updated|parent updated your schedule for homework time.",
        },
        {
            "id": "media-1",
            "title": "Recording delivered",
            "body": "A recent media snapshot is ready to review.",
            "event": "media_recording_ready",
            "dsn": DEMO_DSN,
            "receivedAt": swift_seconds(now - timedelta(minutes=10)),
            "isRead": False,
            "fingerprint": "media_recording_ready|appstore-demo-001|recording delivered|a recent media snapshot is ready to review.",
        },
        {
            "id": "tasks-1",
            "title": "New task assigned",
            "body": "Two tasks are waiting for completion.",
            "event": "tasks_assigned",
            "dsn": DEMO_DSN,
            "receivedAt": swift_seconds(now - timedelta(minutes=6)),
            "isRead": False,
            "fingerprint": "tasks_assigned|appstore-demo-001|new task assigned|two tasks are waiting for completion.",
        },
    ]

    return {
        "DSN": DEMO_DSN,
        "PROFILE_NAME": DEMO_PROFILE,
        "APP_LANGUAGE": "en",
        "APP_THEME": "light",
        "SETTINGS_CACHE_PROFILE_NAME": DEMO_PROFILE,
        "SETTINGS_CACHE_CONNECTED_DEVICES": json_data(
            [
                {"id": 1, "dsn": DEMO_DSN, "name": "Alex's iPhone", "avatarURL": None},
                {"id": 2, "dsn": "APPSTORE-DEMO-002", "name": "Family iPad", "avatarURL": None},
            ]
        ),
        user_defaults_key("MAIN_DEVICE_STATUS_CACHE_", dsn_key): json_data(
            {
                "deviceName": "Alex's iPhone",
                "battery": 82,
                "connectionType": "Wi-Fi",
                "soundMode": "Normal",
                "latitude": 41.3111,
                "longitude": 69.2797,
                "cachedAt": swift_seconds(now),
            }
        ),
        user_defaults_key("MAIN_WEEKLY_USAGE_CACHE_", dsn_key): json_data(
            {
                "hours": [1.1, 1.4, 2.2, 1.8, 2.6, 1.5, 0.9],
                "cachedAt": swift_seconds(now),
            }
        ),
        user_defaults_key("TASK_CACHE_", dsn_key): json_data(
            {
                "awards": task_awards,
                "savedAt": swift_seconds(now),
            }
        ),
        user_defaults_key("CHAT_HISTORY_", dsn_key): json_data(
            {
                "groupedMessages": chat_history,
                "savedAt": swift_seconds(now),
            }
        ),
        user_defaults_key("CHAT_LAST_READ_", dsn_key): last_read,
        user_defaults_key("CHAT_PARENT_NAME_", dsn_key): "Parent",
        "PUSH_INBOX_ITEMS": json_data(push_items),
    }


def seed_defaults(container: Path, bundle_id: str) -> None:
    preferences_dir = container / "Library" / "Preferences"
    preferences_dir.mkdir(parents=True, exist_ok=True)
    plist_path = preferences_dir / f"{bundle_id}.plist"

    with plist_path.open("wb") as handle:
        plistlib.dump(build_preferences(), handle, fmt=plistlib.FMT_BINARY)


def launch_env(shot: Shot) -> dict[str, str]:
    # Only these four variables are read by the app (`AppRuntime`). SMARTOILA_SCREENSHOT_MODE,
    # SMARTOILA_DEBUG_AUTH_STAGE, SMARTOILA_DEBUG_PERMISSIONS_STAGE and
    # SMARTOILA_SCREENSHOT_OPEN_CHAT_THREAD have no reader anywhere in the target and were dropped.
    env = os.environ.copy()
    env.update(
        {
            "SIMCTL_CHILD_SMARTOILA_DEBUG_DSN": DEMO_DSN,
            "SIMCTL_CHILD_SMARTOILA_DEBUG_PROFILE": DEMO_PROFILE,
            "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE": shot.route,
            # The Home header chip is computed from a Keychain credential and a recent successful
            # contact with the backend. A capture simulator has neither, so every Home shot came out
            # with a red "Not connected right now" across the top — an accurate reading of the
            # simulator and a terrible primary App Store screenshot. `#if DEBUG` at the source, so it
            # cannot exist in the archive App Review installs.
            "SIMCTL_CHILD_SMARTOILA_DEBUG_LINK_HEALTHY": "1",
        }
    )
    if shot.setup_step:
        env["SIMCTL_CHILD_SMARTOILA_DEBUG_SETUP_STEP"] = shot.setup_step
    for key, value in shot.extra_env:
        env[f"SIMCTL_CHILD_{key}"] = value
    return env


def terminate_app(udid: str, bundle_id: str) -> None:
    run(["xcrun", "simctl", "terminate", udid, bundle_id], check=False)


def launch_and_capture(
    udid: str,
    bundle_id: str,
    raw_dir: Path,
    ready_dir: Path,
    shot: Shot,
    ready_size: tuple[int, int],
) -> str:
    raw_path = raw_dir / f"{shot.name}.png"
    ready_path = ready_dir / f"{shot.name}.png"

    terminate_app(udid, bundle_id)
    run(
        [
            "xcrun",
            "simctl",
            "launch",
            "--terminate-running-process",
            udid,
            bundle_id,
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ],
        env=launch_env(shot),
    )
    time.sleep(shot.delay)
    host(["xcrun", "simctl", "io", udid, "screenshot", str(raw_path)])
    host(["sips", "-z", str(ready_size[1]), str(ready_size[0]), str(raw_path), "--out", str(ready_path)])
    return hashlib.sha256(raw_path.read_bytes()).hexdigest()


def capture_set(
    udid: str,
    bundle_id: str,
    raw_dir: Path,
    ready_dir: Path,
    ready_size: tuple[int, int],
) -> None:
    """Capture every shot for one device and refuse to return duplicate screens.

    A debug route the app does not recognise produces the regular root instead, so the run still
    "succeeds" while every PNG is the same screen. Digest-comparing the raw captures turns that
    into a hard failure at capture time rather than a rejection in App Store Connect.
    """
    digests: dict[str, str] = {}
    for shot in SHOTS:
        digests[shot.name] = launch_and_capture(
            udid, bundle_id, raw_dir, ready_dir, shot, ready_size
        )

    duplicates: dict[str, list[str]] = {}
    for name, digest in digests.items():
        duplicates.setdefault(digest, []).append(name)
    collisions = [names for names in duplicates.values() if len(names) > 1]
    if collisions:
        detail = "; ".join(", ".join(names) for names in collisions)
        raise RuntimeError(
            f"Identical screenshots captured ({detail}). The debug route almost certainly did not "
            "take effect -- check that every Shot.route is a DebugRoute raw value and that the "
            "build is Debug (debugRoute is compiled out of Release)."
        )


def write_manifest() -> None:
    manifest = OUTPUT_ROOT / "UPLOAD_ORDER.md"
    manifest.write_text(
        "\n".join(
            [
                "# App Store Screenshot Export",
                "",
                "Generated by `scripts/create_app_store_screenshots.py`.",
                "",
                "Upload order:",
                *(f"{index}. `{shot.name}.png`" for index, shot in enumerate(SHOTS, start=1)),
                "",
                "Both sets are required: the app is `TARGETED_DEVICE_FAMILY = \"1,2\"` and cannot drop",
                "iPad, so App Store Connect demands the 13\" slot as well as the 6.9\" one.",
                "",
                "Folders:",
                f"- iPhone 6.9-ready: `{(OUTPUT_ROOT / 'iphone-6.9-ready').relative_to(ROOT)}`",
                f"- iPad 13-ready: `{(OUTPUT_ROOT / 'ipad-13-ready').relative_to(ROOT)}`",
                "",
                "Raw captures are included alongside the upload-sized exports.",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def prepare_output_dirs() -> dict[str, Path]:
    if OUTPUT_ROOT.exists():
        shutil.rmtree(OUTPUT_ROOT)

    directories = {
        "iphone_raw": OUTPUT_ROOT / "iphone-raw",
        "iphone_ready": OUTPUT_ROOT / "iphone-6.9-ready",
        "ipad_raw": OUTPUT_ROOT / "ipad-raw",
        "ipad_ready": OUTPUT_ROOT / "ipad-13-ready",
    }
    for directory in directories.values():
        directory.mkdir(parents=True, exist_ok=True)
    return directories


def main() -> int:
    try:
        directories = prepare_output_dirs()

        iphone_udid = simulator_udid(IPHONE_SIMULATOR)
        ipad_udid = simulator_udid(IPAD_SIMULATOR)

        print(f"Booting {IPHONE_SIMULATOR} and {IPAD_SIMULATOR}...")
        boot_simulator(iphone_udid)
        boot_simulator(ipad_udid)
        run(["open", "-a", "Simulator"], check=False)

        app_path, bundle_id = build_app(iphone_udid)

        for udid in (iphone_udid, ipad_udid):
            uninstall_and_install(udid, bundle_id, app_path)
            seed_defaults(app_data_container(udid, bundle_id), bundle_id)
            override_status_bar(udid)

        print("Capturing iPhone screenshots...")
        capture_set(
            iphone_udid,
            bundle_id,
            directories["iphone_raw"],
            directories["iphone_ready"],
            IPHONE_READY_SIZE,
        )

        print("Capturing iPad screenshots...")
        capture_set(
            ipad_udid,
            bundle_id,
            directories["ipad_raw"],
            directories["ipad_ready"],
            IPAD_READY_SIZE,
        )

        write_manifest()

        print()
        print("Finished.")
        print(f"Output: {OUTPUT_ROOT}")
        return 0
    except Exception as error:
        print(f"Failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
