# MeshCore Pi Lightning Detector

Python service for a Raspberry Pi that reads an AS3935 lightning sensor over I2C and publishes lightning alerts to a MeshCore node over TCP.

This project was made for and tested against the MeshSmith [PiMesh-1W](https://meshsmith.net/products/pimesh-1w).

Current defaults:

- MeshCore TCP companion listener: `0.0.0.0:5000`
- Default room: `#lightning`
- Raspberry Pi I2C bus: `/dev/i2c-1`

## Project Scope

This project is meant to run unattended on a Pi as a small field service:

- configure and poll an AS3935
- classify interrupts as lightning, noise, or disturber events
- send alerts to a MeshCore channel
- install cleanly as a `systemd` service with `manage.sh`

The intended deployment model is to run this on the same device as the MeshCore radio and connect back to that node through the companion feature inside `pyMC` / [`pyMC_Repeater`](https://github.com/rightup/pyMC_Repeater) on `0.0.0.0:5000`. The app is not limited to that layout, though. It will also work with any reachable MeshCore TCP node.

The MeshCore TCP send path and dynamic channel loading were verified against a live node. Hardware polling logic is implemented but still needs end-to-end validation on the final Pi plus sensor assembly.

## Hardware Wiring

Primary target hardware is the MeshSmith PiMesh-1W. The I2C assumptions in this project, including use of `/dev/i2c-1`, are based on that platform.

Tested sensor module:

- AS3935 `CJMCU-3935` style breakout, purchased as: https://www.amazon.com/dp/B07SST5GDB

On the PiMesh-1W, that AS3935 breakout should connect to the board's `I2C / QT` port through the sensor board's `CN1` header.

If you need to map that back to the underlying Raspberry Pi header, the I2C lines are:

- `3V3`: pin `1` or `17`
- `SDA`: pin `3` / `GPIO2`
- `SCL`: pin `5` / `GPIO3`
- `GND`: any Pi ground pin

If your breakout exposes Qwiic / STEMMA QT, it should plug into that PiMesh-1W `I2C / QT` port and still map to the same Pi I2C bus.

For the tested board, the connector you actually use is `CN1` with this printed pinout:

- `1 GND`
- `2 +3V3`
- `3 SDA_3V`
- `4 SCL_3V`

So the working wiring to the PiMesh-1W `I2C / QT` side is just:

- `CN1 pin 1 GND` -> PiMesh `GND`
- `CN1 pin 2 +3V3` -> PiMesh `3.3V`
- `CN1 pin 3 SDA_3V` -> PiMesh `SDA`
- `CN1 pin 4 SCL_3V` -> PiMesh `SCL`

The lower-level AS3935 mode/address strapping is already handled on that tested board variant, so the app only needs the 4 I2C pins above.

## Repository Layout

- `app/main.py`: CLI entrypoint and monitor loop
- `app/as3935.py`: I2C register reads/writes and event parsing
- `app/meshcore_client.py`: MeshCore TCP connect, channel configure, and send logic
- `app/config.py`: TOML config loading and validation
- `HOWTO.md`: start-to-finish deployment guide for the current stack
- `BUILDROOT.md`: Buildroot / Luckfox deployment notes and image requirements
- `manage.sh`: install and service lifecycle management
- `buildroot-manage.sh`: Buildroot-oriented install and process management
- `config.example.toml`: deployment template
- `tests/`: unit tests

## Setup Guide

For the full current-stack deployment guide, read [HOWTO.md](HOWTO.md).

For Buildroot / Luckfox images, read [BUILDROOT.md](BUILDROOT.md).

That guide covers:

- wiring the AS3935 to the PiMesh-1W `I2C / QT` port
- enabling Raspberry Pi I2C only if needed
- creating the companion in `pyMC`
- running `sudo bash manage.sh install`
- running `sudo bash manage.sh upgrade` to pull updates and restart the service
- running `sudo bash manage.sh setup` to change the lightning message template
- verifying the channel with `sudo bash manage.sh test`
- sending a live outbound message with `sudo bash manage.sh send`

## Local Setup

If you want to work on the code manually instead of using the service flow:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -e .
cp config.example.toml config.toml
python -m unittest discover -s tests -v
```

## Behavior Notes

- The app reconfigures the target channel before sends by default.
- By default, the sensor address is set to `i2c_address = "auto"` and the app will try the common AS3935 I2C addresses on startup.
- Default lightning message templates no longer include the app prefix, because MeshCore already shows the sender node name on channel messages.
- Lightning alerts are rate-limited by `alerts.cooldown_seconds`.
- Noise and disturber events are logged and can optionally be sent as messages.
- `config.toml` is local deployment state and is intentionally ignored by git.

## Support

If you want to support this work, you can use [Ko-fi](https://ko-fi.com/yellowcooln).
