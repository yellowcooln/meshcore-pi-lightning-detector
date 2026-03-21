from __future__ import annotations

import argparse
import asyncio
from dataclasses import replace
import logging
import signal
import time
from datetime import datetime

from app.as3935 import AS3935
from app.config import AppConfig, DEFAULT_CONFIG_PATH, load_config
from app.meshcore_client import MeshCoreChannelClient


logger = logging.getLogger(__name__)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AS3935 to MeshCore TCP alert bridge")
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG_PATH),
        help="Path to config TOML file",
    )
    parser.add_argument(
        "--channel-name",
        default=None,
        help="Override meshcore.channel_name for this run",
    )
    parser.add_argument(
        "--channel-key",
        default=None,
        help="Override meshcore.channel_key for this run (32 hex chars for private channels)",
    )
    parser.add_argument(
        "--channel-slot",
        type=int,
        default=None,
        help="Override meshcore.channel_slot for this run",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    monitor_parser = subparsers.add_parser("monitor", help="Run the continuous sensor monitor")
    monitor_parser.set_defaults(command="monitor")

    send_test_parser = subparsers.add_parser("send-test", help="Send a test channel message")
    send_test_parser.add_argument(
        "--message",
        default="AS3935 MeshCore link test",
        help="Message text to send",
    )
    send_test_parser.set_defaults(command="send-test")

    verify_parser = subparsers.add_parser(
        "verify-channel",
        help="Connect, configure the target channel, and optionally send a probe message",
    )
    verify_parser.add_argument(
        "--send-probe",
        action="store_true",
        help="Send a short probe message after configuring the channel",
    )
    verify_parser.add_argument(
        "--message",
        default="MeshCore channel verification probe",
        help="Probe message text when --send-probe is used",
    )
    verify_parser.set_defaults(command="verify-channel")
    return parser


def configure_logging(config: AppConfig) -> None:
    level_name = config.logging.level.upper()
    level = getattr(logging, level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def apply_runtime_overrides(config: AppConfig, args: argparse.Namespace) -> AppConfig:
    if (
        args.channel_name is None
        and args.channel_key is None
        and args.channel_slot is None
    ):
        return config

    meshcore = replace(
        config.meshcore,
        channel_name=args.channel_name if args.channel_name is not None else config.meshcore.channel_name,
        channel_key=args.channel_key if args.channel_key is not None else config.meshcore.channel_key,
        channel_slot=args.channel_slot if args.channel_slot is not None else config.meshcore.channel_slot,
    )
    # Reuse existing validation by calling the derived-key path.
    meshcore.channel_secret_bytes()
    return replace(config, meshcore=meshcore)


def format_alert_message(config: AppConfig, event) -> str:
    prefix = config.alerts.message_prefix
    if event.kind == "lightning":
        class SafeFormatDict(dict):
            def __missing__(self, key):
                return "{" + key + "}"

        now = datetime.now().astimezone()
        return config.alerts.lightning_message_template.format_map(
            SafeFormatDict(
                prefix=prefix,
                distance=event.distance_text or "distance unavailable",
                energy=event.energy if event.energy is not None else "unknown",
                interrupt_code=f"0x{event.interrupt_code:02X}",
                kind=event.kind,
                time=now.strftime("%H:%M:%S"),
                time24=now.strftime("%H:%M:%S"),
                time12=now.strftime("%I:%M:%S %p"),
                date=now.strftime("%Y-%m-%d"),
            )
        )
    if event.kind == "noise":
        return f"{prefix}: sensor noise floor too high"
    if event.kind == "disturber":
        return f"{prefix}: disturber detected"
    return f"{prefix}: sensor interrupt 0x{event.interrupt_code:02X}"


async def run_monitor(config: AppConfig) -> None:
    sensor = AS3935(config.sensor)
    client = MeshCoreChannelClient(config.meshcore)
    last_interrupt = 0
    last_lightning_alert_monotonic = 0.0
    should_stop = False

    def _request_stop(*_args) -> None:
        nonlocal should_stop
        should_stop = True

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _request_stop)
        except NotImplementedError:
            signal.signal(sig, lambda *_args: _request_stop())

    try:
        sensor.configure()
        logger.info("AS3935 configured at I2C address 0x%02X", sensor.address)
        await client.connect()
        logger.info("Sensor configured and MeshCore connection established")

        while not should_stop:
            event = sensor.read_event()
            if event is None:
                last_interrupt = 0
                await asyncio.sleep(config.sensor.poll_interval_seconds)
                continue

            if event.interrupt_code == last_interrupt:
                await asyncio.sleep(config.sensor.poll_interval_seconds)
                continue

            last_interrupt = event.interrupt_code
            logger.info("AS3935 event: %s", event)

            if event.kind == "lightning":
                now_monotonic = time.monotonic()
                if (
                    config.alerts.cooldown_seconds > 0
                    and now_monotonic - last_lightning_alert_monotonic
                    < config.alerts.cooldown_seconds
                ):
                    logger.info("Skipping lightning alert because cooldown is active")
                else:
                    await client.send_message(format_alert_message(config, event))
                    last_lightning_alert_monotonic = now_monotonic
            elif event.kind == "noise" and config.alerts.send_noise_messages:
                await client.send_message(format_alert_message(config, event))
            elif event.kind == "disturber" and config.alerts.send_disturber_messages:
                await client.send_message(format_alert_message(config, event))

            await asyncio.sleep(config.sensor.poll_interval_seconds)
    finally:
        sensor.close()
        await client.close()


async def run_send_test(config: AppConfig, message: str) -> None:
    client = MeshCoreChannelClient(config.meshcore)
    try:
        await client.connect()
        await client.send_message(message)
    finally:
        await client.close()


async def run_verify_channel(config: AppConfig, send_probe: bool, message: str) -> None:
    client = MeshCoreChannelClient(config.meshcore)
    try:
        await client.connect()
        probe_message = message if send_probe else None
        await client.verify_channel(probe_message=probe_message)
        if send_probe:
            print(
                "PASS: connected, configured channel "
                f"{config.meshcore.channel_name!r} in slot {config.meshcore.channel_slot}, "
                "and sent probe message"
            )
        else:
            print(
                "PASS: connected and configured channel "
                f"{config.meshcore.channel_name!r} in slot {config.meshcore.channel_slot}"
            )
    finally:
        await client.close()


async def async_main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    config = apply_runtime_overrides(load_config(args.config), args)
    configure_logging(config)

    if args.command == "send-test":
        await run_send_test(config, args.message)
        return 0

    if args.command == "verify-channel":
        await run_verify_channel(config, args.send_probe, args.message)
        return 0

    await run_monitor(config)
    return 0


def main() -> None:
    raise SystemExit(asyncio.run(async_main()))


if __name__ == "__main__":
    main()
