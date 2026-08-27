#!/bin/bash

#=======================================================================================#
#     Authors:  @fiskce / @tootlejack / @thelastnoc / @haywardgg
#     Contributors: @runtime-legend (community fork: crash diagnostics, workshop
#                   retry logic, Steam API update polling, config generation)
#=======================================================================================#
#
#                       DayZ Standalone Linux Server Manager
#
#=======================================================================================#

### NO NEED TO EDIT ANYTHING IN THIS FILE ###
### Changes should be made in config.ini ###

# ansi, steamlogin, dayzparameter and friends come from config.ini, which is
# sourced at runtime and so cannot be followed statically. The colour palette
# is kept complete even where a colour is not currently used.
# shellcheck disable=SC2154,SC2034

# A failure anywhere in a pipeline must fail the pipeline: several checks below
# read SteamCMD through a pipe, and without this a broken steamcmd.sh would look
# like a clean run.
set -o pipefail

SCRIPT_VERSION="2.0.0"

if [ "${ansi}" != "off" ]; then
        # echo colors
        default="\e[0m"
        red="\e[31m"
        green="\e[32m"
        yellow="\e[33m"
        lightyellow="\e[93m"
        blue="\e[34m"
        lightblue="\e[94m"
        magenta="\e[35m"
        cyan="\e[36m"
        # carriage return & erase to end of line
        creeol="\r\033[K"
fi

# Define the config file path
CONFIG_FILE="config.ini"

# Default content of the config.ini file
DEFAULT_CONFIG="
# DayZ SteamID
appid=223350
dayz_id=221100
#stable=223350
#exp_branch=1042420

# Game Port (Not Steam QueryPort. Add/Change that in your serverDZ.cfg file)
port=2301

# Limit the server frame rate. Lower values reduce CPU load.
limitFPS=60

# How many times to retry a single Steam Workshop mod download before giving
# up. Large mods (the DayZ-Expansion-Bundle in particular) regularly time out
# on the first attempt.
workshop_retries=5

# How many days of backups to keep before they are deleted.
backup_retention_days=2

# Check for and apply DayZ server updates every time the server starts.
# Set to 0 if you would rather update only via the 'update' command or cron.
auto_update_on_start=1

# Web GUI. Bind to 127.0.0.1 to keep it reachable only from this machine
# (recommended - use an SSH tunnel or a reverse proxy with HTTPS to reach it
# remotely). Set to 0.0.0.0 to expose it on the network.
web_bind=127.0.0.1
web_port=8080

# IMPORTANT PARAMETERS
steamlogin=CHANGEME
config=serverDZ.cfg
BEpath=\"-BEpath=\${HOME}/serverfiles/battleye/\"
profiles=\"-profiles=\${HOME}/serverprofile/\"
# optional - just remove the # to enable
#logs=\"-dologs -adminlog -netlog\"

# Discord Notifications.
discord_webhook_url=\"\"

# DayZ Mods from Steam Workshop
# Edit the workshop.cfg and add one Mod Number per line.
# To enable mods, remove the # below and list the Mods like this: \"@mod1;@mod2;@spaces work\". Lowercase only.
#workshop=\"\"
# To enable serverside mods, remove the # below and list the Mods like this: \"@servermod1;@server mod2\". Lowercase only.
#servermods=\"\"

# modify carefully! server won't start if syntax is corrupt!
dayzparameter=\" -config=\${config} -port=\${port} -limitFPS=\${limitFPS} -freezecheck \${BEpath} \${profiles} \${logs}\""

# Work out which command was asked for before anything else runs.
#
# Some commands must work in states where config.ini is absent, incomplete or
# points at a server that was never installed: `setup` is what creates a valid
# config in the first place, `cleanserver` only deletes files, and `version`
# and `help` answer without touching the server at all. Those skip the setup
# gates below and the auto-install gate further down.
getopt="$1"
case "${getopt}" in
    cs|cleanserver|setup|version|--version|-v|help|--help|-h) maintenance_mode=1 ;;
    *)                                                       maintenance_mode=0 ;;
esac

if [ "${maintenance_mode}" != "1" ]; then
    # Check if the config.ini file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "[ ${yellow}Warning${default} ] ${CONFIG_FILE} file not found.\n"
        echo -e "$DEFAULT_CONFIG" > "$CONFIG_FILE"
        printf "[ ${green}Fixed${default} ] Default ${lightyellow}${CONFIG_FILE}${default} created.\n"
        printf "[ ${lightblue}TIP${default} ] Run '${lightyellow}$0 setup${default}' to fill it in interactively.\n"
        chmod 600 "$CONFIG_FILE"
        exit 1
    else
        printf "[ ${green}Success${default} ] Config file found. Reading values...\n"
        # Source the config file to load its variables
        source "$CONFIG_FILE"
        printf "[ ${green}Finished${default} ] Configuration file loaded.\n"
        chmod 600 "$CONFIG_FILE"
    fi

    # Check if steamlogin is set to CHANGEME
    if [ "$steamlogin" = "CHANGEME" ]; then
        printf "[ ${red}Error${default} ] The ${lightyellow}steamlogin${default} value in ${CONFIG_FILE} is still '${lightyellow}CHANGEME${default}'.\n"
        printf "[ ${red}Error${default} ] Set it to your Steam username, or run '${lightyellow}$0 setup${default}'.\n"
        exit 1
    fi
fi

# Fall back to sane values for settings added after a user wrote their
# config.ini. Upgrading the script must never require rewriting the config, so
# every option introduced in a later version gets its default here.
: "${appid:=223350}"
: "${dayz_id:=221100}"
: "${port:=2301}"
: "${limitFPS:=60}"
: "${workshop_retries:=5}"
: "${backup_retention_days:=2}"
: "${auto_update_on_start:=1}"
: "${web_bind:=127.0.0.1}"
: "${web_port:=8080}"
: "${discord_webhook_url:=}"
: "${workshop:=}"
: "${servermods:=}"
: "${config:=serverDZ.cfg}"

# ---------------------------------------------------------------------------
# fn_checkroot_dayz
# Running the server as root leaves root-owned files all over the install and
# gives a game server far more privilege than it needs, so this is refused.
#
# DAYZ_ALLOW_ROOT=1 overrides the check. It exists for containers and CI, where
# there is no other user to switch to; it is not a supported way to run a real
# server.
# ---------------------------------------------------------------------------
fn_checkroot_dayz(){
	if [ "$(id -u)" -eq 0 ]; then
		if [ "${DAYZ_ALLOW_ROOT:-0}" = "1" ]; then
			printf "[ ${yellow}WARN${default} ] Running as root because DAYZ_ALLOW_ROOT=1 is set.\n"
			return 0
		fi
		printf "[ ${red}FAIL${default} ] ${yellow}Do NOT run this script as root!\n"
		printf "\tSwitch to the dayz user, or set DAYZ_ALLOW_ROOT=1 if you are in a container.${default}\n"
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# fn_detect_pkg_manager
# Sets pkg_manager and pkg_install_cmd for the running distribution. The old
# check assumed dpkg, so the dependency check hard-failed on Arch and Fedora
# even though the instructions it printed named pacman and dnf.
# ---------------------------------------------------------------------------
fn_detect_pkg_manager(){
	if command -v apt-get &>/dev/null; then
		pkg_manager="apt"; pkg_install_cmd="sudo apt install -y"
	elif command -v dnf &>/dev/null; then
		pkg_manager="dnf"; pkg_install_cmd="sudo dnf install -y"
	elif command -v yum &>/dev/null; then
		pkg_manager="yum"; pkg_install_cmd="sudo yum install -y"
	elif command -v pacman &>/dev/null; then
		pkg_manager="pacman"; pkg_install_cmd="sudo pacman -S --needed"
	elif command -v zypper &>/dev/null; then
		pkg_manager="zypper"; pkg_install_cmd="sudo zypper install -y"
	else
		pkg_manager="unknown"; pkg_install_cmd=""
	fi
}

# ---------------------------------------------------------------------------
# fn_pkg_name
# Maps a logical dependency to this distribution's package name.
# ---------------------------------------------------------------------------
fn_pkg_name(){
	case "$1:${pkg_manager}" in
		lib32gcc:apt)     echo "lib32gcc-s1" ;;
		lib32gcc:dnf)     echo "glibc.i686 libstdc++.i686" ;;
		lib32gcc:yum)     echo "glibc.i686 libstdc++.i686" ;;
		lib32gcc:pacman)  echo "lib32-gcc-libs" ;;
		lib32gcc:zypper)  echo "glibc-32bit libstdc++6-32bit" ;;
		lib32gcc:*)       echo "lib32gcc" ;;
		*)                echo "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# fn_have_lib32
# Best-effort check for the 32-bit runtime SteamCMD needs. Each package manager
# is queried in its own language; an unrecognised distribution is reported as a
# warning rather than a hard failure, because refusing to run on a system we
# simply cannot introspect is worse than letting SteamCMD speak for itself.
# ---------------------------------------------------------------------------
fn_have_lib32(){
	case "${pkg_manager}" in
		apt)    [[ "$(dpkg-query -W -f='${Status}' lib32gcc-s1 2>/dev/null)" == *"ok installed"* ]] ;;
		dnf|yum) rpm -q glibc.i686 &>/dev/null ;;
		pacman) pacman -Qq lib32-gcc-libs &>/dev/null ;;
		zypper) rpm -q glibc-32bit &>/dev/null ;;
		*)      return 2 ;;
	esac
}

# ---------------------------------------------------------------------------
# check_dependencies
# Verifies the tools this run actually needs.
#
# The 32-bit runtime is only required to execute SteamCMD and the server
# binary, so it is checked only for the commands that do that. Refusing to
# print `status` because a library the command never touches is missing is
# just an obstacle.
# ---------------------------------------------------------------------------
check_dependencies(){
	local missing_tools=()
	local tools=("tmux" "curl" "jq" "wget" "tar" "awk" "sed")
	local tool lib32_status needs_runtime=0

	case "${getopt}" in
		i|install|st|start|r|restart|u|update|v|validate|ws|workshop|m|monitor)
			needs_runtime=1 ;;
	esac

	fn_detect_pkg_manager

	for tool in "${tools[@]}"; do
		if ! command -v "$tool" &>/dev/null; then
			missing_tools+=("$(fn_pkg_name "$tool")")
		fi
	done

	if [ "${needs_runtime}" = "0" ]; then
		if [ "${#missing_tools[@]}" -ne 0 ]; then
			printf "[ ${red}ERROR${default} ] Missing dependencies: ${yellow}%s${default}\n" "${missing_tools[*]}"
			exit 1
		fi
		return 0
	fi

	fn_have_lib32
	lib32_status=$?
	if [ "${lib32_status}" -eq 1 ]; then
		missing_tools+=("$(fn_pkg_name lib32gcc)")
	elif [ "${lib32_status}" -eq 2 ]; then
		printf "[ ${yellow}WARN${default} ] Unrecognised package manager; cannot verify the 32-bit runtime.\n"
		printf "\tSteamCMD needs 32-bit gcc/glibc libraries. Install them if it fails to start.\n"
	fi

	if [ "${#missing_tools[@]}" -ne 0 ]; then
		printf "[ ${red}ERROR${default} ] Missing dependencies: ${yellow}%s${default}\n" "${missing_tools[*]}"
		if [ -n "${pkg_install_cmd}" ]; then
			printf "[ ${lightblue}INFO${default} ] Install them with:\n\n\t%s %s\n\n" \
				"${pkg_install_cmd}" "${missing_tools[*]}"
		else
			printf "[ ${lightblue}INFO${default} ] Install them with your distribution's package manager.\n"
		fi
		exit 1
	fi

	printf "[ ${green}OK${default} ] All required tools are installed.\n"
}

fn_checkscreen(){
	if [ -n "${STY}" ]; then
		printf "[ ${red}FAIL${default} ] The Script creates a tmux session when starting the server.\n"
		printf "\tIt is not possible to run a tmux session inside screen session\n"
		exit 1
	fi
}

fn_status_dayz(){
	dayzstatus=$(tmux list-sessions -F "$(whoami)-tmux" 2> /dev/null | grep -Ecx "$(whoami)-tmux")
}

# ---------------------------------------------------------------------------
# fn_clear_logs
# Removes stale .RPT and .log files before a start so the next session's logs
# are easy to find.
#
# .mdmp files are deliberately kept. They are the engine's crash minidumps and
# the single most useful artefact when diagnosing why a server died; the old
# code deleted them on every start, destroying the evidence before anyone
# could look at it.
# ---------------------------------------------------------------------------
fn_clear_logs(){
	local profiles_dir="${HOME}/serverprofile"
	if [ -d "${profiles_dir}" ]; then
		find "${profiles_dir}" -type f \( -name "*.RPT" -o -name "*.log" \) -delete
		printf "[ ${green}DayZ${default} ] Cleared old .RPT and .log files (crash dumps kept).\n"
	fi
}

# ---------------------------------------------------------------------------
# fn_log_monitor
# Appends a timestamped line to ~/monitor.log, giving a readable history of
# starts, crashes and automatic restarts.
# ---------------------------------------------------------------------------
fn_log_monitor(){
	{
		printf '%s ' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '%b\n' "$1"
	} >> "${HOME}/monitor.log"
}

# ---------------------------------------------------------------------------
# fn_write_launch_wrapper
# Writes the small script tmux actually runs. Launching through a wrapper lets
# us record the server's exit code to ~/last_exit_code, which is otherwise lost
# when the tmux session disappears - and that code is usually the first clue
# about why a server died.
#
# The heredoc is intentionally unquoted so the launch parameters are expanded
# now, producing the exact same command line as a direct invocation. Only "$?"
# is escaped, so it is evaluated by the wrapper after the server exits.
# ---------------------------------------------------------------------------
fn_write_launch_wrapper(){
	local wrapper="${HOME}/.dayz_launch_wrapper.sh"
	cat > "${wrapper}" <<EOF
#!/bin/bash
# Auto-generated by dayzserver.sh - do not edit; it is rewritten on every start.
cd "${HOME}/serverfiles" || exit 1
./DayZServer ${dayzparameter} -mod="${workshop}" -servermod="${servermods}"
echo \$? > "${HOME}/last_exit_code"
EOF
	chmod +x "${wrapper}"
}

# ---------------------------------------------------------------------------
# fn_collect_crashlogs
# Snapshots everything useful about a crash into ~/crashlogs/<timestamp>/.
# Called by the monitor before the automatic restart, because a restart
# truncates the console log and overwrites the RPT.
# ---------------------------------------------------------------------------
fn_collect_crashlogs(){
	local crash_dir latest_rpt
	crash_dir="${HOME}/crashlogs/$(date +%Y-%m-%d_%H-%M-%S)"
	mkdir -p "${crash_dir}"
	printf "[ ${yellow}DayZ${default} ] Collecting crash diagnostics into %s\n" "${crash_dir}"

	# Most recent RPT: full copy plus a short tail that is quick to skim.
	latest_rpt="$(find "${HOME}/serverprofile" -type f -name '*.RPT' -printf '%T@ %p\n' 2>/dev/null \
		| sort -nr | head -n1 | cut -d' ' -f2-)"
	if [ -n "${latest_rpt}" ] && [ -f "${latest_rpt}" ]; then
		cp -f "${latest_rpt}" "${crash_dir}/DayZServer.rpt"
		tail -n 500 "${latest_rpt}" > "${crash_dir}/DayZServer_last500.log"
	else
		echo "No .RPT file found in ${HOME}/serverprofile" > "${crash_dir}/DayZServer_last500.log"
	fi

	# Machine state at the time of the crash - an out-of-memory kill or a full
	# disk shows up here and nowhere else.
	{
		echo "===== free -h ====="; free -h 2>&1
		echo; echo "===== ps aux --sort=-rss (top 30) ====="; ps aux --sort=-rss 2>&1 | head -n 31
		echo; echo "===== df -h ====="; df -h 2>&1
	} > "${crash_dir}/system_state.log" 2>&1

	# Neither of these is guaranteed to be readable by an unprivileged user, so
	# a failure here must never abort the restart.
	journalctl --since "10 minutes ago" > "${crash_dir}/journal.log" 2>&1 \
		|| echo "journalctl unavailable or insufficient permissions" > "${crash_dir}/journal.log"
	dmesg -T > "${crash_dir}/dmesg.log" 2>&1 \
		|| echo "dmesg unavailable or insufficient permissions" > "${crash_dir}/dmesg.log"

	[ -f "${HOME}/tmux.log" ] && cp -f "${HOME}/tmux.log" "${crash_dir}/tmux.log"
	[ -f "${HOME}/last_exit_code" ] && cp -f "${HOME}/last_exit_code" "${crash_dir}/last_exit_code"

	printf "[ ${green}DayZ${default} ] Crash diagnostics saved.\n"
}

fn_start_dayz(){
	local -a refreshed_ids=()
	fn_status_dayz
	if [ "${dayzstatus}" == "1" ]; then
		printf "[ ${yellow}DayZ${default} ] Server already running.\n"
		return 0
	fi

	fn_backup_dayz

	# The README has always promised the server updates itself on restart, so
	# this stays on by default. fn_update_dayz sees a stopped server here and
	# takes its non-restarting branch, so there is no recursion back into start.
	if [ "${auto_update_on_start}" = "1" ]; then
		fn_update_dayz
	fi

	# A `checkmods` run (usually on a cron) leaves this flag when the workshop
	# has newer versions than we hold. Applying them here means downloads happen
	# during the restart window rather than while players are connected.
	if [ -f "${HOME}/update_pending" ]; then
		printf "[ ${yellow}DayZ${default} ] Pending mod updates found; applying before start...\n"
		if fn_workshop_mods; then
			rm -f "${HOME}/update_pending"
			mapfile -t refreshed_ids < <(fn_read_workshop_ids)
			[ "${#refreshed_ids[@]}" -gt 0 ] && fn_refresh_remote_timestamps "${refreshed_ids[@]}"
			printf "[ ${green}DayZ${default} ] Mod updates applied.\n"
		else
			printf "[ ${yellow}WARN${default} ] Some mods failed to update; flag kept for the next start.\n"
		fi
	fi

	fn_clear_logs
	printf "[ ${green}DayZ${default} ] Starting server...\n"

	fn_write_launch_wrapper
	# Start this session's console log fresh. It is archived into the crash
	# directory before every automatic restart, so truncating here is safe and
	# stops the file growing without bound.
	: > "${HOME}/tmux.log"
	tmux new-session -d -x 23 -y 80 -s "$(whoami)-tmux" "${HOME}/.dayz_launch_wrapper.sh"
	sleep 1
	tmux pipe-pane -t "$(whoami)-tmux" -o "cat >> ${HOME}/tmux.log" 2>/dev/null

	date > "${HOME}/.dayzlockfile"

	fn_status_dayz
	if [ "${dayzstatus}" == "1" ]; then
		printf "[ ${green}OK${default} ] Server started.\n"
		fn_log_monitor "Server started successfully."
		return 0
	fi
	printf "[ ${red}FAIL${default} ] Server did not start. Check %s\n" "${HOME}/tmux.log"
	fn_log_monitor "Server start FAILED (no tmux session after launch)."
	return 1
}

fn_stop_dayz(){
	fn_status_dayz
	if [ "${dayzstatus}" == "1" ]; then
		printf "[ ${magenta}...${default} ] Stopping Server graceful."
		# waits up to 90 seconds giving the server time to shutdown gracefuly
		for seconds in {1..90}; do
			fn_status_dayz
			if [ "${dayzstatus}" == "0" ]; then
				printf "\r[ ${green}OK${default} ] Stopping Server graceful.\n"
				rm -f ${HOME}/.dayzlockfile
				break
			fi
			printf "\r[ ${magenta}...${default} ] Stopping Server graceful: ${seconds} seconds"
			tmux send-keys C-c -t "$(whoami)-tmux" > /dev/null 2>&1
			sleep 1
		done
		fn_status_dayz
		if [ "${dayzstatus}" != "0" ]; then
			printf "\n[ ${red}FAIL${default} ] Stopping Server graceful failed. Stop Signal.\n"
			sleep 2
			rm -f ${HOME}/.dayzlockfile
			tmux kill-session -t "$(whoami)-tmux"
			#killall -u $(whoami)
		fi
	else
		printf "[ ${yellow}DayZ${default} ] Server not running.\n"
	fi
}

fn_restart_dayz(){
	fn_stop_dayz
	sleep 1
	fn_start_dayz
}

# ---------------------------------------------------------------------------
# fn_monitor_dayz
# Intended to run every minute from cron or a systemd timer. The lockfile marks
# "the server is supposed to be running"; if it exists but no tmux session
# does, the server died rather than being stopped on purpose.
# ---------------------------------------------------------------------------
fn_monitor_dayz(){
	if [ -f "${HOME}/.dayzlockupdate" ]; then
		printf "[ ${yellow}INFO${default} ] Server files are being updated; skipping this check.\n"
		return 0
	fi

	fn_status_dayz
	if [ "${dayzstatus}" == "0" ] && [ -f "${HOME}/.dayzlockfile" ]; then
		# Gather diagnostics BEFORE restarting - the restart truncates tmux.log
		# and the server overwrites its RPT.
		fn_log_monitor "Server crashed. Restart initiated."
		fn_collect_crashlogs
		fn_discord_notify "DayZ server crashed; restarting automatically."
		fn_restart_dayz
	elif [ "${dayzstatus}" != "0" ] && [ -f "${HOME}/.dayzlockfile" ]; then
		printf "[ ${lightblue}INFO${default} ] Server is online.\n"
	else
		printf "[ ${yellow}INFO${default} ] Server is stopped on purpose. Use '%s start' to start it.\n" "$0"
	fi
	return 0
}

fn_console_dayz(){
	printf "[${yellow} Warning ${default}] Press \"CTRL+b\" then \"d\" to exit console.\n    Do NOT press CTRL+c to exit.\n\n"
	sleep 0.1
	while true; do
                read -e -i "Y" -p "Continue? [Y/n] " -r answer
                case "${answer}" in
                        [Yy]|[Yy][Ee][Ss]) tmux a -t "$(whoami)-tmux"
                                           return 0;;
                        [Nn]|[Nn][Oo]) return 1 ;;
                *) echo "Please answer yes or no." ;;
                esac
        done
}


fn_install_dayz(){
	if [ ! -f "${HOME}/steamcmd/steamcmd.sh" ]; then
		mkdir ${HOME}/steamcmd &> /dev/null
		curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxf - -C steamcmd
		printf "[ ${yellow}STEAM${default} ] Steamcmd installed\n"
	else
		printf "[ ${lightblue}STEAM${default} ] Steamcmd already installed\n"
	fi
	if [ ! -f "${HOME}/serverfiles/DayZServer" ]; then
		mkdir ${HOME}/serverfiles &> /dev/null
		mkdir ${HOME}/serverprofile &> /dev/null
		printf "[ ${yellow}DayZ${default} ] Downloading DayZ Server-Files!\n"
		fn_runvalidate_dayz
		if [ ! -f "${HOME}/serverfiles/${config}" ]; then
			printf "\n[ ${lightblue}TIP${default} ] Run '${lightyellow}%s setup${default}' now to write %s and configure RCon.\n\n" \
				"$0" "${config}"
		fi
	else
		printf "[ ${lightblue}DayZ${default} ] The Server is already installed.\n"
		fn_opt_usage 0
	fi
}

fn_runupdate_dayz(){
	"${HOME}/steamcmd/steamcmd.sh" +force_install_dir "${HOME}/serverfiles" \
		+login "${steamlogin}" +app_update "${appid}" +quit
}

# ---------------------------------------------------------------------------
# fn_update_dayz
# Compares the installed build id against the one Steam advertises and applies
# an update when they differ.
#
# Called both directly and from fn_start_dayz. It therefore returns instead of
# exiting when the version lookup fails: a transient Steam hiccup should skip
# the update check, not abort a server start.
# ---------------------------------------------------------------------------
fn_update_dayz(){
	local appmanifestfile="${HOME}/serverfiles/steamapps/appmanifest_${appid}.acf"
	local currentbuild availablebuild

	printf "[ ... ] Checking for update: SteamCMD"

	if [ -f "${appmanifestfile}" ]; then
		currentbuild="$(grep buildid "${appmanifestfile}" | tr '[:blank:]"' ' ' | tr -s ' ' | cut -d ' ' -f3)"
	fi

	# SteamCMD caches app metadata and will happily report a stale version;
	# removing appinfo.vdf forces it to re-fetch.
	if [ -f "${HOME}/Steam/appcache/appinfo.vdf" ]; then
		rm -f "${HOME}/Steam/appcache/appinfo.vdf"
		sleep 1
	fi

	availablebuild="$("${HOME}/steamcmd/steamcmd.sh" +login "${steamlogin}" +app_info_update 1 \
		+app_info_print "${appid}" +app_info_print "${appid}" +quit \
		| sed -n '/branch/,$p' | grep -m 1 buildid | tr -cd '[:digit:]')"

	if [ -z "${availablebuild}" ]; then
		printf "\r[ ${red}FAIL${default} ] Checking for update: SteamCMD returned no version info.\n"
		printf "[ ${lightblue}TIP${default} ] Try '%s cleancache' if this keeps happening.\n" "$0"
		return 1
	fi
	printf "\r[ ${green}OK${default} ] Checking for update: SteamCMD\n"

	if [ "${currentbuild}" = "${availablebuild}" ]; then
		printf "[ ${green}OK${default} ] No update available (build ${green}%s${default}).\n" "${currentbuild}"
		return 0
	fi

	printf "[ ${green}OK${default} ] Update available.\n"
	printf "\tCurrent build:   ${red}%s${default}\n" "${currentbuild:-unknown}"
	printf "\tAvailable build: ${green}%s${default}\n" "${availablebuild}"
	printf "\thttps://steamdb.info/app/%s/\n\n" "${appid}"

	# The lockfile stops the monitor restarting the server mid-update.
	date > "${HOME}/.dayzlockupdate"
	fn_log_monitor "Server update ${currentbuild:-unknown} -> ${availablebuild} starting."

	fn_status_dayz
	local was_running=0
	if [ "${dayzstatus}" != "0" ]; then
		was_running=1
		fn_stop_dayz
	fi

	fn_runupdate_dayz
	fn_workshop_mods
	rm -f "${HOME}/.dayzlockupdate"
	fn_log_monitor "Server updated to build ${availablebuild}."
	fn_discord_notify "DayZ server updated to build ${availablebuild}."

	if [ "${was_running}" = "1" ]; then
		fn_start_dayz
	fi
	return 0
}

fn_runvalidate_dayz(){
	"${HOME}/steamcmd/steamcmd.sh" +force_install_dir "${HOME}/serverfiles" \
		+login "${steamlogin}" +app_update "${appid}" validate +quit
}

fn_validate_dayz(){
	# The old version read ${dayzstatus} without refreshing it first, so on a
	# direct `validate` the variable was unset and it took the "server running"
	# branch against a stopped server.
	fn_status_dayz
	if [ "${dayzstatus}" == "0" ]; then
		fn_runvalidate_dayz
		return $?
	fi

	date > "${HOME}/.dayzlockupdate"
	fn_stop_dayz
	fn_runvalidate_dayz
	fn_workshop_mods
	rm -f "${HOME}/.dayzlockupdate"
	fn_start_dayz
}

# ---------------------------------------------------------------------------
# fn_trim
# Normalises one line of user-editable config: strips carriage returns (files
# edited on Windows arrive as CRLF) and surrounding whitespace. Without the \r
# strip, the "^[0-9]+$" mod-id test below rejects every line except the last
# one in the file - the cause of issue #1.
# ---------------------------------------------------------------------------
fn_trim(){
	printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# fn_read_workshop_ids
# Prints one valid mod id per line from workshop.cfg. Shared by every command
# that needs the mod list (workshop, checkmods, updateconfig, mods list).
# ---------------------------------------------------------------------------
fn_read_workshop_ids(){
	local workshop_cfg="${HOME}/workshop.cfg"
	local line mod_id
	[ -f "${workshop_cfg}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) continue ;; esac
		mod_id="$(printf '%s' "${line}" | awk '{print $1}')"
		[[ "${mod_id}" =~ ^[0-9]+$ ]] && printf '%s\n' "${mod_id}"
	done < "${workshop_cfg}"
}

# ---------------------------------------------------------------------------
# fn_mod_link_name
# Turns a mod's display name into the folder name DayZ expects after the "@".
# Lowercased, and spaces become underscores - a space left in the name breaks
# the semicolon-separated -mod= list the server is launched with.
# ---------------------------------------------------------------------------
fn_mod_link_name(){
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_'
}

# ---------------------------------------------------------------------------
# fn_workshop_mods
# Downloads every mod listed in workshop.cfg, links it into serverfiles/ and
# copies its BattlEye keys.
#
# Each mod is downloaded in its own SteamCMD call rather than as one batched
# invocation. Batching meant a single slow mod (the DayZ-Expansion-Bundle is
# the usual culprit) timed out the whole run and left every other mod
# untouched - issue #2. Per-mod calls also let us retry just the mod that
# failed.
#
# A mod counts as downloaded only when SteamCMD prints its success line AND
# meta.cpp exists. Checking for a non-empty folder is not enough: an aborted
# download leaves partial content behind that looks identical to a good one.
# ---------------------------------------------------------------------------
fn_workshop_mods(){
	local workshop_cfg="${HOME}/workshop.cfg"
	local workshopfolder="${HOME}/serverfiles/steamapps/workshop/content/${dayz_id}"
	local timestamp_file="${HOME}/mod_timestamps.json"
	local -a workshopID=()
	local updated_workshop_cfg=""
	local failed=0

	if [ ! -f "${workshop_cfg}" ]; then
		touch "${workshop_cfg}"
		chmod 600 "${workshop_cfg}"
	fi
	[ -f "${timestamp_file}" ] || echo "{}" > "${timestamp_file}"

	mapfile -t workshopID < "${workshop_cfg}"
	if [ "${#workshopID[@]}" -eq 0 ]; then
		printf "[ ${lightblue}INFO${default} ] No mods listed in workshop.cfg; nothing to download.\n"
		return 0
	fi

	printf "[ ${green}DayZ${default} ] Downloading Steam Workshop mods...\n"

	local line mod_id name_from_cfg meta_file steamcmd_log
	local success attempt resolved_name link_name desired_link stale
	local mod_last_modified prev_timestamp

	for line in "${workshopID[@]}"; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) updated_workshop_cfg+="${line}"$'\n'; continue ;; esac

		mod_id="$(printf '%s' "${line}" | awk '{print $1}')"
		if [[ ! "${mod_id}" =~ ^[0-9]+$ ]]; then
			printf "[ ${yellow}WARN${default} ] Skipping unparsable workshop.cfg line: %s\n" "${line}"
			continue
		fi

		# "cut -f2-" returns the whole field when the line is just an id, so an
		# id-only line would otherwise look like it already carries a name.
		name_from_cfg="$(fn_trim "$(printf '%s' "${line}" | cut -d' ' -f2-)")"
		[ "${name_from_cfg}" = "${mod_id}" ] && name_from_cfg=""

		meta_file="${workshopfolder}/${mod_id}/meta.cpp"
		steamcmd_log="$(mktemp -t dayz-steamcmd.XXXXXX.log 2>/dev/null)" || steamcmd_log="${HOME}/.steamcmd_last.log"

		success=0
		for attempt in $(seq 1 "${workshop_retries}"); do
			printf "[ ${lightblue}INFO${default} ] Downloading mod ${cyan}%s${default} (attempt %s/%s)\n" \
				"${mod_id}" "${attempt}" "${workshop_retries}"

			: > "${steamcmd_log}"
			"${HOME}/steamcmd/steamcmd.sh" \
				+force_install_dir "${HOME}/serverfiles" \
				+login "${steamlogin}" \
				+workshop_download_item "${dayz_id}" "${mod_id}" validate \
				+quit 2>&1 | tee "${steamcmd_log}"

			if grep -q "Success. Downloaded item ${mod_id}" "${steamcmd_log}" && [ -f "${meta_file}" ]; then
				printf "[ ${green}OK${default} ] Mod ${cyan}%s${default} downloaded.\n" "${mod_id}"
				success=1
				break
			fi

			if grep -q "Timeout downloading item ${mod_id}" "${steamcmd_log}"; then
				printf "[ ${yellow}WARN${default} ] SteamCMD timed out on mod %s.\n" "${mod_id}"
			elif grep -qE "ERROR!.*${mod_id}" "${steamcmd_log}"; then
				printf "[ ${yellow}WARN${default} ] SteamCMD reported an error for mod %s.\n" "${mod_id}"
			else
				printf "[ ${yellow}WARN${default} ] Download of mod %s incomplete (no meta.cpp).\n" "${mod_id}"
			fi
			[ "${attempt}" -lt "${workshop_retries}" ] && sleep $(( attempt * 5 ))
		done
		rm -f "${steamcmd_log}"

		if [ "${success}" -ne 1 ]; then
			printf "[ ${red}FAIL${default} ] Mod %s could not be downloaded after %s attempts.\n" \
				"${mod_id}" "${workshop_retries}"
			failed=$(( failed + 1 ))
			# Keep the line exactly as it was: overwriting a good name with
			# "Unknown" would lose information the next run needs.
			updated_workshop_cfg+="${mod_id}${name_from_cfg:+ }${name_from_cfg}"$'\n'
			continue
		fi

		# Name priority: meta.cpp, then whatever workshop.cfg already had, then
		# the bare id. The grep is anchored to a real `name = "..."` field so it
		# cannot match `picture`, `logo` or a `name` substring elsewhere.
		resolved_name=""
		if [ -f "${meta_file}" ]; then
			resolved_name="$(grep -E '^[[:space:]]*name[[:space:]]*=' "${meta_file}" | head -n1 | cut -d '"' -f2)"
		fi
		[ -z "${resolved_name}" ] && resolved_name="${name_from_cfg}"
		if [ -z "${resolved_name}" ]; then
			resolved_name="${mod_id}"
			printf "[ ${yellow}WARN${default} ] No name found for mod %s; using its id.\n" "${mod_id}"
		fi

		link_name="$(fn_mod_link_name "${resolved_name}")"
		desired_link="${HOME}/serverfiles/@${link_name}"

		# Drop symlinks that point at this mod under a different name - left
		# behind when a mod author renames a mod, or by an earlier run that
		# could not read meta.cpp.
		for stale in "${HOME}/serverfiles/@"*; do
			[ -L "${stale}" ] || continue
			[ "$(readlink "${stale}")" = "${workshopfolder}/${mod_id}" ] || continue
			if [ "${stale}" != "${desired_link}" ]; then
				printf "[ ${lightblue}INFO${default} ] Removing stale symlink %s\n" "$(basename "${stale}")"
				rm -f "${stale}"
			fi
		done

		if [ ! -e "${desired_link}" ]; then
			ln -s "${workshopfolder}/${mod_id}" "${desired_link}"
			printf "[ ${green}OK${default} ] Linked ${cyan}@%s${default}\n" "${link_name}"
		fi

		# Update detection, and a Discord ping when a mod actually changed.
		if [ -f "${meta_file}" ]; then
			mod_last_modified="$(date -r "${meta_file}" +%s 2>/dev/null || echo 0)"
			prev_timestamp="$(jq -r --arg mod "${mod_id}" '.[$mod] // 0' "${timestamp_file}" 2>/dev/null || echo 0)"

			# prev_timestamp of 0 means we have never seen this mod, so this is
			# a first install rather than an update - staying quiet here avoids
			# one webhook per mod on a fresh server.
			if [ "${mod_last_modified}" -gt "${prev_timestamp}" ] && [ "${prev_timestamp}" -gt 0 ]; then
				fn_discord_notify "Mod '${resolved_name}' (ID: ${mod_id}) has been updated."
			fi

			jq --arg mod "${mod_id}" --argjson time "${mod_last_modified}" '.[$mod] = $time' \
				"${timestamp_file}" > "${timestamp_file}.tmp" && mv "${timestamp_file}.tmp" "${timestamp_file}"
		fi

		updated_workshop_cfg+="${mod_id} ${resolved_name}"$'\n'
	done

	# Write resolved names back so the next run has them as a fallback.
	if [ -n "${updated_workshop_cfg}" ]; then
		printf '%s' "${updated_workshop_cfg}" > "${workshop_cfg}"
		printf "[ ${green}OK${default} ] workshop.cfg updated with mod names.\n"
	fi

	fn_copy_mod_keys

	if [ "${failed}" -gt 0 ]; then
		printf "[ ${red}FAIL${default} ] %s mod(s) failed to download. The server may reject clients.\n" "${failed}"
		return 1
	fi
	# Record what we now hold so `checkmods` compares against reality rather
	# than reporting the same updates again on its next run.
	local -a refreshed_ids=()
	mapfile -t refreshed_ids < <(fn_read_workshop_ids)
	[ "${#refreshed_ids[@]}" -gt 0 ] && fn_refresh_remote_timestamps "${refreshed_ids[@]}" || true
	rm -f "${HOME}/update_pending"

	printf "[ ${green}OK${default} ] All workshop mods are ready.\n"
	return 0
}

# ---------------------------------------------------------------------------
# fn_copy_mod_keys
# Copies every mod's BattlEye key into serverfiles/keys. Uses find rather than
# a glob so directory names containing spaces are handled correctly.
# ---------------------------------------------------------------------------
fn_copy_mod_keys(){
	local moddir keydir
	mkdir -p "${HOME}/serverfiles/keys"
	printf "[ ${green}DayZ${default} ] Copying mod keys into the server keys folder...\n"

	# Mods are symlinks into the workshop content directory, and find does not
	# follow symlinks unless asked (-L). Walking the @ links explicitly also
	# keeps us from recursing into serverfiles/keys itself.
	for moddir in "${HOME}/serverfiles/@"*; do
		[ -e "${moddir}" ] || continue
		while IFS= read -r keydir; do
			[ -d "${keydir}" ] || continue
			find -L "${keydir}" -maxdepth 1 -type f -iname '*.bikey' \
				-exec cp -u {} "${HOME}/serverfiles/keys/" \; 2>/dev/null
		done < <(find -L "${moddir}/" -maxdepth 2 -type d \( -iname 'keys' -o -iname 'key' \) 2>/dev/null)
	done
}

# ---------------------------------------------------------------------------
# fn_discord_notify
# Posts a message to the configured Discord webhook. Silent when no webhook is
# set - a missing webhook is a valid configuration, not an error.
# ---------------------------------------------------------------------------
fn_discord_notify(){
	[ -n "${discord_webhook_url}" ] || return 0
	curl -sS -H "Content-Type: application/json" -X POST \
		-d "$(jq -nc --arg content "$1" '{content: $content}')" \
		"${discord_webhook_url}" > /dev/null 2>&1 || true
}


# ---------------------------------------------------------------------------
# fn_missionfolder
# Reads the active mission name out of serverDZ.cfg. Printed rather than
# assigned so callers decide what to do when the config is missing.
# ---------------------------------------------------------------------------
fn_missionfolder(){
	local cfg="${HOME}/serverfiles/${config}"
	[ -f "${cfg}" ] || return 1
	# The template line is indented inside the Missions class, so take the text
	# between the quotes rather than counting fields - a positional cut lands on
	# the "=" when the line has leading whitespace.
	grep -iE '^[[:space:]]*template[[:space:]]*=' "${cfg}" | head -n1 | cut -d '"' -f2
}

# ---------------------------------------------------------------------------
# fn_backup_dayz
# Archives the mission folder and the server profile.
#
# The previous version called fn_stop_dayz followed by fn_start_dayz when it
# found the server running - but fn_start_dayz calls fn_backup_dayz, so a
# backup taken on a live server re-entered itself. The guard below makes the
# nested call a no-op, and a live server is now stopped, backed up and
# restarted explicitly instead of by recursion.
# ---------------------------------------------------------------------------
fn_backup_dayz(){
	if [ "${backup_in_progress:-0}" = "1" ]; then
		return 0
	fi
	local backup_in_progress=1
	local missionfolder backup_file profile_backup_file was_running=0

	mkdir -p "${HOME}/backup"

	missionfolder="$(fn_missionfolder)"
	if [ -z "${missionfolder}" ]; then
		printf "[ ${yellow}WARN${default} ] No mission template found in ${config}; skipping mission backup.\n"
	fi

	fn_status_dayz
	if [ "${dayzstatus}" != "0" ]; then
		was_running=1
		printf "[ ${yellow}DayZ${default} ] Server is running; stopping it for a consistent backup...\n"
		fn_stop_dayz
	fi

	backup_file="${HOME}/backup/${missionfolder}-$(date +%Y-%m-%d-%H-%M).tar"
	profile_backup_file="${HOME}/backup/serverprofile-$(date +%Y-%m-%d-%H-%M).tar"

	if [ -n "${missionfolder}" ] && [ -d "${HOME}/serverfiles/mpmissions/${missionfolder}" ]; then
		printf "[ ${green}DayZ${default} ] Backing up mission folder: ${cyan}%s${default}\n" "${missionfolder}"
		tar -cf "${backup_file}" -C "${HOME}/serverfiles/mpmissions" "${missionfolder}"
	fi

	if [ -d "${HOME}/serverprofile" ]; then
		printf "[ ${green}DayZ${default} ] Backing up server profile: ${cyan}%s${default}\n" "${HOME}/serverprofile"
		tar --exclude='*.log' --exclude='*.RPT' --exclude='*.mdmp' \
			-cf "${profile_backup_file}" -C "${HOME}" "serverprofile"
	fi

	printf "[ ${green}DayZ${default} ] Removing backups older than %s day(s)...\n" "${backup_retention_days}"
	find "${HOME}/backup" -type f -name '*.tar' -mtime "+${backup_retention_days}" -delete 2>/dev/null

	if [ "${was_running}" = "1" ]; then
		printf "[ ${green}DayZ${default} ] Restarting the server after backup...\n"
		fn_start_dayz
	fi
}

# ---------------------------------------------------------------------------
# fn_steam_workshop_details
# Queries the Steam Web API for the given published file ids and prints one
# "<id>\t<time_updated>" line per mod. This is the cheap way to ask "is there
# anything new?" - it costs one HTTP request rather than a full SteamCMD
# download pass, so it is safe to run frequently from cron.
# ---------------------------------------------------------------------------
fn_steam_workshop_details(){
	[ "$#" -gt 0 ] || return 0
	local -a curl_args=(-s --max-time 20 -X POST
		"https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")
	curl_args+=(-d "itemcount=$#")
	local i=0 id
	for id in "$@"; do
		curl_args+=(-d "publishedfileids[${i}]=${id}")
		i=$(( i + 1 ))
	done

	local response
	response="$(curl "${curl_args[@]}" 2>/dev/null)"
	[ -n "${response}" ] || return 1

	printf '%s' "${response}" | jq -r '
		.response.publishedfiledetails[]?
		| select(.result == 1)
		| "\(.publishedfileid)\t\(.time_updated // 0)"' 2>/dev/null
}

# ---------------------------------------------------------------------------
# fn_refresh_remote_timestamps
# Records the workshop's current version of each mod as the new baseline, so a
# later checkmods only reports genuinely newer versions. Called after a
# successful download pass.
# ---------------------------------------------------------------------------
fn_refresh_remote_timestamps(){
	local remote_ts="${HOME}/mod_remote_timestamps.json"
	[ -f "${remote_ts}" ] || echo "{}" > "${remote_ts}"
	[ "$#" -gt 0 ] || return 0

	local details updates
	details="$(fn_steam_workshop_details "$@")" || {
		printf "[ ${yellow}WARN${default} ] Steam API unreachable; update baseline not refreshed.\n"
		return 1
	}
	[ -n "${details}" ] || return 1

	updates="$(printf '%s\n' "${details}" | jq -Rn '
		[inputs | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
		| from_entries')"
	[ -n "${updates}" ] && [ "${updates}" != "null" ] || return 1

	jq --argjson updates "${updates}" '. * $updates' "${remote_ts}" > "${remote_ts}.tmp" \
		&& mv "${remote_ts}.tmp" "${remote_ts}"
}

# ---------------------------------------------------------------------------
# fn_check_mods
# Compares the workshop's current mod versions against the recorded baseline
# and, when anything is newer, leaves ~/update_pending so the next start
# downloads it. Deliberately does not download anything itself: run it on a
# frequent cron without tying up the server.
# ---------------------------------------------------------------------------
fn_check_mods(){
	local remote_ts="${HOME}/mod_remote_timestamps.json"
	local flag_file="${HOME}/update_pending"
	local -a mod_ids=()
	mapfile -t mod_ids < <(fn_read_workshop_ids)

	if [ "${#mod_ids[@]}" -eq 0 ]; then
		printf "[ ${lightblue}INFO${default} ] No mods configured; nothing to check.\n"
		return 0
	fi

	[ -f "${remote_ts}" ] || echo "{}" > "${remote_ts}"

	local details
	details="$(fn_steam_workshop_details "${mod_ids[@]}")" || {
		printf "[ ${yellow}WARN${default} ] Steam API unreachable; skipping check.\n"
		return 1
	}

	local -a updated_mods=()
	local pid tupdated stored
	while IFS=$'\t' read -r pid tupdated; do
		[ -z "${pid}" ] && continue
		stored="$(jq -r --arg p "${pid}" '.[$p] // 0' "${remote_ts}")"
		# A baseline of 0 means this mod has never been recorded. Treat that as
		# "needs downloading" so a newly added mod is picked up rather than
		# silently ignored until it happens to be updated upstream.
		if [ "${tupdated}" -gt "${stored}" ]; then
			updated_mods+=("${pid}")
		fi
	done <<< "${details}"

	if [ "${#updated_mods[@]}" -eq 0 ]; then
		printf "[ ${green}OK${default} ] All mods are up to date.\n"
		rm -f "${flag_file}"
		return 0
	fi

	date > "${flag_file}"
	printf "[ ${yellow}DayZ${default} ] %s mod update(s) available; flagged for the next start.\n" "${#updated_mods[@]}"
	local m
	for m in "${updated_mods[@]}"; do
		printf "  - %s\n" "${m}"
	done
	fn_discord_notify "DayZ mod updates available: $(printf '%s, ' "${updated_mods[@]}" | sed 's/, $//'). They will be applied on the next restart."
	return 0
}

# ---------------------------------------------------------------------------
# fn_update_workshop_line
# Rebuilds the workshop="@a;@b" line in config.ini from workshop.cfg.
#
# Keeping that line in sync by hand is the most common way to break a server:
# a mod is added to workshop.cfg, the launch parameter is forgotten, and the
# server starts without it. Only mods that are actually present on disk are
# included, so a failed download cannot produce a launch line the server will
# reject.
# ---------------------------------------------------------------------------
fn_update_workshop_line(){
	local workshopfolder="${HOME}/serverfiles/steamapps/workshop/content/${dayz_id}"
	local -a parts=() skipped=()
	local line mod_id name link_name

	if [ ! -f "${CONFIG_FILE}" ]; then
		printf "[ ${red}FAIL${default} ] %s not found.\n" "${CONFIG_FILE}"
		return 1
	fi

	while IFS= read -r line || [ -n "${line}" ]; do
		line="$(fn_trim "${line}")"
		[ -z "${line}" ] && continue
		case "${line}" in \#*) continue ;; esac

		mod_id="$(printf '%s' "${line}" | awk '{print $1}')"
		[[ "${mod_id}" =~ ^[0-9]+$ ]] || continue
		name="$(fn_trim "$(printf '%s' "${line}" | cut -d' ' -f2-)")"
		[ "${name}" = "${mod_id}" ] && name=""

		if [ -z "${name}" ]; then
			skipped+=("${mod_id} (no resolved name - run 'workshop' first)")
			continue
		fi

		link_name="$(fn_mod_link_name "${name}")"
		if [ ! -e "${HOME}/serverfiles/@${link_name}" ]; then
			skipped+=("${mod_id} (@${link_name} is not installed)")
			continue
		fi
		parts+=("@${link_name}")
	done < "${HOME}/workshop.cfg"

	local mod_line
	mod_line="$(IFS=';'; printf '%s' "${parts[*]}")"

	# Replace any existing workshop= line, commented out or not, and append one
	# if the config has none.
	local tmp="${CONFIG_FILE}.tmp"
	if grep -qE '^[[:space:]]*#?[[:space:]]*workshop=' "${CONFIG_FILE}"; then
		awk -v repl="workshop=\"${mod_line}\"" '
			/^[[:space:]]*#?[[:space:]]*workshop=/ && !done { print repl; done=1; next }
			{ print }' "${CONFIG_FILE}" > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
	else
		printf 'workshop="%s"\n' "${mod_line}" >> "${CONFIG_FILE}"
	fi
	chmod 600 "${CONFIG_FILE}"

	if [ "${#parts[@]}" -eq 0 ]; then
		printf "[ ${yellow}WARN${default} ] No installed mods found; workshop= set to empty.\n"
	else
		printf "[ ${green}OK${default} ] workshop= set to ${cyan}%s${default}\n" "${mod_line}"
	fi
	local sk
	for sk in "${skipped[@]}"; do
		printf "[ ${yellow}SKIP${default} ] %s\n" "${sk}"
	done
	return 0
}

# ---------------------------------------------------------------------------
# fn_clean_dayz
# Clears SteamCMD's metadata and partial-download caches. This is the first
# thing to try when SteamCMD reports a stale version or refuses to finish a
# download. The saved login lives in ~/Steam/config and is never touched, so
# the user stays signed in.
# ---------------------------------------------------------------------------
fn_clean_dayz(){
	printf "[ ${magenta}...${default} ] Clearing SteamCMD caches (login is preserved)...\n"
	rm -f "${HOME}/Steam/appcache/appinfo.vdf" "${HOME}/Steam/appcache/packageinfo.vdf"
	rm -rf "${HOME}/serverfiles/steamapps/downloading"
	rm -rf "${HOME}/serverfiles/steamapps/workshop/downloads"
	rm -rf "${HOME}/serverfiles/steamapps/workshop/temp"
	rm -f "${HOME}/serverfiles/steamapps/workshop/appworkshop_${dayz_id}.acf"
	printf "[ ${green}OK${default} ] Caches cleared. Steam login preserved.\n"
	return 0
}

# ---------------------------------------------------------------------------
# fn_clean_server
# Deletes the installed server, mods, profiles, backups and config so the next
# run starts from scratch. The Steam client directories are left alone so the
# user does not have to re-authorise (and re-enter Steam Guard).
# ---------------------------------------------------------------------------
fn_clean_server(){
	printf "[ ${red}WARNING${default} ] This deletes the server files, mods, profiles, backups and %s.\n" "${CONFIG_FILE}"
	printf "[ ${lightblue}INFO${default} ] Your Steam authorisation is preserved.\n"
	read -r -p "Type 'yes' to continue: " confirm
	if [ "${confirm}" != "yes" ]; then
		printf "[ ${lightblue}INFO${default} ] Aborted; nothing was deleted.\n"
		return 1
	fi

	fn_status_dayz
	if [ "${dayzstatus}" != "0" ]; then
		printf "[ ${yellow}DayZ${default} ] Stopping the server first...\n"
		fn_stop_dayz
	fi

	local d f
	for d in "${HOME}/serverfiles" "${HOME}/serverprofile" "${HOME}/steamcmd" \
	         "${HOME}/backup" "${HOME}/crashlogs"; do
		if [ -e "${d}" ]; then
			rm -rf "${d}"
			printf "[ ${green}OK${default} ] Removed %s\n" "${d}"
		fi
	done
	for f in "${HOME}/${CONFIG_FILE}" "${HOME}/workshop.cfg" "${HOME}/mod_timestamps.json" \
	         "${HOME}/mod_remote_timestamps.json" "${HOME}/update_pending" \
	         "${HOME}/.dayzlockfile" "${HOME}/.dayzlockupdate" "${HOME}/monitor.log" \
	         "${HOME}/tmux.log" "${HOME}/last_exit_code" "${HOME}/.dayz_launch_wrapper.sh"; do
		if [ -e "${f}" ]; then
			rm -f "${f}"
			printf "[ ${green}OK${default} ] Removed %s\n" "${f}"
		fi
	done

	printf "[ ${green}DayZ${default} ] Cleanup complete. Steam authorisation preserved.\n"
	return 0
}

fn_wipe_dayz(){
	local missionfolder storage
	missionfolder="$(fn_missionfolder)"
	if [ -z "${missionfolder}" ]; then
		printf "[ ${red}FAIL${default} ] Could not determine the mission folder from ${config}.\n"
		return 1
	fi
	storage="${HOME}/serverfiles/mpmissions/${missionfolder}/storage_1"

	printf "[ ${red}WARNING${default} ] This wipes all players and resets the Central Economy state.\n"
	for seconds in {9..0}; do
		printf "\r\t    Mission: ${cyan}%s${default} - wiping in ${red}%s${default} seconds. Press CTRL+C to abort." \
			"${missionfolder}" "${seconds}"
		sleep 1
	done
	printf "\n"

	fn_status_dayz
	local was_running=0
	if [ "${dayzstatus}" != "0" ]; then
		was_running=1
		fn_stop_dayz
	fi

	rm -f "${storage}/players.db"
	rm -rf "${storage:?}/data/"*
	printf "[ ${yellow}DayZ${default} ] players.db and storage data wiped.\n"
	fn_log_monitor "Server data wiped (mission: ${missionfolder})."

	if [ "${was_running}" = "1" ]; then
		sleep 0.5
		fn_start_dayz
	fi
}

#=======================================================================================#
#                              Status, players and RCON                                 #
#=======================================================================================#

# ---------------------------------------------------------------------------
# fn_cfg_value
# Reads a "key = value;" setting out of a DayZ config file (serverDZ.cfg) or a
# "Key value" setting out of a BattlEye config. Both formats appear in a normal
# install and both are read the same way here: first token is the key, the rest
# is the value with quotes and the trailing semicolon removed.
# ---------------------------------------------------------------------------
fn_cfg_value(){
	local file="$1" key="$2"
	[ -f "${file}" ] || return 1
	grep -iE "^[[:space:]]*${key}[[:space:]]*=?" "${file}" 2>/dev/null \
		| head -n1 \
		| sed -E "s/^[[:space:]]*${key}[[:space:]]*=?[[:space:]]*//I" \
		| tr -d '";' \
		| sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# fn_query_port
# The Steam query port, which is what A2S queries go to. Falls back to the
# DayZ default when serverDZ.cfg does not set it.
# ---------------------------------------------------------------------------
fn_query_port(){
	local qp
	qp="$(fn_cfg_value "${HOME}/serverfiles/${config}" "steamQueryPort")"
	printf '%s' "${qp:-27016}"
}

# ---------------------------------------------------------------------------
# fn_server_uptime
# Seconds since the server was started, derived from the lockfile's mtime.
# ---------------------------------------------------------------------------
fn_server_uptime(){
	local started now
	[ -f "${HOME}/.dayzlockfile" ] || { printf '0'; return; }
	started="$(date -r "${HOME}/.dayzlockfile" +%s 2>/dev/null || echo 0)"
	now="$(date +%s)"
	printf '%s' "$(( now - started ))"
}

# ---------------------------------------------------------------------------
# fn_status_dayz_report
# Human-readable status summary. `status --json` prints the same facts as JSON
# instead; that is what the web GUI polls, so the two must not drift apart -
# both are built from the same block of variables below.
# ---------------------------------------------------------------------------
fn_status_dayz_report(){
	local as_json=0
	[ "${1:-}" = "--json" ] && as_json=1

	fn_status_dayz
	local running="false" uptime=0 build="" mods=0 pending="false" last_exit="" players=""
	[ "${dayzstatus}" != "0" ] && running="true"
	uptime="$(fn_server_uptime)"
	[ "${running}" = "false" ] && uptime=0

	local manifest="${HOME}/serverfiles/steamapps/appmanifest_${appid}.acf"
	if [ -f "${manifest}" ]; then
		build="$(grep buildid "${manifest}" | tr '[:blank:]"' ' ' | tr -s ' ' | cut -d ' ' -f3)"
	fi
	mods="$(fn_read_workshop_ids | wc -l | tr -d ' ')"
	[ -f "${HOME}/update_pending" ] && pending="true"
	[ -f "${HOME}/last_exit_code" ] && last_exit="$(tr -dc '0-9' < "${HOME}/last_exit_code")"
	[ "${running}" = "true" ] && players="$(fn_a2s_players "$(fn_query_port)" 2>/dev/null || true)"

	if [ "${as_json}" = "1" ]; then
		jq -nc \
			--argjson running "${running}" \
			--argjson uptime "${uptime}" \
			--arg build "${build}" \
			--argjson mods "${mods:-0}" \
			--argjson pending "${pending}" \
			--arg last_exit "${last_exit}" \
			--arg players "${players}" \
			--arg version "${SCRIPT_VERSION}" \
			--argjson port "${port}" \
			'{
				running: $running,
				uptime_seconds: $uptime,
				build: $build,
				mod_count: $mods,
				update_pending: $pending,
				last_exit_code: $last_exit,
				players: (if $players == "" then null else ($players | tonumber) end),
				port: $port,
				version: $version
			}'
		return 0
	fi

	printf "\n${lightyellow}DayZ Server Status${default}\n"
	if [ "${running}" = "true" ]; then
		printf "  State:      ${green}running${default} (%dh %dm)\n" "$(( uptime / 3600 ))" "$(( (uptime % 3600) / 60 ))"
	else
		printf "  State:      ${red}stopped${default}\n"
	fi
	printf "  Game port:  %s\n" "${port}"
	printf "  Query port: %s\n" "$(fn_query_port)"
	printf "  Build:      %s\n" "${build:-unknown}"
	printf "  Mods:       %s\n" "${mods}"
	[ -n "${players}" ] && printf "  Players:    %s\n" "${players}"
	if [ "${pending}" = "true" ]; then
		printf "  Updates:    ${yellow}mod updates pending${default} (applied on next start)\n"
	else
		printf "  Updates:    ${green}up to date${default}\n"
	fi
	[ -n "${last_exit}" ] && [ "${running}" = "false" ] && printf "  Last exit:  %s\n" "${last_exit}"
	printf "  Manager:    v%s\n\n" "${SCRIPT_VERSION}"
	return 0
}

# ---------------------------------------------------------------------------
# fn_a2s_players
# Current player count via the Steam A2S_INFO query. Implemented with a short
# Python helper rather than a new dependency: the query needs a raw UDP socket
# and a challenge-response round trip that no standard shell tool provides,
# and python3 is already present on every distribution this script supports.
# Prints nothing if the server does not answer.
# ---------------------------------------------------------------------------
fn_a2s_players(){
	local qport="$1"
	command -v python3 &>/dev/null || return 1
	python3 - "${qport}" <<'PYEOF' 2>/dev/null
import socket, struct, sys

port = int(sys.argv[1])
REQ = b"\xff\xff\xff\xffTSource Engine Query\x00"

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    s.sendto(REQ, ("127.0.0.1", port))
    data, _ = s.recvfrom(4096)

    # Modern servers answer a bare A2S_INFO with a challenge (header 'A') that
    # must be echoed back before they send the real reply.
    if len(data) > 4 and data[4:5] == b"A":
        s.sendto(REQ + data[5:9], ("127.0.0.1", port))
        data, _ = s.recvfrom(4096)

    if len(data) < 5 or data[4:5] != b"I":
        sys.exit(1)

    # Header(4) + type(1) + protocol(1), then four null-terminated strings:
    # name, map, folder, game. Then app id (short), then players.
    i = 6
    for _ in range(4):
        end = data.index(b"\x00", i)
        i = end + 1
    i += 2  # app id
    print(struct.unpack_from("<B", data, i)[0])
except Exception:
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# fn_be_cfg
# Path to the BattlEye config actually in use. The server rewrites its config
# into beserver_x64_active_*.cfg on first launch, and that generated file - not
# the one the user edited - is what BattlEye reads.
# ---------------------------------------------------------------------------
fn_be_cfg(){
	local active
	active="$(find "${HOME}/serverfiles/battleye" -maxdepth 1 -name 'beserver_x64_active_*.cfg' \
		-printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
	if [ -n "${active}" ]; then
		printf '%s' "${active}"
	elif [ -f "${HOME}/serverfiles/battleye/beserver_x64.cfg" ]; then
		printf '%s' "${HOME}/serverfiles/battleye/beserver_x64.cfg"
	else
		return 1
	fi
}

# ---------------------------------------------------------------------------
# fn_rcon_dayz
# Sends a command to the server over BattlEye RCon.
#
# The port and password are read from the BattlEye config rather than taken as
# arguments, so the password never appears in shell history, in the process
# list, or in a crontab.
# ---------------------------------------------------------------------------
fn_rcon_dayz(){
	if [ "$#" -eq 0 ]; then
		printf "[ ${red}FAIL${default} ] Usage: %s rcon <command>    e.g. %s rcon players\n" "$0" "$0"
		return 1
	fi

	if ! command -v bercon-cli &>/dev/null; then
		printf "[ ${red}FAIL${default} ] bercon-cli is not installed.\n"
		printf "[ ${lightblue}INFO${default} ] Install it with:\n\n"
		printf "\tsudo curl -L -o /usr/local/bin/bercon-cli \\\\\n"
		printf "\t  https://github.com/WoozyMasta/bercon-cli/releases/latest/download/bercon-cli-linux-amd64\n"
		printf "\tsudo chmod +x /usr/local/bin/bercon-cli\n\n"
		return 1
	fi

	local be_cfg rcon_port rcon_pass
	be_cfg="$(fn_be_cfg)" || {
		printf "[ ${red}FAIL${default} ] No BattlEye config found. Start the server once, or run '%s setup'.\n" "$0"
		return 1
	}
	rcon_port="$(fn_cfg_value "${be_cfg}" "RConPort")"
	rcon_pass="$(fn_cfg_value "${be_cfg}" "RConPassword")"

	if [ -z "${rcon_pass}" ]; then
		printf "[ ${red}FAIL${default} ] No RConPassword set in %s\n" "${be_cfg}"
		printf "[ ${lightblue}TIP${default} ] Run '%s setup' to configure RCon.\n" "$0"
		return 1
	fi
	: "${rcon_port:=2306}"

	bercon-cli --ip 127.0.0.1 --port "${rcon_port}" --password "${rcon_pass}" "$@"
}

#=======================================================================================#
#                            Setup wizard and mod management                            #
#=======================================================================================#

# ---------------------------------------------------------------------------
# fn_set_config_value
# Sets key=value in config.ini, replacing an existing line (commented out or
# not) or appending one when the key is absent.
# ---------------------------------------------------------------------------
fn_set_config_value(){
	local key="$1" value="$2" file="${CONFIG_FILE}"
	local tmp="${file}.tmp"
	[ -f "${file}" ] || touch "${file}"
	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "${file}"; then
		awk -v k="${key}" -v v="${key}=${value}" '
			$0 ~ "^[[:space:]]*#?[[:space:]]*" k "=" && !done { print v; done=1; next }
			{ print }' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
	else
		printf '%s=%s\n' "${key}" "${value}" >> "${file}"
	fi
	chmod 600 "${file}"
}

# ---------------------------------------------------------------------------
# fn_prompt
# Reads one value with a default. $1 prompt, $2 default, $3 "secret" to hide
# input. The answer is printed on stdout, so all status text here goes to
# stderr to keep command substitution clean.
# ---------------------------------------------------------------------------
fn_prompt(){
	local prompt="$1" default="$2" secret="${3:-}" answer=""
	if [ "${secret}" = "secret" ]; then
		printf "%s: " "${prompt}" >&2
		read -r -s answer
		printf "\n" >&2
	elif [ -n "${default}" ]; then
		printf "%s [%s]: " "${prompt}" "${default}" >&2
		read -r answer
	else
		printf "%s: " "${prompt}" >&2
		read -r answer
	fi
	printf '%s' "${answer:-${default}}"
}

# ---------------------------------------------------------------------------
# fn_setup_dayz
# Interactive first-run configuration.
#
# Getting a server online used to mean hand-editing three files in three
# different syntaxes - config.ini, serverDZ.cfg and beserver_x64.cfg - with
# nothing checking the result. This asks for the handful of values that
# actually differ between servers and writes all three, then explains what to
# do next.
# ---------------------------------------------------------------------------
fn_setup_dayz(){
	local setup_incomplete=0
	printf "\n${lightyellow}DayZ Server Manager - setup${default}\n"
	printf "Press Enter to accept the value in brackets.\n\n"

	# config.ini has to exist before we can edit it in place.
	if [ ! -f "${CONFIG_FILE}" ]; then
		echo -e "$DEFAULT_CONFIG" > "${CONFIG_FILE}"
		chmod 600 "${CONFIG_FILE}"
	fi
	# Values already configured become the defaults, so re-running setup to
	# change one thing does not mean retyping everything.
	source "${CONFIG_FILE}" 2>/dev/null || true

	printf "${cyan}Steam${default}\n"
	local new_login
	new_login="$(fn_prompt "  Steam username (must own DayZ)" "${steamlogin:-}")"
	if [ -z "${new_login}" ] || [ "${new_login}" = "CHANGEME" ]; then
		printf "[ ${red}FAIL${default} ] A Steam username is required.\n"
		return 1
	fi
	fn_set_config_value "steamlogin" "${new_login}"
	printf "  ${lightblue}Note${default}: SteamCMD asks for your password and Steam Guard code on first use.\n"
	printf "  It is never stored in %s.\n\n" "${CONFIG_FILE}"

	printf "${cyan}Ports${default}\n"
	local game_port query_port rcon_port
	game_port="$(fn_prompt "  Game port" "${port:-2301}")"
	query_port="$(fn_prompt "  Steam query port" "27016")"
	rcon_port="$(fn_prompt "  BattlEye RCon port" "2306")"
	if [ "${rcon_port}" = "${game_port}" ]; then
		printf "[ ${red}FAIL${default} ] The RCon port must differ from the game port.\n"
		return 1
	fi
	fn_set_config_value "port" "${game_port}"
	printf "\n"

	printf "${cyan}Server${default}\n"
	local hostname max_players rcon_pass
	hostname="$(fn_prompt "  Server name" "My DayZ Server")"
	max_players="$(fn_prompt "  Max players" "60")"
	rcon_pass="$(fn_prompt "  RCon password (leave blank to generate one)" "" secret)"
	if [ -z "${rcon_pass}" ]; then
		rcon_pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
		printf "  Generated RCon password: ${lightyellow}%s${default}\n" "${rcon_pass}"
	fi
	printf "\n"

	printf "${cyan}Web GUI${default}\n"
	local enable_web bind
	enable_web="$(fn_prompt "  Enable the web GUI? [y/N]" "n")"
	case "${enable_web}" in
		[Yy]*)
			bind="$(fn_prompt "  Bind address (127.0.0.1 keeps it local-only)" "127.0.0.1")"
			fn_set_config_value "web_bind" "${bind}"
			fn_set_config_value "web_port" "$(fn_prompt "  Web port" "8080")"
			if [ "${bind}" != "127.0.0.1" ] && [ "${bind}" != "localhost" ]; then
				printf "  [ ${yellow}WARN${default} ] %s exposes the GUI on the network over plain HTTP.\n" "${bind}"
				printf "  Put it behind a reverse proxy with HTTPS before using it that way.\n"
			fi
			;;
	esac
	printf "\n"

	# --- serverDZ.cfg ---------------------------------------------------
	local dz_cfg="${HOME}/serverfiles/${config:-serverDZ.cfg}"
	if [ -d "${HOME}/serverfiles" ]; then
		[ -f "${dz_cfg}" ] && cp -f "${dz_cfg}" "${dz_cfg}.bak.$(date +%Y%m%d-%H%M%S)"
		cat > "${dz_cfg}" <<EOF
hostname = "${hostname}";
password = "";
passwordAdmin = "";
maxPlayers = ${max_players};
verifySignatures = 2;
forceSameBuild = 1;
disableVoN = 0;
vonCodecQuality = 20;
disable3rdPerson = 0;
disableCrosshair = 0;
serverTime = "SystemTime";
serverTimeAcceleration = 12;
serverNightTimeAcceleration = 1;
serverTimePersistent = 0;
guaranteedUpdates = 1;
loginQueueConcurrentPlayers = 5;
loginQueueMaxPlayers = 500;
instanceId = 1;
storageAutoFix = 1;
steamQueryPort = ${query_port};

class Missions
{
    class DayZ
    {
        template = "dayzOffline.chernarusplus";
    };
};
EOF
		printf "[ ${green}OK${default} ] Wrote %s\n" "${dz_cfg}"
	else
		printf "[ ${yellow}SKIP${default} ] Server files are not installed yet, so %s and the\n" "${config:-serverDZ.cfg}"
		printf "\t BattlEye config cannot be written yet. Run '${lightyellow}%s install${default}' first,\n" "$0"
		printf "\t then run '${lightyellow}%s setup${default}' again to write them.\n" "$0"
		setup_incomplete=1
	fi

	# --- BattlEye -------------------------------------------------------
	local be_dir="${HOME}/serverfiles/battleye"
	if [ -d "${HOME}/serverfiles" ]; then
		mkdir -p "${be_dir}"
		cat > "${be_dir}/beserver_x64.cfg" <<EOF
RConPassword ${rcon_pass}
RConPort ${rcon_port}
RestrictRCon 0
EOF
		chmod 600 "${be_dir}/beserver_x64.cfg"
		# The server regenerates its active config from this one on launch, so
		# stale generated copies would otherwise keep the old password alive.
		rm -f "${be_dir}"/beserver_x64_active_*.cfg
		printf "[ ${green}OK${default} ] Wrote %s\n" "${be_dir}/beserver_x64.cfg"
	fi

	touch "${HOME}/workshop.cfg"
	chmod 600 "${HOME}/workshop.cfg"

	printf "\n[ ${green}DONE${default} ] Setup complete.\n\n"
	printf "${lightyellow}Next steps${default}\n"
	if [ "${setup_incomplete:-0}" = "1" ]; then
		printf "  1. %s install          # download the server files\n" "$0"
		printf "  2. %s setup            # write serverDZ.cfg and the RCon config\n" "$0"
		printf "  3. %s mods add <id>    # add Steam Workshop mods (optional)\n" "$0"
		printf "  4. %s start            # start the server\n\n" "$0"
	else
		printf "  1. %s mods add <id>    # add Steam Workshop mods (optional)\n" "$0"
		printf "  2. %s start            # start the server\n\n" "$0"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# fn_mods_dayz
# add / remove / list mods without opening an editor. Accepts a bare id or a
# full workshop URL, because copying the URL out of the browser is what people
# actually do.
# ---------------------------------------------------------------------------
fn_mods_dayz(){
	local action="${1:-list}"
	shift || true
	local workshop_cfg="${HOME}/workshop.cfg"
	touch "${workshop_cfg}"

	case "${action}" in
		add)
			[ "$#" -gt 0 ] || { printf "[ ${red}FAIL${default} ] Usage: %s mods add <id|url> [...]\n" "$0"; return 1; }
			local arg mod_id added=0 existing_ids
			for arg in "$@"; do
				# Accept ...?id=1234567890 as well as a bare id.
				mod_id="$(printf '%s' "${arg}" | grep -oE '[0-9]{6,}' | head -n1)"
				if [ -z "${mod_id}" ]; then
					printf "[ ${yellow}SKIP${default} ] Could not find a mod id in '%s'\n" "${arg}"
					continue
				fi
				# Capture the id list first: piping it into `grep -q` lets grep
				# exit on the first match and SIGPIPE the producer, and pipefail
				# then reports the whole pipeline as failed.
				existing_ids="$(fn_read_workshop_ids)"
				if printf '%s\n' "${existing_ids}" | grep -qx "${mod_id}"; then
					printf "[ ${lightblue}INFO${default} ] Mod %s is already listed.\n" "${mod_id}"
					continue
				fi
				printf '%s\n' "${mod_id}" >> "${workshop_cfg}"
				printf "[ ${green}OK${default} ] Added mod %s\n" "${mod_id}"
				added=$(( added + 1 ))
			done
			if [ "${added}" -gt 0 ]; then
				printf "[ ${lightblue}TIP${default} ] Run '%s workshop' to download, then '%s updateconfig'.\n" "$0" "$0"
			fi
			;;
		remove|rm)
			[ "$#" -gt 0 ] || { printf "[ ${red}FAIL${default} ] Usage: %s mods remove <id> [...]\n" "$0"; return 1; }
			local tmp="${workshop_cfg}.tmp" arg2 mod_id2
			for arg2 in "$@"; do
				mod_id2="$(printf '%s' "${arg2}" | grep -oE '[0-9]{6,}' | head -n1)"
				[ -n "${mod_id2}" ] || continue
				grep -v -E "^[[:space:]]*${mod_id2}([[:space:]]|$)" "${workshop_cfg}" > "${tmp}" || true
				mv "${tmp}" "${workshop_cfg}"
				printf "[ ${green}OK${default} ] Removed mod %s from workshop.cfg\n" "${mod_id2}"
			done
			printf "[ ${lightblue}TIP${default} ] Run '%s updateconfig' so the launch line matches.\n" "$0"
			printf "[ ${lightblue}NOTE${default} ] The downloaded files and the @symlink are left in place.\n"
			;;
		list|ls)
			local line count=0
			printf "\n${lightyellow}Configured mods${default}\n"
			while IFS= read -r line || [ -n "${line}" ]; do
				line="$(fn_trim "${line}")"
				[ -z "${line}" ] && continue
				case "${line}" in \#*) continue ;; esac
				printf "  %s\n" "${line}"
				count=$(( count + 1 ))
			done < "${workshop_cfg}"
			[ "${count}" -eq 0 ] && printf "  (none)\n"
			printf "\n"
			;;
		*)
			printf "[ ${red}FAIL${default} ] Usage: %s mods {add|remove|list} [id|url]\n" "$0"
			return 1
			;;
	esac
	return 0
}

#=======================================================================================#
#                              systemd and the web GUI                                  #
#=======================================================================================#

# ---------------------------------------------------------------------------
# fn_systemd_dayz
# Writes systemd *user* units for the server, the crash monitor and the web
# GUI. User units need no root and no sudo, which matters because this script
# refuses to run as root in the first place.
#
# `loginctl enable-linger` is what makes user units survive logout and start at
# boot; without it the units stop the moment the SSH session ends, so it is
# called out explicitly rather than left as a footnote.
# ---------------------------------------------------------------------------
fn_systemd_dayz(){
	local unit_dir="${HOME}/.config/systemd/user"
	local script_path
	script_path="$(readlink -f "$0")"
	mkdir -p "${unit_dir}"

	cat > "${unit_dir}/dayzserver.service" <<EOF
[Unit]
Description=DayZ Standalone Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${HOME}
ExecStart=${script_path} start
ExecStop=${script_path} stop
TimeoutStartSec=1800
TimeoutStopSec=120

[Install]
WantedBy=default.target
EOF

	cat > "${unit_dir}/dayzserver-monitor.service" <<EOF
[Unit]
Description=DayZ server crash monitor
After=dayzserver.service

[Service]
Type=oneshot
WorkingDirectory=${HOME}
ExecStart=${script_path} monitor
EOF

	cat > "${unit_dir}/dayzserver-monitor.timer" <<EOF
[Unit]
Description=Run the DayZ crash monitor every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

	cat > "${unit_dir}/dayzserver-checkmods.service" <<EOF
[Unit]
Description=Check the Steam Workshop for DayZ mod updates

[Service]
Type=oneshot
WorkingDirectory=${HOME}
ExecStart=${script_path} checkmods
EOF

	cat > "${unit_dir}/dayzserver-checkmods.timer" <<EOF
[Unit]
Description=Check for DayZ mod updates every 2 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=2h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

	cat > "${unit_dir}/dayzweb.service" <<EOF
[Unit]
Description=DayZ Server Manager web GUI
After=network.target

[Service]
Type=simple
WorkingDirectory=${HOME}
ExecStart=/usr/bin/env python3 ${HOME}/dayzweb.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

	printf "[ ${green}OK${default} ] Wrote systemd user units to %s\n\n" "${unit_dir}"
	printf "${lightyellow}Enable them with${default}\n"
	printf "  systemctl --user daemon-reload\n"
	printf "  systemctl --user enable --now dayzserver.service\n"
	printf "  systemctl --user enable --now dayzserver-monitor.timer\n"
	printf "  systemctl --user enable --now dayzserver-checkmods.timer\n"
	printf "  systemctl --user enable --now dayzweb.service        # optional web GUI\n\n"
	printf "${lightyellow}So they start at boot without you logged in${default}\n"
	printf "  sudo loginctl enable-linger %s\n\n" "$(whoami)"
	return 0
}

# ---------------------------------------------------------------------------
# fn_web_dayz
# Starts, stops or reports on the web GUI daemon.
# ---------------------------------------------------------------------------
fn_web_dayz(){
	local action="${1:-status}"
	local pidfile="${HOME}/.dayzweb.pid"
	local script="${HOME}/dayzweb.py"
	local pid=""
	[ -f "${pidfile}" ] && pid="$(cat "${pidfile}" 2>/dev/null)"

	# A pidfile left behind by a killed process would otherwise make the GUI
	# look permanently "running".
	if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
		rm -f "${pidfile}"
		pid=""
	fi

	case "${action}" in
		start)
			if [ -n "${pid}" ]; then
				printf "[ ${yellow}INFO${default} ] Web GUI already running (pid %s).\n" "${pid}"
				return 0
			fi
			if [ ! -f "${script}" ]; then
				printf "[ ${red}FAIL${default} ] %s not found. Download it alongside dayzserver.sh.\n" "${script}"
				return 1
			fi
			command -v python3 &>/dev/null || {
				printf "[ ${red}FAIL${default} ] python3 is required for the web GUI.\n"
				return 1
			}
			nohup python3 "${script}" >> "${HOME}/dayzweb.log" 2>&1 &
			echo $! > "${pidfile}"
			sleep 1
			if kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
				printf "[ ${green}OK${default} ] Web GUI started on ${cyan}http://%s:%s${default}\n" "${web_bind}" "${web_port}"
				[ "${web_bind}" = "127.0.0.1" ] && \
					printf "[ ${lightblue}TIP${default} ] Reach it remotely with: ssh -L %s:127.0.0.1:%s %s@<server>\n" \
						"${web_port}" "${web_port}" "$(whoami)"
			else
				rm -f "${pidfile}"
				printf "[ ${red}FAIL${default} ] Web GUI failed to start. See %s\n" "${HOME}/dayzweb.log"
				return 1
			fi
			;;
		stop)
			if [ -z "${pid}" ]; then
				printf "[ ${yellow}INFO${default} ] Web GUI is not running.\n"
				return 0
			fi
			kill "${pid}" 2>/dev/null
			rm -f "${pidfile}"
			printf "[ ${green}OK${default} ] Web GUI stopped.\n"
			;;
		status)
			if [ -n "${pid}" ]; then
				printf "[ ${green}OK${default} ] Web GUI running (pid %s) on http://%s:%s\n" "${pid}" "${web_bind}" "${web_port}"
			else
				printf "[ ${yellow}INFO${default} ] Web GUI is not running.\n"
			fi
			;;
		*)
			printf "[ ${red}FAIL${default} ] Usage: %s web {start|stop|status}\n" "$0"
			return 1
			;;
	esac
	return 0
}

#=======================================================================================#
#                                   Command dispatch                                    #
#=======================================================================================#
#
# Commands are declared as "aliases|description" and dispatched by a case
# statement. The previous nested-awk dispatcher could not forward arguments to
# a command, which the newer commands (rcon, mods, status --json) all need.

commands=(
	"setup|setup|Interactive first-run configuration (start here)."
	"stat|status|Show server status. Add --json for machine-readable output."
	"st|start|Start the server."
	"sp|stop|Stop the server."
	"r|restart|Restart the server."
	"m|monitor|Check server status and restart it if it crashed."
	"c|console|Attach to the server console."
	"i|install|Install SteamCMD and the DayZ server files."
	"u|update|Check for and apply server updates."
	"v|validate|Validate the server files with SteamCMD."
	"ws|workshop|Download and link Steam Workshop mods."
	"chm|checkmods|Check the workshop for mod updates; flag them for the next start."
	"uc|updateconfig|Rebuild the workshop= launch line in config.ini."
	"b|backup|Create backup archives of the mission and profile."
	"wi|wipe|Wipe server data (players and storage)."
	"cc|cleancache|Clear SteamCMD and workshop caches (keeps your Steam login)."
	"cs|cleanserver|Delete the installed server, mods and config for a fresh start."
	"mods|mods|Manage mods: mods add|remove|list <id|url>."
	"p|players|Show the current player count."
	"rc|rcon|Send a BattlEye RCon command, e.g. rcon players."
	"web|web|Control the web GUI: web start|stop|status."
	"sd|systemd|Write systemd user units for the server, monitor and GUI."
)

# ---------------------------------------------------------------------------
# fn_opt_usage
# Prints the command table. Exits 0 when the user asked for help and non-zero
# only when it is shown because of a mistake - cron and systemd read the exit
# status, and the old code reported failure on every successful run.
# ---------------------------------------------------------------------------
fn_opt_usage(){
	local entry short long desc
	printf "\n${lightyellow}DayZ Linux Server Manager${default} v${SCRIPT_VERSION}\n"
	printf "\nUsage:${lightblue} $0 [command]${default}\n\n"
	printf "${lightyellow}Commands${default}\n"
	# Columns are aligned with printf padding rather than `column`, which is not
	# installed on minimal systems and containers.
	for entry in "${commands[@]}"; do
		IFS='|' read -r short long desc <<< "${entry}"
		printf "  ${cyan}%-14s${default}%-6s %s\n" "${long}" "${short}" "${desc}"
	done
	printf "\n"
	return "${1:-0}"
}

# ---------------------------------------------------------------------------
# fn_dispatch
# Maps a command (long name or short alias) to its function, forwarding any
# remaining arguments. Returns 127 for an unknown command so the caller can
# tell "no such command" apart from "the command failed".
# ---------------------------------------------------------------------------
fn_dispatch(){
	local cmd="$1"
	shift || true
	case "${cmd}" in
		setup)         fn_setup_dayz "$@" ;;
		stat|status)   fn_status_dayz_report "$@" ;;
		st|start)      fn_start_dayz "$@" ;;
		sp|stop)       fn_stop_dayz "$@" ;;
		r|restart)     fn_restart_dayz "$@" ;;
		m|monitor)     fn_monitor_dayz "$@" ;;
		c|console)     fn_console_dayz "$@" ;;
		i|install)     fn_install_dayz "$@" ;;
		u|update)      fn_update_dayz "$@" ;;
		v|validate)    fn_validate_dayz "$@" ;;
		ws|workshop)   fn_workshop_mods "$@" ;;
		chm|checkmods) fn_check_mods "$@" ;;
		uc|updateconfig) fn_update_workshop_line "$@" ;;
		b|backup)      fn_backup_dayz "$@" ;;
		wi|wipe)       fn_wipe_dayz "$@" ;;
		cc|cleancache) fn_clean_dayz "$@" ;;
		cs|cleanserver) fn_clean_server "$@" ;;
		mods)          fn_mods_dayz "$@" ;;
		p|players)     fn_a2s_players "$(fn_query_port)" || { printf "[ ${yellow}INFO${default} ] Server did not answer the query.\n"; return 1; } ;;
		rc|rcon)       fn_rcon_dayz "$@" ;;
		web)           fn_web_dayz "$@" ;;
		sd|systemd)    fn_systemd_dayz "$@" ;;
		help|--help|-h)          fn_opt_usage 0 ;;
		version|--version|-v)    printf "DayZ Linux Server Manager v%s\n" "${SCRIPT_VERSION}" ;;
		*)             return 127 ;;
	esac
}

#=======================================================================================#
#                                        Startup                                        #
#=======================================================================================#

fn_checkroot_dayz
fn_checkscreen

# help and version answer without needing dependencies or an installed server.
case "${getopt}" in
	help|--help|-h|version|--version|-v)
		fn_dispatch "${getopt}"
		exit $?
		;;
esac

check_dependencies

if [ "${maintenance_mode}" != "1" ]; then
	if [ ! -f "${HOME}/steamcmd/steamcmd.sh" ] || [ ! -f "${HOME}/serverfiles/DayZServer" ]; then
		printf "[ ${yellow}INFO${default} ] No SteamCMD and/or server files found.\n"
		# $0 is this script; the old code chmod'd "${HOME}/dayzserver", a path
		# that has never existed - the file is dayzserver.sh.
		chmod u+x "$0" 2>/dev/null
		fn_install_dayz
		if [ -f "${HOME}/steamcmd/steamcmd.sh" ] && [ -f "${HOME}/serverfiles/DayZServer" ]; then
			fn_opt_usage 0
		fi
		exit 0
	fi
fi

if [ -z "${getopt}" ]; then
	fn_opt_usage 0
	exit 0
fi

fn_dispatch "$@"
status=$?

if [ "${status}" -eq 127 ]; then
	printf "${red}Unknown command${default}: %s %s\n" "$0" "${getopt}"
	fn_opt_usage 1
	exit 1
fi

exit "${status}"
