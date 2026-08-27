# DayZ Server Manager for Linux

![](https://edge-prodberiffagroup.b-cdn.net/web/dayzservermanagerheadlinegifsmall-revisedyellow.gif)

Run a DayZ Standalone server on Linux without living in an SSH session. One
script installs the server, keeps it and its mods updated, backs it up, restarts
it when it crashes, and captures the diagnostics you need when it does. An
optional web GUI gives you all of it in a browser.

```sh
curl -fsSL https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/install.sh | bash
```

---

## What it does

- **Interactive setup** — `setup` asks a handful of questions and writes
  `config.ini`, `serverDZ.cfg` and `beserver_x64.cfg` for you.
- **Automatic installation** — SteamCMD and the server files, in one command.
- **Mods that actually download** — one SteamCMD call per mod with retries, so a
  large mod timing out no longer takes the whole batch down with it.
- **Cheap update checks** — `checkmods` asks the Steam API what changed and
  flags it; the download happens during your next restart, not while people are
  playing.
- **Crash diagnostics** — when the monitor finds a dead server it saves the RPT,
  memory and disk state, `journalctl`, `dmesg`, the console log and the exit
  code into a timestamped folder *before* restarting.
- **Backups** — the mission folder and server profile, with configurable
  retention.
- **RCon built in** — `rcon players` reads the port and password out of your
  BattlEye config, so credentials never go in your shell history or crontab.
- **systemd or cron** — `systemd` writes user units that survive reboots.
- **Web GUI** — optional, standard-library Python, no dependencies to install.

## Requirements

A Linux server, a **non-root user** to run it as, and a Steam account that
**owns DayZ** (mod downloads fail otherwise). `install.sh` handles the packages
for Debian/Ubuntu, Fedora/RHEL, Arch and openSUSE.

---

## Getting started

### 1. Create a user for the server

Never run a game server as root.

```sh
sudo adduser --disabled-password --gecos "" dayz
sudo su - dayz
```

### 2. Install

```sh
curl -fsSL https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/install.sh | bash
```

That installs the dependencies, downloads the manager, and offers to run setup.

<details>
<summary>Or install manually</summary>

```sh
cd ~
curl -fsSLO https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/dayzserver.sh
curl -fsSLO https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/dayzweb.py
mkdir -p webui && curl -fsSL -o webui/index.html \
  https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/webui/index.html
chmod +x dayzserver.sh
```
</details>

### 3. Configure, install, start

```sh
./dayzserver.sh setup      # asks for your Steam login, ports, server name, RCon password
./dayzserver.sh install    # downloads SteamCMD and the DayZ server files
./dayzserver.sh start
```

SteamCMD prompts for your Steam password and Steam Guard code the first time.
**Neither is ever stored in `config.ini`** — only your username is.

> **If mpmissions is empty:** SteamCMD occasionally skips the mission files.
> Create `serverfiles/mpmissions` and copy the mission from
> [DayZ Central Economy](https://github.com/BohemiaInteractive/DayZ-Central-Economy).

---

## Commands

| Command | Short | What it does |
|---|---|---|
| `setup` | | Interactive configuration. Start here. |
| `status` | `stat` | State, uptime, build, players, pending updates. `--json` for scripts. |
| `start` | `st` | Back up, apply pending updates, start the server. |
| `stop` | `sp` | Graceful shutdown, force-kill after 90s. |
| `restart` | `r` | Stop then start. |
| `monitor` | `m` | Restart if it crashed, capturing diagnostics first. For cron. |
| `console` | `c` | Attach to the live server console. |
| `install` | `i` | Install SteamCMD and the server files. |
| `update` | `u` | Check for and apply a server update. |
| `validate` | `v` | Verify the server files with SteamCMD. |
| `workshop` | `ws` | Download, update and link all mods. |
| `checkmods` | `chm` | Ask Steam what changed; flag it for the next start. |
| `updateconfig` | `uc` | Rebuild the `workshop=` launch line from `workshop.cfg`. |
| `mods add\|remove\|list` | | Manage mods by ID or workshop URL. |
| `players` | `p` | Current player count. |
| `rcon <command>` | `rc` | Send a BattlEye RCon command. |
| `backup` | `b` | Archive the mission folder and server profile. |
| `wipe` | `wi` | Wipe players and storage. |
| `cleancache` | `cc` | Clear SteamCMD caches (keeps your Steam login). |
| `cleanserver` | `cs` | Delete everything and start over (keeps your Steam login). |
| `web start\|stop\|status` | | Control the web GUI. |
| `systemd` | `sd` | Write systemd user units. |
| `version` | | Show the version. |

---

## Mods

Add mods by ID or by pasting the workshop URL:

```sh
./dayzserver.sh mods add 1559212036
./dayzserver.sh mods add "https://steamcommunity.com/sharedfiles/filedetails/?id=2545327648"
./dayzserver.sh workshop        # download and link them
./dayzserver.sh updateconfig    # rebuild the workshop= launch line
./dayzserver.sh mods list
```

`updateconfig` is the one that saves you: it builds the `workshop="@a;@b"` line
in `config.ini` from what is *actually installed*, so a mod you added but never
downloaded cannot produce a launch line the server rejects.

Mod names are resolved automatically and written back into `workshop.cfg`.
Symlinks are lowercased with spaces replaced by underscores, because a space in
a mod name corrupts the semicolon-separated `-mod=` list.

### Keeping mods current

Run `checkmods` on a schedule. It costs one API request, downloads nothing, and
leaves a flag that the next `start` acts on:

```sh
0 */2 * * * /home/dayz/dayzserver.sh checkmods > /dev/null 2>&1
```

Set `discord_webhook_url` in `config.ini` to be told when a mod changes.

---

## Web GUI

```sh
./dayzserver.sh web start
```

A password is generated and printed **once** on first run; only its
PBKDF2 hash is stored.

The GUI can start, stop and wipe your server, so it **binds `127.0.0.1` by
default**. Reach it from your desktop over an SSH tunnel:

```sh
ssh -L 8080:127.0.0.1:8080 dayz@your-server
# then open http://127.0.0.1:8080
```

To expose it on your network instead, set `web_bind=0.0.0.0` in `config.ini` —
and put it behind a reverse proxy with HTTPS. Plain HTTP over a network means
your password crosses it in the clear.

Tabs: dashboard with live status and one-click controls, server console with an
RCon box, mod manager, config editor for all three config files, log viewer, and
backups and crash reports.

Your Steam login, Discord webhook and password hash are replaced with
placeholders before `config.ini` is ever sent to the browser.

---

## Keeping it running

### systemd (recommended)

```sh
./dayzserver.sh systemd
systemctl --user daemon-reload
systemctl --user enable --now dayzserver.service
systemctl --user enable --now dayzserver-monitor.timer
systemctl --user enable --now dayzserver-checkmods.timer
systemctl --user enable --now dayzweb.service     # optional

sudo loginctl enable-linger dayz    # so it survives logout and starts at boot
```

`enable-linger` is not optional if you want the server up after you disconnect.

### Or cron

```sh
@reboot /home/dayz/dayzserver.sh start > /dev/null 2>&1
*/1 * * * * /home/dayz/dayzserver.sh monitor > /dev/null 2>&1
0 */2 * * * /home/dayz/dayzserver.sh checkmods > /dev/null 2>&1
# */30 * * * * /home/dayz/dayzserver.sh backup > /dev/null 2>&1
```

`monitor` restarts the server only if it crashed or was shut down remotely.
Stopping it yourself with `./dayzserver.sh stop` removes the lockfile, so the
monitor leaves it alone.

### Scheduled restarts

Use `messages.xml` in your mission DB folder, or RCon:

```sh
0 */3 * * * /home/dayz/dayzserver.sh rcon "#shutdown"
```

With the monitor or a systemd service in place, it comes straight back up,
applying any pending mod updates on the way.

---

## BattlEye RCon

`setup` configures RCon for you. To use it, install `bercon-cli` once:

```sh
sudo curl -L -o /usr/local/bin/bercon-cli \
  https://github.com/WoozyMasta/bercon-cli/releases/latest/download/bercon-cli-linux-amd64
sudo chmod +x /usr/local/bin/bercon-cli
```

Then:

```sh
./dayzserver.sh rcon players
./dayzserver.sh rcon "#shutdown"
```

The port and password are read from your BattlEye config, so they stay out of
your shell history and your crontab.

<details>
<summary>Configuring RCon by hand</summary>

Edit `serverfiles/battleye/beserver_x64.cfg`:

```
RConPassword your-strong-password
RConPort 2306
RestrictRCon 0
```

The RCon port must differ from the game port. After the first launch the server
generates `beserver_x64_active_*.cfg` and reads that instead — delete the
generated file after changing the password.

Check BattlEye opened the port with `ss -lun | grep 2306`.
</details>

---

## Files it creates

| Path | What it is |
|---|---|
| `config.ini` | Manager settings. Contains your Steam username — mode `600`. |
| `workshop.cfg` | One mod ID per line; names are filled in automatically. |
| `serverfiles/` | The DayZ server, mods and BattlEye config. |
| `serverprofile/` | Server logs, RPT files and crash dumps. |
| `backup/` | Mission and profile archives. |
| `crashlogs/` | One folder per crash, with everything needed to diagnose it. |
| `monitor.log` | Starts, crashes and automatic restarts. |
| `tmux.log` | The live server console. |
| `last_exit_code` | The server's exit code from its last run. |

---

## Troubleshooting

**A mod will not download.** Large mods time out on Steam's side. The script
already retries five times (`workshop_retries` in `config.ini`). If it still
fails, `./dayzserver.sh cleancache` then try again.

**SteamCMD reports a stale version.** `./dayzserver.sh cleancache` clears its
metadata cache without logging you out.

**The server starts, then immediately stops.** Check `cat ~/last_exit_code` and
`tail -n 50 ~/tmux.log`. A malformed `serverDZ.cfg` or a mod in `workshop=`
that is not installed are the usual culprits — run `updateconfig` to fix the
second.

**Clients get a version mismatch.** Your mods are out of date. Run
`./dayzserver.sh workshop` then `./dayzserver.sh updateconfig`.

**Nothing runs because of a missing library.** SteamCMD needs 32-bit gcc/glibc.
On Debian/Ubuntu: `sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install lib32gcc-s1`.

---

## Development

```sh
./tests/run_tests.sh
```

65 checks against a throwaway `$HOME` with stubbed SteamCMD, tmux and package
tooling — including regression tests for both reported mod-download bugs and the
web GUI's authentication, CSRF and secret-redaction behaviour. No DayZ licence
or Steam credentials required.

---

## Credits

Originally by [@fiskce](https://github.com/fiskce), with @tootlejack,
@thelastnoc and @haywardgg.

Significant improvements in this version come from
[@runtime-legend](https://github.com/runtime-legend)'s
[community fork](https://github.com/runtime-legend/DayZ-Server-Manager-Linux) —
the crash diagnostics, the workshop retry logic, Steam API update polling, and
launch-line generation all originated there. Thanks for the fork and for
reporting the download bug with a working patch attached.

## Contributing

Issues and pull requests are welcome. Please run `./tests/run_tests.sh` before
opening a PR, and add a test for anything you fix.

## Disclaimer

Use at your own risk. You are free to copy, modify and fork this, but please
keep the credits intact.
