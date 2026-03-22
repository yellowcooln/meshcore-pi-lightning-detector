import unittest

from app.config import AlertSettings, AppConfig, LoggingSettings, MeshCoreSettings, SensorSettings
from app.main import format_alert_message


class MainTests(unittest.TestCase):
    def test_format_lightning_alert(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="0.0.0.0",
                port=5000,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=0x03,
                irq_gpio=None,
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
                distance_unit="km",
                time_format="24h",
                lightning_message_template="Lightning detected | Distance={distance} | Energy={energy}",
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
                "distance_km": 12,
                "distance_text": "12 km",
            },
        )()
        self.assertEqual(
            format_alert_message(config, event),
            "Lightning detected | Distance=12 km | Energy=12345",
        )

    def test_format_lightning_alert_uses_template(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="0.0.0.0",
                port=5000,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=None,
                irq_gpio=None,
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
                distance_unit="km",
                time_format="24h",
                lightning_message_template="Strike: {distance} / {energy}",
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
                "distance_km": 12,
                "distance_text": "12 km",
            },
        )()
        self.assertEqual(format_alert_message(config, event), "Strike: 12 km / 12345")

    def test_format_lightning_alert_supports_time_placeholder(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="0.0.0.0",
                port=5000,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=None,
                irq_gpio=None,
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
                distance_unit="km",
                time_format="24h",
                lightning_message_template="Lightning detected at {time} on {date}",
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
                "distance_km": 12,
                "distance_text": "12 km",
            },
        )()
        message = format_alert_message(config, event)
        self.assertTrue(message.startswith("Lightning detected at "))
        self.assertIn(" on ", message)

    def test_format_lightning_alert_supports_miles(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="0.0.0.0",
                port=5000,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=None,
                irq_gpio=None,
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
                distance_unit="mi",
                time_format="24h",
                lightning_message_template="Strike: {distance}",
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
                "distance_km": 12,
                "distance_text": "12 km",
            },
        )()
        self.assertEqual(format_alert_message(config, event), "Strike: 7.5 mi")

    def test_format_lightning_alert_supports_12h_time_selector(self) -> None:
        config = AppConfig(
            meshcore=MeshCoreSettings(
                host="0.0.0.0",
                port=5000,
                channel_name="#lightning",
                channel_key="",
                channel_slot=0,
                always_configure_channel=True,
                connect_timeout_seconds=10.0,
            ),
            sensor=SensorSettings(
                i2c_bus=1,
                i2c_address=None,
                irq_gpio=None,
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
                distance_unit="km",
                time_format="12h",
                lightning_message_template="Lightning detected at {time}",
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
                "distance_km": 12,
                "distance_text": "12 km",
            },
        )()
        message = format_alert_message(config, event)
        self.assertRegex(message, r"Lightning detected at \d{2}:\d{2}:\d{2} (AM|PM)")


if __name__ == "__main__":
    unittest.main()
