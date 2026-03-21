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

On the PiMesh-1W, the AS3935 should connect to the board's `I2C / QT` port.

![PiMesh-1W board layout](https://meshsmith.net/pimesh/base.png)

If you need to map that back to the underlying Raspberry Pi header, the I2C lines are:

- `3V3`: pin `1` or `17`
- `SDA`: pin `3` / `GPIO2`
- `SCL`: pin `5` / `GPIO3`
- `GND`: any Pi ground pin

If your breakout exposes Qwiic / STEMMA QT, it should plug into that PiMesh-1W `I2C / QT` port and still map to the same Pi I2C bus.

## Repository Layout

- `app/main.py`: CLI entrypoint and monitor loop
- `app/as3935.py`: I2C register reads/writes and event parsing
- `app/meshcore_client.py`: MeshCore TCP connect, channel configure, and send logic
- `app/config.py`: TOML config loading and validation
- `HOWTO.md`: start-to-finish deployment guide for the current stack
- `manage.sh`: install and service lifecycle management
- `config.example.toml`: deployment template
- `tests/`: unit tests

## Setup Guide

For the full current-stack deployment guide, read [HOWTO.md](HOWTO.md).

That guide covers:

- wiring the AS3935 to the PiMesh-1W `I2C / QT` port
- enabling Raspberry Pi I2C only if needed
- creating the companion in `pyMC`
- running `sudo bash manage.sh install`
- running `sudo bash manage.sh setup` to change the lightning message template
- verifying the channel with `sudo bash manage.sh test`
- sending a live outbound message with `sudo bash manage.sh send`

## Useful Commands

One-off MeshCore send test:

```bash
meshcore-lightning send-test --message "AS3935 MeshCore link test"
```

Verify that the configured channel can be loaded, even if it is not already on the radio:

```bash
meshcore-lightning verify-channel --send-probe
meshcore-lightning --channel-name "#temporary-check" verify-channel --send-probe
```

Verify that the configured channel can be loaded without sending a message:

```bash
sudo bash manage.sh test
```

Send a message to the configured channel through the project-managed virtualenv:

```bash
sudo bash manage.sh send
sudo bash manage.sh send "Lightning detector manual message test"
```

When you run `send` with no message, it sends a sample rendered from your current `lightning_message_template`.

Reconfigure the lightning alert message template:

```bash
sudo bash manage.sh setup
```

`setup` offers preset message styles, lets you choose `km` or `mi` for `{distance}`, lets you choose `12h` or `24h` for `{time}`, and only asks for a full template if you choose the custom option. The built-in styles include `lightning detected at {time} | distance={distance} | energy={energy}`, `lightning detected at {time}`, `lightning detected at {time} on {date}`, and `lightning detected`. Available time placeholders include `{time}`, `{time24}`, `{time12}`, and `{date}`.

Run the monitor interactively:

```bash
meshcore-lightning monitor
```

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
