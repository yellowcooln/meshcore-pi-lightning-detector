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
- `manage.sh`: install and service lifecycle management
- `config.example.toml`: deployment template
- `tests/`: unit tests

## Local Setup

```bash
cd /path/to/meshcore-pi-lightning-detector
python3 -m venv .venv
. .venv/bin/activate
pip install -e .
cp config.example.toml config.toml
python -m unittest discover -s tests -v
```

## Raspberry Pi Setup

Check whether I2C is already enabled before changing anything:

```bash
ls /dev/i2c-1
```

If `/dev/i2c-1` exists, I2C is already enabled and you do not need to run `raspi-config`.

If `/dev/i2c-1` is missing, enable I2C and reboot:

```bash
sudo raspi-config
# Interface Options -> I2C -> Enable
sudo reboot
```

Install prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip i2c-tools
```

Confirm the bus and sensor:

```bash
ls /dev/i2c-1
i2cdetect -y 1
```

## Configuration

Edit `config.toml`.

### pyMC Companion Setup

If you are using the intended self-hosted layout with `pyMC_Repeater`:

1. Log into the `pyMC` web interface.
2. Go to `Companions`.
3. Create a new companion.
4. Set the companion name.
5. Set the companion TCP port. This project’s README examples assume `5000`.
6. Save the companion.
7. Use that companion IP and port in this app’s `config.toml`.

On the same host, that will typically look like:

```toml
[meshcore]
host = "127.0.0.1"
port = 5000
```

If `pyMC` is on another device, use that device’s reachable IP address instead of `127.0.0.1`.

Hashtag room example:

```toml
[meshcore]
channel_name = "#lightning"
channel_key = ""
```

Private room example:

```toml
[meshcore]
channel_name = "lightning-private"
channel_key = "00112233445566778899AABBCCDDEEFF"
```

## Service Install

```bash
chmod +x manage.sh
sudo ./manage.sh install
```

Then edit `config.toml` and start the service:

```bash
sudo ./manage.sh start
sudo ./manage.sh status
sudo ./manage.sh logs
```

Other service commands:

```bash
sudo ./manage.sh stop
sudo ./manage.sh restart
sudo ./manage.sh uninstall
```

The installer creates `/etc/systemd/system/meshcore-lightning.service` and runs the monitor from this repo’s `.venv`.

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

Run the monitor interactively:

```bash
meshcore-lightning monitor
```

## Behavior Notes

- The app reconfigures the target channel before sends by default.
- Lightning alerts are rate-limited by `alerts.cooldown_seconds`.
- Noise and disturber events are logged and can optionally be sent as messages.
- `config.toml` is local deployment state and is intentionally ignored by git.
