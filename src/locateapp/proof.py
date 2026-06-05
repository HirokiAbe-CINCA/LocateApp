from dataclasses import dataclass

from locateapp.commands import (
    CommandError,
    build_auto_mount_command,
    build_developer_mode_status_command,
    build_reset_location_command,
    build_set_location_command,
)


@dataclass(frozen=True)
class ProofStep:
    name: str
    command: list[str]


def select_device_udid(devices: list[dict], *, requested_udid: str | None) -> str:
    if requested_udid:
        return requested_udid

    if not devices:
        raise CommandError(
            "No iPhone is visible through pymobiledevice3 usbmux. "
            "Connect the iPhone by cable, unlock it, and tap Trust on the device."
        )

    if len(devices) > 1:
        identifiers = [
            str(device.get("Identifier", "(missing Identifier)")) for device in devices
        ]
        raise CommandError(
            "Multiple iPhones are visible. Pass --udid explicitly: "
            + ", ".join(identifiers)
        )

    identifier = devices[0].get("Identifier")
    if not identifier:
        raise CommandError("No Identifier field found in the first usbmux device")

    return str(identifier)


def build_location_proof_plan(
    pymobiledevice: str,
    *,
    udid: str | None,
    rsd: tuple[str, str] | None = None,
    tunnel: str | None = None,
    ios_major: int,
    latitude: float,
    longitude: float,
    reset_after: bool,
) -> list[ProofStep]:
    steps = [
        ProofStep(
            "developer-mode-status",
            build_developer_mode_status_command(
                pymobiledevice,
                udid=udid,
                rsd=rsd,
                tunnel=tunnel,
            ),
        ),
        ProofStep(
            "auto-mount-developer-disk-image",
            build_auto_mount_command(
                pymobiledevice,
                udid=udid,
                rsd=rsd,
                tunnel=tunnel,
            ),
        ),
        ProofStep(
            "set-location",
            build_set_location_command(
                pymobiledevice,
                latitude=latitude,
                longitude=longitude,
                ios_major=ios_major,
                udid=udid,
                rsd=rsd,
                tunnel=tunnel,
            ),
        ),
    ]

    if reset_after:
        steps.append(
            ProofStep(
                "reset-location",
                build_reset_location_command(
                    pymobiledevice,
                    ios_major=ios_major,
                    udid=udid,
                    rsd=rsd,
                    tunnel=tunnel,
                ),
            )
        )

    return steps
