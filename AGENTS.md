# Repository Guidelines

## Project Structure & Module Organization

The codebase is a small Python application for reading an AS3935 lightning sensor and sending alerts through a MeshCore TCP node.

- `app/`: runtime code
- `app/main.py`: CLI entrypoint (`monitor`, `send-test`, `verify-channel`)
- `app/as3935.py`: AS3935 I2C register access and event parsing
- `app/meshcore_client.py`: MeshCore TCP connection and channel send/verify logic
- `app/config.py`: TOML config loading and validation
- `tests/`: unit tests
- `config.example.toml`: template for deployments
- `config.toml`: local runtime config, usually environment-specific

## Build, Test, and Development Commands

- `python3 -m venv .venv && . .venv/bin/activate`: create and activate a virtual environment
- `pip install -e .`: install the project in editable mode
- `python -m unittest discover -s tests -v`: run the full test suite
- `python -m compileall app`: catch syntax/import issues quickly
- `meshcore-lightning send-test --message "test"`: verify MeshCore TCP send path
- `meshcore-lightning verify-channel --send-probe`: confirm the configured channel can be loaded and used
- `meshcore-lightning monitor`: start the sensor polling loop

## Coding Style & Naming Conventions

Use Python 3.10+ with 4-space indentation and type hints on public functions. Prefer small, single-purpose modules and direct control flow over framework-heavy abstractions.

- `snake_case` for functions, variables, and module names
- `PascalCase` for classes
- keep config field names aligned with TOML keys where practical
- log actionable operational events; avoid noisy debug output by default

No formatter or linter is wired in yet, so keep style consistent with the existing files.

## Testing Guidelines

Tests use the standard library `unittest` framework. Add tests under `tests/` named `test_*.py`. Focus on config validation, message formatting, and protocol-safe behavior that can run without hardware.

Prefer unit tests for:

- channel key derivation
- CLI/config overrides
- alert message formatting
- error handling around MeshCore responses

## Commit & Pull Request Guidelines

This directory is not currently a git repository, so no local commit convention exists yet. When you initialize git, use short imperative commit subjects, for example:

- `Add AS3935 probe command`
- `Handle MeshCore retry on no_event_received`

For pull requests, include:

- a short summary of the change
- test results or command output
- any config changes
- hardware assumptions or limitations if sensor behavior is involved

## Security & Configuration Tips

Do not commit real private channel keys in `config.toml`. Treat MeshCore host, channel keys, and deployment-specific settings as secrets. Keep `config.example.toml` sanitized and use `verify-channel` before first field deployment.
