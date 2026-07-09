#!/usr/bin/env python3
from __future__ import annotations

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
OUTPUT_ROOT = ROOT / "Artifacts" / "app-store-shots" / f"{date.today().isoformat()}-generated"

IPHONE_SIMULATOR = "iPhone 16 Plus"
IPAD_SIMULATOR = "iPad Pro 13-inch (M4)"

IPHONE_READY_SIZE = (1284, 2778)
IPAD_READY_SIZE = (2064, 2752)

DEMO_DSN = "APPSTORE-DEMO-001"
DEMO_PROFILE = "Alex"

SWIFT_REFERENCE_DATE = datetime(2001, 1, 1, tzinfo=UTC)


@dataclass(frozen=True)
class Shot:
    name: str
    route: str
    delay: float
    auth_stage: str | None = None
    permissions_stage: str | None = None
    open_chat_thread: bool = False


SHOTS = [
    Shot(name="01-link-success", route="auth", delay=2.0, auth_stage="success"),
    Shot(name="02-dashboard", route="main", delay=2.8),
    Shot(name="03-parent-chat", route="chat", delay=3.2, open_chat_thread=True),
    Shot(name="04-tasks", route="tasks", delay=2.8),
    Shot(name="05-permissions", route="permissions", delay=2.0, permissions_stage="checklist"),
    Shot(name="06-settings", route="settings", delay=2.8),
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
    if DERIVED_DATA.exists():
        shutil.rmtree(DERIVED_DATA)

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
    env = os.environ.copy()
    env.update(
        {
            "SIMCTL_CHILD_SMARTOILA_SCREENSHOT_MODE": "1",
            "SIMCTL_CHILD_SMARTOILA_DEBUG_DSN": DEMO_DSN,
            "SIMCTL_CHILD_SMARTOILA_DEBUG_PROFILE": DEMO_PROFILE,
            "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE": shot.route,
        }
    )
    if shot.auth_stage:
        env["SIMCTL_CHILD_SMARTOILA_DEBUG_AUTH_STAGE"] = shot.auth_stage
    if shot.permissions_stage:
        env["SIMCTL_CHILD_SMARTOILA_DEBUG_PERMISSIONS_STAGE"] = shot.permissions_stage
    if shot.open_chat_thread:
        env["SIMCTL_CHILD_SMARTOILA_SCREENSHOT_OPEN_CHAT_THREAD"] = "1"
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
) -> None:
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
                "1. `01-link-success.png`",
                "2. `02-dashboard.png`",
                "3. `03-parent-chat.png`",
                "4. `04-tasks.png`",
                "5. `05-permissions.png`",
                "6. `06-settings.png`",
                "",
                "Folders:",
                f"- iPhone 6.5-ready: `{(OUTPUT_ROOT / 'iphone-6.5-ready').relative_to(ROOT)}`",
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
        "iphone_ready": OUTPUT_ROOT / "iphone-6.5-ready",
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
        for shot in SHOTS:
            launch_and_capture(
                iphone_udid,
                bundle_id,
                directories["iphone_raw"],
                directories["iphone_ready"],
                shot,
                IPHONE_READY_SIZE,
            )

        print("Capturing iPad screenshots...")
        for shot in SHOTS:
            launch_and_capture(
                ipad_udid,
                bundle_id,
                directories["ipad_raw"],
                directories["ipad_ready"],
                shot,
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
