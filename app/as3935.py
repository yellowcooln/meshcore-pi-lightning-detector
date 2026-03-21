from __future__ import annotations

from dataclasses import dataclass
import time

from smbus2 import SMBus

from app.config import SensorSettings


INT_NOISE = 0x01
INT_DISTURBER = 0x04
INT_LIGHTNING = 0x08

REG_AFE = 0x00
REG_NOISE_FLOOR = 0x01
REG_ALGORITHM = 0x02
REG_INTERRUPT = 0x03
REG_ENERGY_LSB = 0x04
REG_ENERGY_MSB = 0x05
REG_ENERGY_MM = 0x06
REG_DISTANCE = 0x07

CMD_PRESET_DEFAULT = 0x3C
CMD_CALIBRATE_RCO = 0x3D
DIRECT_COMMAND_VALUE = 0x96

INDOOR_AFE_VALUE = 0b10010
OUTDOOR_AFE_VALUE = 0b01110

MIN_LIGHTNING_BITS = {
    1: 0b00,
    5: 0b01,
    9: 0b10,
    16: 0b11,
}


@dataclass(frozen=True)
class LightningEvent:
    kind: str
    interrupt_code: int
    energy: int | None = None
    distance_km: int | None = None
    distance_text: str | None = None


class AS3935:
    def __init__(self, settings: SensorSettings):
        self.settings = settings
        self._bus = SMBus(settings.i2c_bus)
        self._address = settings.i2c_address

    def close(self) -> None:
        self._bus.close()

    def configure(self) -> None:
        if self.settings.reset_defaults_on_start:
            self._send_direct_command(CMD_PRESET_DEFAULT)
            time.sleep(0.005)

        self._set_afe_mode(indoor=self.settings.indoor)
        self._update_bits(REG_NOISE_FLOOR, mask=0x70, value=(self.settings.noise_floor & 0x07) << 4)
        self._update_bits(REG_NOISE_FLOOR, mask=0x0F, value=self.settings.watchdog_threshold & 0x0F)
        self._update_bits(
            REG_ALGORITHM,
            mask=0x30,
            value=MIN_LIGHTNING_BITS[self.settings.minimum_lightnings] << 4,
        )
        self._update_bits(REG_ALGORITHM, mask=0x0F, value=self.settings.spike_rejection & 0x0F)
        self._update_bits(REG_INTERRUPT, mask=0x20, value=0x20 if self.settings.mask_disturbers else 0x00)

        if self.settings.clear_statistics_on_start:
            self.clear_statistics()

        if self.settings.calibrate_on_start:
            self._send_direct_command(CMD_CALIBRATE_RCO)
            time.sleep(0.005)

    def clear_statistics(self) -> None:
        # Datasheet: toggle REG0x02[6] high-low-high.
        self._update_bits(REG_ALGORITHM, mask=0x40, value=0x40)
        self._update_bits(REG_ALGORITHM, mask=0x40, value=0x00)
        self._update_bits(REG_ALGORITHM, mask=0x40, value=0x40)

    def read_event(self) -> LightningEvent | None:
        code = self.read_interrupt_code()
        if code == 0:
            return None
        if code == INT_NOISE:
            return LightningEvent(kind="noise", interrupt_code=code)
        if code == INT_DISTURBER:
            return LightningEvent(kind="disturber", interrupt_code=code)
        if code == INT_LIGHTNING:
            distance_raw = self._read_register(REG_DISTANCE) & 0x3F
            energy = self.read_energy()
            return LightningEvent(
                kind="lightning",
                interrupt_code=code,
                energy=energy,
                distance_km=self._distance_to_km(distance_raw),
                distance_text=self._distance_to_text(distance_raw),
            )
        return LightningEvent(kind="unknown", interrupt_code=code)

    def read_interrupt_code(self) -> int:
        return self._read_register(REG_INTERRUPT) & 0x0F

    def read_energy(self) -> int:
        lsb = self._read_register(REG_ENERGY_LSB)
        msb = self._read_register(REG_ENERGY_MSB)
        mmsb = self._read_register(REG_ENERGY_MM) & 0x1F
        return (mmsb << 16) | (msb << 8) | lsb

    def _set_afe_mode(self, *, indoor: bool) -> None:
        afe_value = INDOOR_AFE_VALUE if indoor else OUTDOOR_AFE_VALUE
        self._update_bits(REG_AFE, mask=0x3E, value=afe_value << 1)

    def _send_direct_command(self, register: int) -> None:
        self._write_register(register, DIRECT_COMMAND_VALUE)

    def _read_register(self, register: int) -> int:
        return self._bus.read_byte_data(self._address, register)

    def _write_register(self, register: int, value: int) -> None:
        self._bus.write_byte_data(self._address, register, value & 0xFF)

    def _update_bits(self, register: int, *, mask: int, value: int) -> None:
        current = self._read_register(register)
        updated = (current & ~mask) | (value & mask)
        self._write_register(register, updated)

    @staticmethod
    def _distance_to_km(raw_distance: int) -> int | None:
        if raw_distance in (0, 0x3F):
            return None
        if raw_distance == 0x01:
            return 0
        return raw_distance

    @staticmethod
    def _distance_to_text(raw_distance: int) -> str:
        if raw_distance == 0x01:
            return "storm overhead"
        if raw_distance == 0x3F:
            return "out of range"
        if raw_distance == 0:
            return "distance unavailable"
        return f"{raw_distance} km"
