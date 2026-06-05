from io import StringIO
import subprocess

from locateapp.cli import main


def _runner_with_responses(responses):
    calls = []

    def runner(command):
        calls.append(command)
        return responses[tuple(command)]

    runner.calls = calls
    return runner


def test_doctor_reports_no_visible_devices():
    stdout = StringIO()
    stderr = StringIO()
    runner = _runner_with_responses(
        {
            ("pmd3", "usbmux", "list"): subprocess.CompletedProcess(
                args=["pmd3"],
                returncode=0,
                stdout="[]",
                stderr="",
            )
        }
    )

    exit_code = main(
        ["doctor", "--pymobiledevice", "pmd3"],
        runner=runner,
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 1
    assert "No devices visible" in stdout.getvalue()


def test_prove_dry_run_prints_location_commands_without_running_them():
    stdout = StringIO()
    stderr = StringIO()

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--udid",
            "abc123",
            "--ios-major",
            "17",
            "--rsd-host",
            "fd00::1",
            "--rsd-port",
            "12345",
            "--lat",
            "35.681236",
            "--lon",
            "139.767125",
            "--dry-run",
        ],
        runner=lambda command: (_ for _ in ()).throw(AssertionError(command)),
        stdout=stdout,
        stderr=stderr,
    )

    output = stdout.getvalue()
    assert exit_code == 0
    assert "developer-mode-status" in output
    assert "auto-mount-developer-disk-image" in output
    assert "developer dvt simulate-location set --rsd fd00::1 12345 -- 35.681236 139.767125" in output


def test_prove_executes_steps_in_order_when_device_is_requested():
    stdout = StringIO()
    stderr = StringIO()
    responses = {
        (
            "pmd3",
            "mounter",
            "query-developer-mode-status",
            "--rsd",
            "fd00::1",
            "12345",
        ): subprocess.CompletedProcess(args=["pmd3"], returncode=0, stdout="true\n", stderr=""),
        (
            "pmd3",
            "mounter",
            "auto-mount",
            "--rsd",
            "fd00::1",
            "12345",
        ): subprocess.CompletedProcess(args=["pmd3"], returncode=0, stdout="mounted\n", stderr=""),
    }
    runner = _runner_with_responses(responses)
    persistent_calls = []

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--ios-major",
            "17",
            "--rsd-host",
            "fd00::1",
            "--rsd-port",
            "12345",
            "--lat",
            "35.681236",
            "--lon",
            "139.767125",
        ],
        runner=runner,
        persistent_runner=lambda command, hold_seconds=None: persistent_calls.append(
            (command, hold_seconds)
        ),
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 0
    assert runner.calls == [list(command) for command in responses.keys()]
    assert persistent_calls == [
        (
            [
                "pmd3",
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--rsd",
                "fd00::1",
                "12345",
                "--",
                "35.681236",
                "139.767125",
            ],
            None,
        )
    ]
    assert "set-location: running" in stdout.getvalue()


def test_prove_rejects_ios17_without_rsd_or_tunnel():
    stdout = StringIO()
    stderr = StringIO()

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--udid",
            "abc123",
            "--ios-major",
            "17",
            "--lat",
            "35.681236",
            "--lon",
            "139.767125",
        ],
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 1
    assert "iOS 17+" in stderr.getvalue()


def test_prove_rejects_both_rsd_and_tunnel():
    stdout = StringIO()
    stderr = StringIO()

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--ios-major",
            "17",
            "--rsd-host",
            "fd00::1",
            "--rsd-port",
            "12345",
            "--tunnel",
            "abc123",
            "--lat",
            "35.681236",
            "--lon",
            "139.767125",
        ],
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 1
    assert "mutually exclusive" in stderr.getvalue()


def test_prove_rejects_invalid_coordinates():
    stdout = StringIO()
    stderr = StringIO()

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--ios-major",
            "16",
            "--lat",
            "91",
            "--lon",
            "139.767125",
        ],
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 1
    assert "latitude" in stderr.getvalue()


def test_prove_stops_when_developer_mode_is_disabled():
    stdout = StringIO()
    stderr = StringIO()
    runner = _runner_with_responses(
        {
            (
                "pmd3",
                "mounter",
                "query-developer-mode-status",
                "--udid",
                "abc123",
            ): subprocess.CompletedProcess(args=["pmd3"], returncode=0, stdout="false\n", stderr=""),
        }
    )

    exit_code = main(
        [
            "prove",
            "--pymobiledevice",
            "pmd3",
            "--udid",
            "abc123",
            "--ios-major",
            "16",
            "--lat",
            "35.681236",
            "--lon",
            "139.767125",
        ],
        runner=runner,
        stdout=stdout,
        stderr=stderr,
    )

    assert exit_code == 1
    assert "Developer Mode is disabled" in stderr.getvalue()
