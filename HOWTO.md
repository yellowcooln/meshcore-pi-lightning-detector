# HOWTO

Start-to-finish setup for the current stack:

- hardware: MeshSmith [PiMesh-1W](https://meshsmith.net/products/pimesh-1w)
- radio companion stack: `pyMC` / [`pyMC_Repeater`](https://github.com/rightup/pyMC_Repeater)
- detector app: this repository

## 1. Wire The Sensor

Connect the AS3935 breakout to the PiMesh-1W `I2C / QT` port.

Board reference:

![PiMesh-1W board layout](https://meshsmith.net/pimesh/base.png)

This project assumes the Pi I2C bus is `/dev/i2c-1`.

## 2. Clone The Repo

```bash
git clone https://github.com/yellowcooln/meshcore-pi-lightning-detector.git
cd meshcore-pi-lightning-detector
```

## 3. Make Sure I2C Is Enabled

Check for the bus first:

```bash
ls /dev/i2c-1
```

If that path exists, I2C is already enabled.

If it does not exist:

```bash
sudo raspi-config
# Interface Options -> I2C -> Enable
sudo reboot
```

After reboot:

```bash
cd ~/meshcore-pi-lightning-detector
ls /dev/i2c-1
```

## 4. Install Required Packages

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip i2c-tools
```

Optional sensor check:

```bash
i2cdetect -y 1
```

## 5. Create A Companion In pyMC

This project is intended to connect to the MeshCore companion feature inside `pyMC`.

1. Log into the `pyMC` web interface.
2. Open `Companions`.
3. Create a new companion.
4. Set a companion name.
5. Set the companion TCP port.
6. Save it.

Typical same-host setup:

- host: `127.0.0.1`
- port: `5000`

The project also works with any reachable MeshCore TCP node if you are not using local `pyMC`.

## 6. Run The Installer

```bash
chmod +x manage.sh
sudo ./manage.sh install
```

The installer will:

- create or reuse `.venv/`
- install the app into that virtualenv
- prompt for MeshCore host, port, channel name, and optional channel key
- write `config.toml`
- install and enable `meshcore-lightning.service`

If you just press Enter at the prompts on a fresh install, it uses the defaults:

- host: `0.0.0.0`
- port: `5000`
- channel: `#lightning`
- key: blank

## 7. Start And Verify

Start the service:

```bash
sudo ./manage.sh start
sudo ./manage.sh status
```

Verify the configured channel can be loaded without sending a message:

```bash
sudo ./manage.sh test
```

Send an outbound message to the configured channel:

```bash
sudo ./manage.sh send
sudo ./manage.sh send "Lightning detector manual message test"
```

Watch logs:

```bash
sudo ./manage.sh logs
```

## 8. Common Service Commands

```bash
sudo ./manage.sh stop
sudo ./manage.sh restart
sudo ./manage.sh disable
sudo ./manage.sh uninstall
```

## 9. Notes

- `test` only verifies the channel can be configured; it does not send a message.
- `send` is the outbound message test.
- `config.toml` is local deployment state and is git-ignored.
- The service runs from this repo’s `.venv`.
