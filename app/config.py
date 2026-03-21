from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    import tomli as tomllib


DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[1] / "config.toml"


def _coerce_int(value: Any, field_name: str) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise ValueError(f"{field_name} must be an integer")


def _coerce_optional_i2c_address(value: Any, field_name: str) -> int | None:
    if isinstance(value, str) and value.strip().lower() in {"", "auto"}:
        return None
    return _coerce_int(value, field_name)


def _coerce_float(value: Any, field_name: str) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        return float(value)
    raise ValueError(f"{field_name} must be a number")


def _normalize_key(key: str) -> str:
    normalized = key.strip().replace(" ", "").replace("-", "")
    if not normalized:
        return ""
    try:
        key_bytes = bytes.fromhex(normalized)
    except ValueError as exc:
        raise ValueError("channel_key must be valid hex") from exc
    if len(key_bytes) != 16:
        raise ValueError("channel_key must be exactly 16 bytes (32 hex characters)")
    return key_bytes.hex().upper()


@dataclass(frozen=True)
class MeshCoreSettings:
    host: str
    port: int
    channel_name: str
    channel_key: str
    channel_slot: int
    always_configure_channel: bool
    connect_timeout_seconds: float

    def channel_secret_bytes(self) -> bytes:
        if self.channel_name.startswith("#"):
            return sha256(self.channel_name.encode("utf-8")).digest()[:16]
        if not self.channel_key:
            raise ValueError(
                "Private channels require meshcore.channel_key unless channel_name starts with '#'"
            )
        return bytes.fromhex(self.channel_key)


@dataclass(frozen=True)
class SensorSettings:
    i2c_bus: int
    i2c_address: int | None
    indoor: bool
    noise_floor: int
    watchdog_threshold: int
    spike_rejection: int
    minimum_lightnings: int
    mask_disturbers: bool
    reset_defaults_on_start: bool
    calibrate_on_start: bool
    clear_statistics_on_start: bool
    poll_interval_seconds: float


@dataclass(frozen=True)
class AlertSettings:
    cooldown_seconds: float
    send_noise_messages: bool
    send_disturber_messages: bool
    message_prefix: str
    distance_unit: str
    time_format: str
    lightning_message_template: str


@dataclass(frozen=True)
class LoggingSettings:
    level: str


@dataclass(frozen=True)
class AppConfig:
    meshcore: MeshCoreSettings
    sensor: SensorSettings
    alerts: AlertSettings
    logging: LoggingSettings


def load_config(path: str | Path | None = None) -> AppConfig:
    config_path = Path(path) if path else DEFAULT_CONFIG_PATH
    with config_path.open("rb") as handle:
        raw = tomllib.load(handle)

    meshcore_raw = raw.get("meshcore", {})
    sensor_raw = raw.get("sensor", {})
    alerts_raw = raw.get("alerts", {})
    logging_raw = raw.get("logging", {})

    meshcore = MeshCoreSettings(
        host=str(meshcore_raw.get("host", "0.0.0.0")).strip(),
        port=_coerce_int(meshcore_raw.get("port", 5000), "meshcore.port"),
        channel_name=str(meshcore_raw.get("channel_name", "#lightning")).strip(),
        channel_key=_normalize_key(str(meshcore_raw.get("channel_key", ""))),
        channel_slot=_coerce_int(meshcore_raw.get("channel_slot", 0), "meshcore.channel_slot"),
        always_configure_channel=bool(meshcore_raw.get("always_configure_channel", True)),
        connect_timeout_seconds=_coerce_float(
            meshcore_raw.get("connect_timeout_seconds", 10.0),
            "meshcore.connect_timeout_seconds",
        ),
    )

    sensor = SensorSettings(
        i2c_bus=_coerce_int(sensor_raw.get("i2c_bus", 1), "sensor.i2c_bus"),
        i2c_address=_coerce_optional_i2c_address(
            sensor_raw.get("i2c_address", "auto"),
            "sensor.i2c_address",
        ),
        indoor=bool(sensor_raw.get("indoor", True)),
        noise_floor=_coerce_int(sensor_raw.get("noise_floor", 2), "sensor.noise_floor"),
        watchdog_threshold=_coerce_int(
            sensor_raw.get("watchdog_threshold", 1), "sensor.watchdog_threshold"
        ),
        spike_rejection=_coerce_int(
            sensor_raw.get("spike_rejection", 2), "sensor.spike_rejection"
        ),
        minimum_lightnings=_coerce_int(
            sensor_raw.get("minimum_lightnings", 1), "sensor.minimum_lightnings"
        ),
        mask_disturbers=bool(sensor_raw.get("mask_disturbers", True)),
        reset_defaults_on_start=bool(sensor_raw.get("reset_defaults_on_start", False)),
        calibrate_on_start=bool(sensor_raw.get("calibrate_on_start", True)),
        clear_statistics_on_start=bool(sensor_raw.get("clear_statistics_on_start", True)),
        poll_interval_seconds=_coerce_float(
            sensor_raw.get("poll_interval_seconds", 0.1), "sensor.poll_interval_seconds"
        ),
    )

    alerts = AlertSettings(
        cooldown_seconds=_coerce_float(
            alerts_raw.get("cooldown_seconds", 60), "alerts.cooldown_seconds"
        ),
        send_noise_messages=bool(alerts_raw.get("send_noise_messages", False)),
        send_disturber_messages=bool(alerts_raw.get("send_disturber_messages", False)),
        message_prefix=str(alerts_raw.get("message_prefix", "AS3935")).strip(),
        distance_unit=str(alerts_raw.get("distance_unit", "km")).strip().lower(),
        time_format=str(alerts_raw.get("time_format", "24h")).strip().lower(),
        lightning_message_template=str(
            alerts_raw.get(
                "lightning_message_template",
                "Lightning detected at {time} | Distance={distance} | Energy={energy}",
            )
        ).strip(),
    )

    logging = LoggingSettings(level=str(logging_raw.get("level", "INFO")).upper())

    _validate_config(meshcore, sensor, alerts)
    return AppConfig(meshcore=meshcore, sensor=sensor, alerts=alerts, logging=logging)


def _validate_config(
    meshcore: MeshCoreSettings, sensor: SensorSettings, alerts: AlertSettings
) -> None:
    if not meshcore.host:
        raise ValueError("meshcore.host must not be blank")
    if meshcore.port <= 0 or meshcore.port > 65535:
        raise ValueError("meshcore.port must be between 1 and 65535")
    if not meshcore.channel_name:
        raise ValueError("meshcore.channel_name must not be blank")
    if meshcore.channel_slot < 0 or meshcore.channel_slot > 255:
        raise ValueError("meshcore.channel_slot must be between 0 and 255")
    meshcore.channel_secret_bytes()

    if sensor.i2c_bus < 0:
        raise ValueError("sensor.i2c_bus must be zero or greater")
    if sensor.i2c_address is not None and (sensor.i2c_address < 0 or sensor.i2c_address > 0x7F):
        raise ValueError("sensor.i2c_address must be a 7-bit I2C address")
    if not 0 <= sensor.noise_floor <= 7:
        raise ValueError("sensor.noise_floor must be between 0 and 7")
    if not 0 <= sensor.watchdog_threshold <= 15:
        raise ValueError("sensor.watchdog_threshold must be between 0 and 15")
    if not 0 <= sensor.spike_rejection <= 15:
        raise ValueError("sensor.spike_rejection must be between 0 and 15")
    if sensor.minimum_lightnings not in {1, 5, 9, 16}:
        raise ValueError("sensor.minimum_lightnings must be one of 1, 5, 9, or 16")
    if sensor.poll_interval_seconds <= 0:
        raise ValueError("sensor.poll_interval_seconds must be greater than 0")
    if alerts.cooldown_seconds < 0:
        raise ValueError("alerts.cooldown_seconds must be zero or greater")
    if alerts.distance_unit not in {"km", "mi"}:
        raise ValueError("alerts.distance_unit must be 'km' or 'mi'")
    if alerts.time_format not in {"24h", "12h"}:
        raise ValueError("alerts.time_format must be '24h' or '12h'")
