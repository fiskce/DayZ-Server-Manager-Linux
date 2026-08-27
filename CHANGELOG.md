# Changelog

## v2.0.0

The manager still installs as a single script you drop in the server user's
home directory, and an existing `config.ini` keeps working unchanged — every
new setting falls back to a default when absent.

### Fixed

- **Only the last mod in `workshop.cfg` was downloaded** ([#1]). A file edited
  on Windows arrives with CRLF line endings, which made the `^[0-9]+$` mod-id
  check reject every line except the last. Lines are now stripped of carriage
  returns and surrounding whitespace before being parsed.
- **Large mods failed with a download timeout** ([#2]). Every mod was requested
  in a single SteamCMD call, so one slow mod (the DayZ-Expansion-Bundle in
  particular) took the whole batch with it. Each mod now gets its own call with
  up to five retries, and success requires both SteamCMD's success line *and*
  `meta.cpp` — an aborted download leaves partial content that folder checks
  cannot tell apart from a complete one.
- Mod names containing spaces produced symlinks with spaces in them, corrupting
  the semicolon-separated `-mod=` launch list. Spaces now become underscores.
- The `meta.cpp` name lookup matched any line containing "name", including
  `picture` and `title`. It is now anchored to a real `name =` field.
- A failed download overwrote the mod's name in `workshop.cfg` with `Unknown`,
  losing information the next run needed.
- Discord fired one webhook per mod on a fresh install; notifications now
  require a previous baseline, so only genuine updates are announced.
- Stale symlinks were left behind when a mod was renamed upstream.
- Mod BattlEye keys were never actually copied — mods are reached through
  symlinks, and `find` does not follow those without `-L`.
- Every successful command exited `1`, so cron and systemd recorded a failure
  on every run.
- The dependency check used `dpkg`, so it hard-failed on Arch and Fedora while
  printing instructions naming `pacman` and `dnf`. It now detects apt, dnf,
  yum, pacman and zypper, and warns rather than refusing to run on anything
  else. The 32-bit runtime is only required for commands that actually invoke
  SteamCMD or the server.
- `fn_backup_dayz` restarted a running server by calling `fn_start_dayz`, which
  calls `fn_backup_dayz` — a backup on a live server re-entered itself.
- `validate` read the server's status without refreshing it first, so a direct
  run behaved as though the server were running.
- `update` exited the entire script when Steam returned no version info,
  aborting a start over a transient hiccup.
- The mission folder was read with a positional `cut` on a line that is
  indented inside the `Missions` class, returning `=` instead of the name.
- `chmod u+x ${HOME}/dayzserver` referenced a path that has never existed.
- The workshop content path hardcoded `221100` instead of using `dayz_id`.
- `${HOME}` paths are quoted throughout, so a home directory containing a space
  no longer breaks `tar`, `find` and SteamCMD.

### Added

- `setup` — interactive first-run configuration writing `config.ini`,
  `serverDZ.cfg` and `beserver_x64.cfg` in one pass.
- `status` / `status --json` — state, uptime, build, player count, pending
  updates and last exit code.
- `players` — live player count over the Steam A2S protocol.
- `rcon` — BattlEye RCon reading the port and password from the server's own
  config, so credentials stay out of shell history and crontabs.
- `mods add|remove|list` — accepts a bare workshop ID or a full workshop URL.
- `checkmods` — polls the Steam API for mod updates and flags them for the next
  start without downloading anything.
- `updateconfig` — rebuilds the `workshop=` launch line from what is actually
  installed.
- `cleancache` and `cleanserver` — both preserve your Steam login.
- `systemd` — writes user units for the server, crash monitor, mod-update timer
  and web GUI.
- `web start|stop|status` and **`dayzweb.py`**, a standard-library web GUI:
  dashboard, live console, RCon, mod manager, config editor, log viewer and
  backups. Binds `127.0.0.1` with password login, CSRF protection, login rate
  limiting and a command allowlist; secrets are redacted before any config
  reaches the browser.
- Crash diagnostics: the RPT, system state, `journalctl`, `dmesg`, console log
  and exit code are captured into `~/crashlogs/<timestamp>/` before the monitor
  restarts a dead server.
- `~/monitor.log` lifecycle history, `~/tmux.log` console capture, and
  `~/last_exit_code`.
- `.mdmp` crash dumps are no longer deleted on start.
- New settings: `limitFPS`, `workshop_retries`, `backup_retention_days`,
  `auto_update_on_start`, `web_bind`, `web_port`.
- `install.sh` bootstrap installer with per-distribution dependency handling.
- `tests/run_tests.sh` — 65 checks with stubbed SteamCMD, tmux and package
  tooling, including regression tests for both bugs above.
- GitHub Actions CI running shellcheck and the test suite.

### Credits

Crash diagnostics, workshop retry logic, Steam API update polling and
launch-line generation were adapted from
[@runtime-legend](https://github.com/runtime-legend)'s
[community fork](https://github.com/runtime-legend/DayZ-Server-Manager-Linux).

[#1]: https://github.com/fiskce/DayZ-Server-Manager-Linux/issues/1
[#2]: https://github.com/fiskce/DayZ-Server-Manager-Linux/issues/2
