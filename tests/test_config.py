from hashlib import sha256
from pathlib import Path
import tempfile
import textwrap
import unittest

from app.config import load_config


class ConfigTests(unittest.TestCase):
    def test_hashtag_channel_uses_derived_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [meshcore]
                    channel_name = "#lightning"
                    channel_key = ""

                    [sensor]
                    i2c_bus = 1

                    [alerts]
                    cooldown_seconds = 0
                    """
                ).strip()
            )
            config = load_config(config_path)
            self.assertEqual(
                config.meshcore.channel_secret_bytes(),
                sha256(b"#lightning").digest()[:16],
            )

    def test_private_channel_requires_exact_hex_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [meshcore]
                    channel_name = "lightning-private"
                    channel_key = "00112233445566778899AABBCCDDEEFF"

                    [sensor]
                    i2c_bus = 1

                    [alerts]
                    cooldown_seconds = 0
                    """
                ).strip()
            )
            config = load_config(config_path)
            self.assertEqual(
                config.meshcore.channel_secret_bytes().hex().upper(),
                "00112233445566778899AABBCCDDEEFF",
            )

    def test_auto_i2c_address_maps_to_none(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [meshcore]
                    channel_name = "#lightning"
                    channel_key = ""

                    [sensor]
                    i2c_bus = 1
                    i2c_address = "auto"

                    [alerts]
                    cooldown_seconds = 0
                    """
                ).strip()
            )
            config = load_config(config_path)
            self.assertIsNone(config.sensor.i2c_address)

    def test_distance_unit_defaults_to_km(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [meshcore]
                    channel_name = "#lightning"
                    channel_key = ""

                    [sensor]
                    i2c_bus = 1

                    [alerts]
                    cooldown_seconds = 0
                    """
                ).strip()
            )
            config = load_config(config_path)
            self.assertEqual(config.alerts.distance_unit, "km")

    def test_distance_unit_must_be_km_or_mi(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.toml"
            config_path.write_text(
                textwrap.dedent(
                    """
                    [meshcore]
                    channel_name = "#lightning"
                    channel_key = ""

                    [sensor]
                    i2c_bus = 1

                    [alerts]
                    cooldown_seconds = 0
                    distance_unit = "yards"
                    """
                ).strip()
            )
            with self.assertRaisesRegex(ValueError, "alerts.distance_unit"):
                load_config(config_path)


if __name__ == "__main__":
    unittest.main()
