from __future__ import annotations

import os
import select
import time
from pathlib import Path


class GPIOInterruptMonitor:
    def __init__(self, gpio: int):
        self.gpio = gpio
        self._base_path = Path("/sys/class/gpio")
        self._gpio_path = self._base_path / f"gpio{gpio}"
        self._fd: int | None = None
        self._poller: select.poll | None = None
        self._owns_export = False

    def setup(self) -> None:
        if not self._base_path.exists():
            raise RuntimeError("/sys/class/gpio is not available on this system")

        if not self._gpio_path.exists():
            try:
                (self._base_path / "export").write_text(f"{self.gpio}", encoding="utf-8")
                self._owns_export = True
            except OSError as exc:
                raise RuntimeError(
                    f"Could not export GPIO {self.gpio}; check permissions or GPIO support"
                ) from exc

            deadline = time.monotonic() + 1.0
            while not self._gpio_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not self._gpio_path.exists():
                raise RuntimeError(f"GPIO {self.gpio} did not appear under /sys/class/gpio")

        try:
            (self._gpio_path / "direction").write_text("in", encoding="utf-8")
            # Use both edges so the monitor works regardless of the board's IRQ polarity.
            (self._gpio_path / "edge").write_text("both", encoding="utf-8")
        except OSError as exc:
            raise RuntimeError(
                f"Could not configure GPIO {self.gpio} for input interrupts"
            ) from exc

        try:
            self._fd = os.open(self._gpio_path / "value", os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            raise RuntimeError(f"Could not open GPIO {self.gpio} value file") from exc

        self._clear_value()
        self._poller = select.poll()
        self._poller.register(self._fd, select.POLLPRI | select.POLLERR)

    def wait_for_interrupt(self, timeout_seconds: float) -> bool:
        if self._fd is None or self._poller is None:
            raise RuntimeError("GPIO interrupt monitor is not set up")

        timeout_ms = max(0, int(timeout_seconds * 1000))
        self._clear_value()
        events = self._poller.poll(timeout_ms)
        if not events:
            return False
        self._clear_value()
        return True

    def close(self) -> None:
        if self._poller is not None and self._fd is not None:
            try:
                self._poller.unregister(self._fd)
            except OSError:
                pass
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
        self._fd = None
        self._poller = None

        if self._owns_export:
            try:
                (self._base_path / "unexport").write_text(f"{self.gpio}", encoding="utf-8")
            except OSError:
                pass
            self._owns_export = False

    def _clear_value(self) -> None:
        if self._fd is None:
            return
        os.lseek(self._fd, 0, os.SEEK_SET)
        try:
            os.read(self._fd, 8)
        except BlockingIOError:
            pass
