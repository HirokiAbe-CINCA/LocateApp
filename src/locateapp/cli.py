import argparse
import json
import shlex
import sys
from typing import TextIO

from locateapp.commands import (
    CommandError,
    build_list_devices_command,
    parse_usbmux_devices,
    run_command,
    run_persistent_command,
    validate_coordinates,
)
from locateapp.proof import build_location_proof_plan, select_device_udid


def _add_common_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--pymobiledevice",
        default=".venv/bin/pymobiledevice3",
        help="Path to pymobiledevice3. Defaults to the project venv binary.",
    )


def _make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="locate-poc",
        description="Xcode-less iPhone location simulation proof helper.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="Check visible iPhone devices.")
    _add_common_options(doctor)

    prove = subparsers.add_parser("prove", help="Run or print the location proof steps.")
    _add_common_options(prove)
    prove.add_argument("--udid", help="Target iPhone UDID. Uses first usbmux device if omitted.")
    prove.add_argument("--ios-major", type=int, default=17, help="Target iOS major version.")
    prove.add_argument("--lat", type=float, required=True, help="Latitude to simulate.")
    prove.add_argument("--lon", type=float, required=True, help="Longitude to simulate.")
    prove.add_argument("--rsd-host", help="RemoteServiceDiscovery host from start-tunnel.")
    prove.add_argument("--rsd-port", help="RemoteServiceDiscovery port from start-tunnel.")
    prove.add_argument("--tunnel", help="UDID or UDID:PORT exposed by pymobiledevice3 tunneld.")
    prove.add_argument("--reset-after", action="store_true", help="Clear simulated location after set.")
    prove.add_argument(
        "--hold-seconds",
        type=float,
        help="How long to keep the iOS 17+ DVT set process alive before stopping it.",
    )
    prove.add_argument("--dry-run", action="store_true", help="Print commands without running them.")

    return parser


def _rsd_from_args(args: argparse.Namespace) -> tuple[str, str] | None:
    if bool(args.rsd_host) != bool(args.rsd_port):
        raise CommandError("--rsd-host and --rsd-port must be provided together")
    if args.rsd_host and args.rsd_port:
        return (args.rsd_host, args.rsd_port)
    return None


def _validate_target_args(args: argparse.Namespace, rsd: tuple[str, str] | None) -> None:
    if rsd and args.tunnel:
        raise CommandError("--rsd and --tunnel are mutually exclusive")
    if args.ios_major >= 17 and not (rsd or args.tunnel):
        raise CommandError(
            "iOS 17+ requires --rsd-host/--rsd-port or --tunnel. "
            "Start a pymobiledevice3 tunnel first."
        )


def _ensure_developer_mode_enabled(output: str) -> None:
    value = output.strip().lower()
    if value in {"true", "1", "yes", "enabled"}:
        return
    if value in {"false", "0", "no", "disabled"}:
        raise CommandError("Developer Mode is disabled on the target iPhone")

    try:
        parsed = json.loads(output)
    except Exception as exc:
        raise CommandError(
            f"Unable to parse Developer Mode status output: {output.strip()}"
        ) from exc

    if parsed is True:
        return
    if parsed is False:
        raise CommandError("Developer Mode is disabled on the target iPhone")
    raise CommandError(f"Unexpected Developer Mode status output: {output.strip()}")


def _print_step(stdout: TextIO, name: str, command: list[str]) -> None:
    print(f"{name}: {shlex.join(command)}", file=stdout)


def _run_doctor(args: argparse.Namespace, *, runner, stdout: TextIO, stderr: TextIO) -> int:
    del stderr
    command = build_list_devices_command(args.pymobiledevice)
    _print_step(stdout, "list-devices", command)
    output = run_command(command, runner=runner)
    devices = parse_usbmux_devices(output)

    if not devices:
        print("No devices visible through pymobiledevice3 usbmux.", file=stdout)
        print("Connect the iPhone by cable, unlock it, and tap Trust.", file=stdout)
        return 1

    print(f"Visible devices: {len(devices)}", file=stdout)
    for device in devices:
        identifier = device.get("Identifier", "(missing Identifier)")
        connection = device.get("ConnectionType", "(unknown connection)")
        print(f"- {identifier} [{connection}]", file=stdout)
    return 0


def _run_prove(
    args: argparse.Namespace,
    *,
    runner,
    persistent_runner,
    stdout: TextIO,
    stderr: TextIO,
) -> int:
    del stderr
    rsd = _rsd_from_args(args)
    _validate_target_args(args, rsd)
    validate_coordinates(args.lat, args.lon)
    udid = args.udid

    if not (udid or rsd or args.tunnel):
        output = run_command(build_list_devices_command(args.pymobiledevice), runner=runner)
        udid = select_device_udid(parse_usbmux_devices(output), requested_udid=None)

    plan = build_location_proof_plan(
        args.pymobiledevice,
        udid=udid,
        rsd=rsd,
        tunnel=args.tunnel,
        ios_major=args.ios_major,
        latitude=args.lat,
        longitude=args.lon,
        reset_after=args.reset_after,
    )

    for step in plan:
        if args.dry_run:
            _print_step(stdout, step.name, step.command)
            continue

        _print_step(stdout, step.name, step.command)

        if args.ios_major >= 17 and step.name == "set-location":
            hold_seconds = args.hold_seconds
            if args.reset_after and hold_seconds is None:
                hold_seconds = 5.0
            if hold_seconds is None:
                print(
                    "set-location: running; keep this process open to maintain simulation.",
                    file=stdout,
                )
            else:
                print(f"set-location: holding for {hold_seconds:g}s", file=stdout)
            returncode = persistent_runner(step.command, hold_seconds=hold_seconds)
            if returncode not in (None, 0, -2, -15):
                raise CommandError(
                    f"set-location process exited with code {returncode}"
                )
            if hold_seconds is None:
                print("set-location: process exited", file=stdout)
            else:
                print("set-location: stopped", file=stdout)
            continue

        output = run_command(step.command, runner=runner)
        if step.name == "developer-mode-status":
            _ensure_developer_mode_enabled(output)
        print(f"{step.name}: OK", file=stdout)

    return 0


def main(
    argv: list[str] | None = None,
    *,
    runner=None,
    persistent_runner=None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = _make_parser()
    args = parser.parse_args(argv)

    try:
        if persistent_runner is None:
            persistent_runner = run_persistent_command
        if args.command == "doctor":
            return _run_doctor(args, runner=runner, stdout=stdout, stderr=stderr)
        if args.command == "prove":
            return _run_prove(
                args,
                runner=runner,
                persistent_runner=persistent_runner,
                stdout=stdout,
                stderr=stderr,
            )
    except CommandError as exc:
        print(f"ERROR: {exc}", file=stderr)
        return 1

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
