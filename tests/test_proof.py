import pytest

from locateapp.commands import CommandError
from locateapp.proof import build_location_proof_plan, select_device_udid


def test_select_device_udid_uses_only_identifier_when_not_specified():
    assert (
        select_device_udid(
            [
                {"ConnectionType": "USB", "Identifier": "only"},
            ],
            requested_udid=None,
        )
        == "only"
    )


def test_select_device_udid_fails_when_multiple_devices_are_visible():
    with pytest.raises(CommandError, match="Multiple iPhones"):
        select_device_udid(
            [
                {"ConnectionType": "USB", "Identifier": "first"},
                {"ConnectionType": "USB", "Identifier": "second"},
            ],
            requested_udid=None,
        )


def test_select_device_udid_honors_requested_udid():
    assert select_device_udid([], requested_udid="manual") == "manual"


def test_select_device_udid_fails_when_no_device_is_connected():
    with pytest.raises(CommandError, match="No iPhone is visible"):
        select_device_udid([], requested_udid=None)


def test_build_location_proof_plan_for_ios17_without_reset():
    plan = build_location_proof_plan(
        "pmd3",
        udid=None,
        rsd=("fd00::1", "12345"),
        ios_major=17,
        latitude=35.681236,
        longitude=139.767125,
        reset_after=False,
    )

    assert [step.name for step in plan] == [
        "developer-mode-status",
        "auto-mount-developer-disk-image",
        "set-location",
    ]
    assert plan[-1].command == [
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
    ]


def test_build_location_proof_plan_can_reset_after_set():
    plan = build_location_proof_plan(
        "pmd3",
        udid="abc123",
        ios_major=16,
        latitude=35.681236,
        longitude=139.767125,
        reset_after=True,
    )

    assert [step.name for step in plan] == [
        "developer-mode-status",
        "auto-mount-developer-disk-image",
        "set-location",
        "reset-location",
    ]
    assert plan[-1].command == [
        "pmd3",
        "developer",
        "simulate-location",
        "clear",
        "--udid",
        "abc123",
    ]
