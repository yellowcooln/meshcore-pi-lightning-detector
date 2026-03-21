# BUILDROOT

This repository can run on a Luckfox / Buildroot image, but it uses a different management path than the Raspberry Pi `systemd` flow.

Use:

```sh
sh buildroot-manage.sh install
sh buildroot-manage.sh start
sh buildroot-manage.sh start logs
```

## What The Image Needs

Required:

- `/bin/sh`
- Python `3.10+`
- `python3 -m pip`
- I2C userspace enabled, with the sensor visible on a Linux I2C device such as `/dev/i2c-1`
- network access to the target MeshCore TCP node
- basic userland tools: `cp`, `mkdir`, `rm`, `chmod`, `tail`, `kill`, `nohup`

Preferred:

- `python3 -m venv`
  If `venv` is present, `buildroot-manage.sh` creates `.venv/`.
  If `venv` is missing, it falls back to a repo-local target install in `.buildroot-runtime/site-packages/`.

Optional:

- `git`
  Needed only for `sh buildroot-manage.sh upgrade`.
- `sudo`
  Not required if you are already logged in as `root`.
- BusyBox / SysV init
  Needed only if you want `sh buildroot-manage.sh install-init-script`.

## Python Package Notes

The app depends on:

- `meshcore==2.3.1`
- `smbus2>=0.4.3`
- `tomli` on Python `<3.11`

If your Buildroot image cannot install wheels for all dependencies, you may need:

- a working compiler toolchain
- Python build support
- SSL / certificate support for `pip`

## Commands

Main commands:

```sh
sh buildroot-manage.sh install
sh buildroot-manage.sh upgrade
sh buildroot-manage.sh setup
sh buildroot-manage.sh run
sh buildroot-manage.sh start
sh buildroot-manage.sh start logs
sh buildroot-manage.sh stop
sh buildroot-manage.sh restart
sh buildroot-manage.sh status
sh buildroot-manage.sh logs
sh buildroot-manage.sh test
sh buildroot-manage.sh send
sh buildroot-manage.sh send "Lightning detector manual message test"
```

BusyBox init script:

```sh
sh buildroot-manage.sh install-init-script
sh buildroot-manage.sh uninstall-init-script
```

## Runtime Model

`buildroot-manage.sh` does not use `systemd`.

Instead it:

- writes a launcher into `.buildroot-runtime/`
- starts the monitor in the background with `nohup`
- stores the PID in `.buildroot-runtime/meshcore-lightning.pid`
- writes logs to `.buildroot-runtime/meshcore-lightning.log`

## Notes

- The script assumes a writable git clone of this repo.
- `upgrade` refuses to run if the git worktree is dirty.
- If the app says `Set sensor.i2c_address explicitly in config.toml.`, run `i2cdetect -y 1`, then set `[sensor].i2c_address` manually in `config.toml`.
