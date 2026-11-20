# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- **Pressure as its own axis**, kept apart from health. The query now also reads `power.draw`, `power.limit`, `utilization.memory` and `temperature.memory`, and a GPU's detail pane shows a separate `load` line under its own label. An alert raised by a threshold is prefixed `load:` so a busy card is never mistaken for a broken one.
- Per-host **VRAM** and **power** warning thresholds, alongside the existing temperature one. All three are optional and unset by default, because a threshold not tied to what the operator expects of that host is a guess. With none set, a card at 100% utilisation stays green.
- Warnings now carry their kind — `readability` (the driver did not answer something we asked) or `pressure` (an operator-declared threshold was crossed) — so the two can be presented, counted and alerted differently.

### Notes

- `temperature.memory` is unsupported on many cards, including every RTX 5090 tested. It stays `nil` and no line is drawn for it, rather than showing a dash for a reading that never existed.
- `clocks_throttle_reasons.active` is deliberately not queried: its bitmask meanings are not stable across driver versions.

## [1.0.0] — 2026-11-18

First release.

### The design rule this app is built on

SSH reachability, GPU query status and data freshness are three separate axes and are never collapsed into one verdict. A failed transport marks every GPU **unknown** — never missing and never healthy — and a card is only reported missing when a *complete* query positively lacked its baseline UUID. Counts carried forward from an earlier check are never counted as readable.

### Added

- Menu bar item showing confirmed/expected GPU count, with a warning glyph and an explicit unknown marker. It never reports healthy while any data is stale or any host is unaccounted for.
- Popover listing one row per host: SSH level, name, one dot per GPU, ratio, and the short reason when something is wrong. Rows expand to show the two axes separately, per-GPU index/UUID/model/temperature/utilization/VRAM, last-attempted and last-successful timestamps, and an explicit **last known** tag on values that are not current.
- Per-host actions: edit, test connection, register or remove a GPU baseline, enable/disable, delete — plus a context menu on the row.
- Pinnable floating panel that shares the app's single polling loop, with an always-on-top toggle.
- Add/edit host form with validation shared with the probe, and a staged **Test Connection** result (*SSH failed* / *SSH OK, no nvidia-smi* / *SSH OK, GPU query failed* / *success with N GPUs*).
- Baseline tracking by GPU UUID, with index used for display only.
- Bounded concurrent polling with a generation guard, so a result arriving after a host is edited or deleted is discarded. Editing the poll interval restarts the loop; opening more windows does not add a second one.
- Notifications with two-round confirmation, change-only delivery, cooldown, and recovery. Missing-GPU alerts are structurally impossible from a transport failure.
- Demo mode with a seven-host synthetic fleet: healthy, missing GPU, replaced card, unreachable host, no `nvidia-smi`, stale data, and a GPU over threshold. No network, no notifications.
- Atomic, schema-versioned storage. A file that cannot be read is never overwritten; it is preserved under a timestamped name and reported.
- Troubleshooting modes: `--diagnose`, `--check <user@host>`, `--show-popover`, `--show-settings`, `--show-editor`.

### Security

- Runs `/usr/bin/ssh` with an argument vector and no shell. Host, username, port and identity path are validated; a destination beginning with `-` is rejected.
- Host key verification is always on. The app never accepts a new key, never writes to `known_hosts`, and never sets `StrictHostKeyChecking=no`.
- No password, key, or key content is ever stored. No telemetry, no analytics.

### Known limitations

- NVIDIA physical GPUs only; MIG instances are not counted as additional GPUs and AMD is unsupported.
- Requires a POSIX remote login shell (`sh`, `bash`, `dash`, `zsh`).
- Notifications are unit tested but have not been observed end-to-end on a real machine.
- macOS 14 or later. Verified on macOS 27.2.1 on Apple Silicon only.
- The published build is **ad-hoc signed and not notarised**, so Gatekeeper will refuse a downloaded copy until the quarantine attribute is cleared. Building from source avoids this entirely.

[1.0.0]: https://github.com/Knoxpix/GPUWatch/releases/tag/v1.0.0
