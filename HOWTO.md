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
By default, the app uses `i2c_address = "auto"` and will try to guess the AS3935 address on that bus.

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

If the app later logs:

```text
Set sensor.i2c_address explicitly in config.toml.
```

use `i2cdetect` to find the sensor address, then set it manually:

```bash
i2cdetect -y 1
nano config.toml
```

Look for a device at one of the common AS3935 addresses:

- `0x03`
- `0x02`
- `0x01`
- `0x00`

Then update the `[sensor]` section in `config.toml`:

```toml
[sensor]
i2c_bus = 1
i2c_address = "0x03"
```

After saving the file, restart the service:

```bash
sudo bash manage.sh restart
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

- host: `0.0.0.0`
- port: `5000`

The project also works with any reachable MeshCore TCP node if you are not using local `pyMC`.

## 6. Run The Installer

```bash
sudo bash manage.sh install
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
sudo bash manage.sh start
```

If you want to start the service and immediately follow the logs:

```bash
sudo bash manage.sh start logs
```

Verify the configured channel can be loaded without sending a message:

```bash
sudo bash manage.sh test
```

Send an outbound message to the configured channel:

```bash
sudo bash manage.sh send
sudo bash manage.sh send "Lightning detector manual message test"
```

If you run `send` without a message, it sends a sample rendered from the currently configured lightning message template.

Watch logs:

```bash
sudo bash manage.sh logs
```

## 8. Common Service Commands

```bash
sudo bash manage.sh stop
sudo bash manage.sh restart
sudo bash manage.sh disable
sudo bash manage.sh uninstall
```

## 9. Change The Lightning Message Later

If you want to change the outbound lightning message after install, run:

```bash
sudo bash manage.sh setup
```

That command gives you preset message styles first, lets you choose `km` or `mi` for `{distance}`, lets you choose `12h` or `24h` for `{time}`, and only asks for a full template if you choose the custom option. The built-in presets include `Lightning detected at {time} | Distance={distance} | Energy={energy}`, `Lightning detected at {time}`, `Lightning detected at {time} on {date}`, and `Lightning detected`. It then updates `config.toml`.

Available placeholders in the template are:

- `{prefix}`
- `{distance}`
- `{energy}`
- `{interrupt_code}`
- `{kind}`
- `{time}`
- `{time24}`
- `{time12}`
- `{date}`

Example:

```text
Lightning detected at {time} on {date}
```

## 10. Notes

- `test` only verifies the channel can be configured; it does not send a message.
- `send` is the outbound message test. Without an explicit message, it sends a sample rendered from the current lightning template.
- `config.toml` is local deployment state and is git-ignored.
- The service runs from this repo’s `.venv`.
- If startup says `Set sensor.i2c_address explicitly in config.toml.`, run `i2cdetect -y 1`, set `[sensor].i2c_address` in `config.toml`, then `sudo bash manage.sh restart`.

## 11. config.toml Reference

The installer writes `config.toml` for you. You usually only need to change the `meshcore` section, but the other sections control sensor behavior and alerting.

### `[meshcore]`

- `host`: MeshCore TCP host or IP. For the intended local `pyMC` companion setup, use `0.0.0.0`.
- `port`: MeshCore TCP port. The current stack assumes `5000`.
- `channel_name`: Target room name. If it starts with `#`, the app derives the room key from the name.
- `channel_key`: Optional 32-hex-character key for private channels. Leave blank for hashtag rooms.
- `channel_slot`: Temporary radio slot the app uses when loading the channel before send.
- `always_configure_channel`: When `true`, the app loads the channel before each send instead of assuming the radio already has it.
- `connect_timeout_seconds`: TCP connect timeout for the MeshCore node.

### `[sensor]`

- `i2c_bus`: Linux I2C bus number. On the PiMesh-1W this should be `1`.
- `i2c_address`: AS3935 I2C address. Use `"auto"` to try the common AS3935 addresses automatically, or set an explicit value such as `"0x03"` if needed.
- `indoor`: Sets the AS3935 indoor/outdoor front-end mode.
- `noise_floor`: Noise threshold tuning. Higher values make the detector less sensitive to background noise.
- `watchdog_threshold`: Event qualification threshold used by the AS3935.
- `spike_rejection`: Rejects short spikes that are not likely to be real lightning events.
- `minimum_lightnings`: Number of strikes needed before the sensor reports an event. Valid values are `1`, `5`, `9`, or `16`.
- `mask_disturbers`: When `true`, filters out some man-made interference classifications.
- `reset_defaults_on_start`: Resets the AS3935 registers to defaults before applying this config.
- `calibrate_on_start`: Runs AS3935 calibration during app startup.
- `clear_statistics_on_start`: Clears the sensor’s internal lightning statistics at startup.
- `poll_interval_seconds`: Poll interval for checking sensor interrupts.

### `[alerts]`

- `cooldown_seconds`: Minimum time between lightning alert messages.
- `send_noise_messages`: When `true`, noise interrupts are also sent as channel messages.
- `send_disturber_messages`: When `true`, disturber events are also sent as channel messages.
- `message_prefix`: Prefix added to outbound alert text.
- `distance_unit`: Unit used when rendering `{distance}` in lightning message templates. Valid values are `km` and `mi`.
- `time_format`: Format used when rendering `{time}` in lightning message templates. Valid values are `24h` and `12h`. Use `{time24}` or `{time12}` if you want to bypass this setting in a template.
- `lightning_message_template`: Template for the actual lightning alert text. Supports `{prefix}`, `{distance}`, `{energy}`, `{interrupt_code}`, `{kind}`, `{time}`, `{time24}`, `{time12}`, and `{date}`. The current defaults do not include the prefix because the MeshCore sender name is already present on channel messages.

### `[logging]`

- `level`: Log verbosity, typically `INFO` or `DEBUG`.
