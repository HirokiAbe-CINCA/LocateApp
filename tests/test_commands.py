import subprocess

import pytest

from locateapp.commands import (
    CommandError,
    build_auto_mount_command,
    build_developer_mode_status_command,
    build_lockdown_start_tunnel_command,
    build_remote_start_tunnel_command,
    build_list_devices_command,
    build_reset_location_command,
    build_set_location_command,
    parse_usbmux_devices,
    run_command,
)


def test_builds_usbmux_list_command():
    assert build_list_devices_command("pymobiledevice3") == [
        "pymobiledevice3",
        "usbmux",
        "list",
    ]


def test_builds_developer_mode_status_command_with_udid():
    assert build_developer_mode_status_command("pmd3", udid="abc123") == [
        "pmd3",
        "mounter",
        "query-developer-mode-status",
        "--udid",
        "abc123",
    ]


def test_builds_developer_mode_status_command_with_rsd():
    assert build_developer_mode_status_command(
        "pmd3", udid=None, rsd=("fd00::1", "12345")
    ) == [
        "pmd3",
        "mounter",
        "query-developer-mode-status",
        "--rsd",
        "fd00::1",
        "12345",
    ]


def test_builds_auto_mount_command_with_udid():
    assert build_auto_mount_command("pmd3", udid="abc123") == [
        "pmd3",
        "mounter",
        "auto-mount",
        "--udid",
        "abc123",
    ]


def test_builds_lockdown_start_tunnel_command():
    assert build_lockdown_start_tunnel_command("pmd3", udid="abc123") == [
        "pmd3",
        "lockdown",
        "start-tunnel",
        "--script-mode",
        "--udid",
        "abc123",
    ]


def test_builds_remote_start_tunnel_command():
    assert build_remote_start_tunnel_command("pmd3", udid="abc123") == [
        "pmd3",
        "remote",
        "start-tunnel",
        "--script-mode",
        "--udid",
        "abc123",
    ]


def test_builds_ios17_set_command_with_separator_for_negative_values():
    assert build_set_location_command(
        "pmd3",
        latitude=40.690008,
        longitude=-74.045843,
        ios_major=17,
        udid=None,
        rsd=("fd00::1", "12345"),
    ) == [
        "pmd3",
        "developer",
        "dvt",
        "simulate-location",
        "set",
        "--rsd",
        "fd00::1",
        "12345",
        "--",
        "40.690008",
        "-74.045843",
    ]


def test_builds_ios17_set_command_with_tunnel():
    assert build_set_location_command(
        "pmd3",
        latitude=35.681236,
        longitude=139.767125,
        ios_major=17,
        udid=None,
        tunnel="abc123",
    ) == [
        "pmd3",
        "developer",
        "dvt",
        "simulate-location",
        "set",
        "--tunnel",
        "abc123",
        "--",
        "35.681236",
        "139.767125",
    ]


def test_ios17_set_requires_rsd_or_tunnel():
    with pytest.raises(CommandError, match="iOS 17\\+"):
        build_set_location_command(
            "pmd3",
            latitude=35.681236,
            longitude=139.767125,
            ios_major=17,
            udid="abc123",
        )


def test_builds_pre_ios17_set_command():
    assert build_set_location_command(
        "pmd3",
        latitude=35.681236,
        longitude=139.767125,
        ios_major=16,
        udid=None,
    ) == [
        "pmd3",
        "developer",
        "simulate-location",
        "set",
        "--",
        "35.681236",
        "139.767125",
    ]


def test_builds_ios17_reset_command():
    assert build_reset_location_command(
        "pmd3", ios_major=18, udid=None, rsd=("fd00::1", "12345")
    ) == [
        "pmd3",
        "developer",
        "dvt",
        "simulate-location",
        "clear",
        "--rsd",
        "fd00::1",
        "12345",
    ]


def test_ios17_reset_requires_rsd_or_tunnel():
    with pytest.raises(CommandError, match="iOS 17\\+"):
        build_reset_location_command("pmd3", ios_major=17, udid="abc123")


def test_builds_pre_ios17_reset_command():
    assert build_reset_location_command("pmd3", ios_major=16, udid=None) == [
        "pmd3",
        "developer",
        "simulate-location",
        "clear",
    ]


def test_parse_usbmux_devices_accepts_json_list():
    devices = parse_usbmux_devices(
        '[{"ConnectionType": "USB", "DeviceID": 3, "Identifier": "abc123"}]'
    )

    assert devices == [{"ConnectionType": "USB", "DeviceID": 3, "Identifier": "abc123"}]


def test_parse_usbmux_devices_rejects_non_json_output():
    with pytest.raises(CommandError, match="Unable to parse"):
        parse_usbmux_devices("not json")


def test_rejects_out_of_range_coordinates():
    with pytest.raises(CommandError, match="latitude"):
        build_set_location_command(
            "pmd3",
            latitude=91,
            longitude=139.767125,
            ios_major=16,
            udid=None,
        )


def test_rejects_non_finite_coordinates():
    with pytest.raises(CommandError, match="finite"):
        build_set_location_command(
            "pmd3",
            latitude=float("nan"),
            longitude=139.767125,
            ios_major=16,
            udid=None,
        )


def test_run_command_returns_stdout_for_success():
    result = subprocess.CompletedProcess(
        args=["tool"],
        returncode=0,
        stdout="ok\n",
        stderr="",
    )

    assert run_command(["tool"], runner=lambda command: result) == "ok\n"


def test_run_command_raises_with_stderr_for_failure():
    result = subprocess.CompletedProcess(
        args=["tool"],
        returncode=2,
        stdout="",
        stderr="device not found\n",
    )

    with pytest.raises(CommandError, match="device not found"):
        run_command(["tool"], runner=lambda command: result)
