import json
import math
import subprocess
import time
from collections.abc import Callable


class CommandError(RuntimeError):
    """Raised when an external device command fails."""


def _device_options(
    udid: str | None,
    *,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
) -> list[str]:
    if rsd:
        host, port = rsd
        return ["--rsd", host, port]
    if tunnel:
        return ["--tunnel", tunnel]
    if udid:
        return ["--udid", udid]
    return []


def _ios_location_base(ios_major: int) -> list[str]:
    if ios_major >= 17:
        return ["developer", "dvt", "simulate-location"]
    return ["developer", "simulate-location"]


def _coordinate_text(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def validate_coordinates(latitude: float, longitude: float) -> None:
    if not math.isfinite(latitude) or not math.isfinite(longitude):
        raise CommandError("Coordinates must be finite numbers")
    if not -90 <= latitude <= 90:
        raise CommandError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise CommandError("longitude must be between -180 and 180")


def _validate_location_target(
    *,
    ios_major: int,
    rsd: tuple[str, str] | None,
    tunnel: str | None,
) -> None:
    if rsd and tunnel:
        raise CommandError("--rsd and --tunnel are mutually exclusive")
    if ios_major >= 17 and not (rsd or tunnel):
        raise CommandError(
            "iOS 17+ location simulation requires --rsd or --tunnel. "
            "Start a pymobiledevice3 tunnel first."
        )


def build_list_devices_command(pymobiledevice: str) -> list[str]:
    return [pymobiledevice, "usbmux", "list"]


def build_developer_mode_status_command(
    pymobiledevice: str,
    *,
    udid: str | None,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
) -> list[str]:
    return [
        pymobiledevice,
        "mounter",
        "query-developer-mode-status",
        *_device_options(udid, rsd=rsd, tunnel=tunnel),
    ]


def build_auto_mount_command(
    pymobiledevice: str,
    *,
    udid: str | None,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
) -> list[str]:
    return [
        pymobiledevice,
        "mounter",
        "auto-mount",
        *_device_options(udid, rsd=rsd, tunnel=tunnel),
    ]


def build_lockdown_start_tunnel_command(
    pymobiledevice: str, *, udid: str | None
) -> list[str]:
    return [
        pymobiledevice,
        "lockdown",
        "start-tunnel",
        "--script-mode",
        *_device_options(udid),
    ]


def build_remote_start_tunnel_command(
    pymobiledevice: str, *, udid: str | None
) -> list[str]:
    return [
        pymobiledevice,
        "remote",
        "start-tunnel",
        "--script-mode",
        *_device_options(udid),
    ]


def build_set_location_command(
    pymobiledevice: str,
    *,
    latitude: float,
    longitude: float,
    ios_major: int,
    udid: str | None,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
) -> list[str]:
    _validate_location_target(ios_major=ios_major, rsd=rsd, tunnel=tunnel)
    validate_coordinates(latitude, longitude)
    return [
        pymobiledevice,
        *_ios_location_base(ios_major),
        "set",
        *_device_options(udid, rsd=rsd, tunnel=tunnel),
        "--",
        _coordinate_text(latitude),
        _coordinate_text(longitude),
    ]


def build_reset_location_command(
    pymobiledevice: str,
    *,
    ios_major: int,
    udid: str | None,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
) -> list[str]:
    _validate_location_target(ios_major=ios_major, rsd=rsd, tunnel=tunnel)
    return [
        pymobiledevice,
        *_ios_location_base(ios_major),
        "clear",
        *_device_options(udid, rsd=rsd, tunnel=tunnel),
    ]


def parse_usbmux_devices(output: str) -> list[dict]:
    try:
        devices = json.loads(output)
    except json.JSONDecodeError as exc:
        raise CommandError(f"Unable to parse usbmux list output: {exc}") from exc

    if not isinstance(devices, list):
        raise CommandError("Unable to parse usbmux list output: expected a JSON list")

    return devices


def run_command(
    command: list[str],
    *,
    runner: Callable[[list[str]], subprocess.CompletedProcess[str]] | None = None,
) -> str:
    if runner is None:
        runner = lambda cmd: subprocess.run(  # noqa: E731
            cmd,
            check=False,
            text=True,
            capture_output=True,
        )

    result = runner(command)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise CommandError(message or f"Command failed with exit code {result.returncode}")

    return result.stdout


def run_persistent_command(
    command: list[str],
    *,
    hold_seconds: float | None = None,
    popen_factory=None,
    sleeper: Callable[[float], None] = time.sleep,
) -> int:
    if popen_factory is None:
        popen_factory = subprocess.Popen

    process = popen_factory(command)
    if hold_seconds is None:
        return process.wait()

    sleeper(hold_seconds)
    process.terminate()
    try:
        return process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=5)
