import unittest

from app.config import AlertSettings, AppConfig, LoggingSettings, MeshCoreSettings, SensorSettings
from app.main import format_alert_message


class MainTests(unittest.TestCase):
    def test_format_lightning_alert(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="192.168.30.52",
                port=5002,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=0x03,
                indoor=True,
                noise_floor=2,
                watchdog_threshold=1,
                spike_rejection=2,
                minimum_lightnings=1,
                mask_disturbers=True,
                reset_defaults_on_start=False,
                calibrate_on_start=True,
                clear_statistics_on_start=True,
                poll_interval_seconds=0.1,
            ),
            alerts=AlertSettings(
                cooldown_seconds=60.0,
                send_noise_messages=False,
                send_disturber_messages=False,
                message_prefix="AS3935",
            ),
            logging=LoggingSettings(level="INFO"),
        )
        event = type(
            "Event",
            (),
            {
                "kind": "lightning",
                "interrupt_code": 0x08,
                "energy": 12345,
                "distance_text": "12 km",
            },
        )()
        self.assertEqual(
            format_alert_message(config, event),
            "AS3935: lightning detected | distance=12 km | energy=12345",
        )


if __name__ == "__main__":
    unittest.main()
