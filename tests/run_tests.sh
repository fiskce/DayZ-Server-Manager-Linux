#!/bin/bash
#=======================================================================================#
#     Test harness for dayzserver.sh
#=======================================================================================#
#
# A real DayZ server cannot run in CI (it needs Steam credentials and a game
# licence), so these tests build a throwaway $HOME, put stub versions of
# steamcmd.sh and tmux on PATH, and assert on what the script does with them.
#
# Run with:  ./tests/run_tests.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/dayzserver.sh"
STUBS="${REPO_ROOT}/tests/stubs"

pass=0
fail=0
current_test=""

red="\e[31m"; green="\e[32m"; yellow="\e[33m"; cyan="\e[36m"; default="\e[0m"

start_test(){
	current_test="$1"
	printf "${cyan}==>${default} %s\n" "$1"
}

ok(){
	pass=$(( pass + 1 ))
	printf "    ${green}PASS${default} %s\n" "$1"
}

no(){
	fail=$(( fail + 1 ))
	printf "    ${red}FAIL${default} %s\n" "$1"
	[ -n "${2:-}" ] && printf "         %s\n" "$2"
}

assert_contains(){
	if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else no "$3" "expected to find: $2"; fi
}

assert_not_contains(){
	if printf '%s' "$1" | grep -qF -- "$2"; then no "$3" "did not expect: $2"; else ok "$3"; fi
}

assert_eq(){
	if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected '$2', got '$1'"; fi
}

assert_file(){
	if [ -e "$1" ]; then ok "$2"; else no "$2" "missing: $1"; fi
}

assert_no_file(){
	if [ -e "$1" ]; then no "$2" "should not exist: $1"; else ok "$2"; fi
}

# ---------------------------------------------------------------------------
# make_home
# Builds an isolated fake server home with stubs on PATH. Everything each test
# touches lives under it, so tests cannot affect each other or the real system.
# ---------------------------------------------------------------------------
make_home(){
	FAKE_HOME="$(mktemp -d)"
	export STUB_STATE="${FAKE_HOME}/.stubstate"
	export STUB_LOG="${FAKE_HOME}/.stublog"
	mkdir -p "${STUB_STATE}" "${FAKE_HOME}/steamcmd" "${FAKE_HOME}/bin" \
		"${FAKE_HOME}/serverfiles/steamapps" "${FAKE_HOME}/serverfiles/keys" \
		"${FAKE_HOME}/serverfiles/battleye" "${FAKE_HOME}/serverprofile"
	: > "${STUB_LOG}"

	cp "${STUBS}/steamcmd.sh" "${FAKE_HOME}/steamcmd/steamcmd.sh"
	# The 32-bit runtime check queries the package manager; stub it so the tests
	# do not depend on what happens to be installed on the machine running them.
	cp "${STUBS}/dpkg-query" "${FAKE_HOME}/bin/dpkg-query"
	touch "${FAKE_HOME}/serverfiles/DayZServer"
	chmod +x "${FAKE_HOME}/serverfiles/DayZServer"

	# An installed-looking app manifest, so the update check is a no-op unless a
	# test deliberately changes STUB_BUILDID.
	cat > "${FAKE_HOME}/serverfiles/steamapps/appmanifest_223350.acf" <<ACF
"AppState"
{
	"buildid"		"1000"
}
ACF

	cat > "${FAKE_HOME}/serverfiles/serverDZ.cfg" <<CFG
hostname = "Test Server";
maxPlayers = 60;
steamQueryPort = 27016;
class Missions
{
    class DayZ
    {
        template = "dayzOffline.chernarusplus";
    };
};
CFG
	mkdir -p "${FAKE_HOME}/serverfiles/mpmissions/dayzOffline.chernarusplus/storage_1/data"

	# tmux stub: reports "no session" so the script sees a stopped server.
	cat > "${FAKE_HOME}/bin/tmux" <<'TMUX'
#!/bin/bash
case "$1" in
	list-sessions) exit 1 ;;
	*) exit 0 ;;
esac
TMUX
	chmod +x "${FAKE_HOME}/bin/tmux"

	cp "${SCRIPT}" "${FAKE_HOME}/dayzserver.sh"
	chmod +x "${FAKE_HOME}/dayzserver.sh"

	cat > "${FAKE_HOME}/config.ini" <<CFG
appid=223350
dayz_id=221100
port=2301
limitFPS=60
workshop_retries=5
backup_retention_days=2
auto_update_on_start=0
steamlogin=testuser
config=serverDZ.cfg
discord_webhook_url=""
dayzparameter=" -config=serverDZ.cfg -port=2301"
CFG
	chmod 600 "${FAKE_HOME}/config.ini"
}

cleanup_home(){
	[ -n "${FAKE_HOME:-}" ] && [ -d "${FAKE_HOME}" ] && rm -rf "${FAKE_HOME}"
}

# Runs dayzserver.sh inside the fake home with the stubs on PATH.
run_dayz(){
	( cd "${FAKE_HOME}" && HOME="${FAKE_HOME}" PATH="${FAKE_HOME}/bin:${PATH}" \
		ansi=off DAYZ_ALLOW_ROOT=1 ./dayzserver.sh "$@" 2>&1 )
}

#=======================================================================================#

start_test "Syntax check"
if bash -n "${SCRIPT}"; then ok "dayzserver.sh parses"; else no "dayzserver.sh parses"; fi
if [ -f "${REPO_ROOT}/dayzweb.py" ]; then
	if python3 -m py_compile "${REPO_ROOT}/dayzweb.py" 2>/dev/null; then
		ok "dayzweb.py compiles"
	else
		no "dayzweb.py compiles"
	fi
fi

#=======================================================================================#
# Issue #1: a workshop.cfg with CRLF line endings and trailing whitespace used to
# leave every mod except the last one out of the download.
#=======================================================================================#
start_test "Issue #1 - CRLF and trailing whitespace in workshop.cfg"
make_home
printf '1111111 \r\n2222222\r\n  3333333  \r\n' > "${FAKE_HOME}/workshop.cfg"
out="$(run_dayz workshop)"
log="$(cat "${STUB_LOG}")"
assert_contains "${log}" "workshop_download_item 221100 1111111" "first mod is downloaded"
assert_contains "${log}" "workshop_download_item 221100 2222222" "middle mod is downloaded"
assert_contains "${log}" "workshop_download_item 221100 3333333" "last mod is downloaded"
assert_file "${FAKE_HOME}/serverfiles/@test_mod_1111111" "first mod is linked"
assert_file "${FAKE_HOME}/serverfiles/@test_mod_3333333" "last mod is linked"
assert_not_contains "$(cat "${FAKE_HOME}/workshop.cfg")" $'\r' "CRLF is normalised out of workshop.cfg"
cleanup_home

#=======================================================================================#
# Issue #2: a mod that times out on the first attempts must be retried, and a
# partial download must never be mistaken for a successful one.
#=======================================================================================#
start_test "Issue #2 - retry a timing-out mod download"
make_home
echo "2572331007" > "${FAKE_HOME}/workshop.cfg"
STUB_FAIL_UNTIL_ATTEMPT=3 out="$(STUB_FAIL_UNTIL_ATTEMPT=3 run_dayz workshop)"
assert_contains "${out}" "Mod 2572331007 downloaded" "mod succeeds after retries"
assert_eq "$(cat "${STUB_STATE}/attempts_2572331007")" "3" "took exactly 3 attempts"
assert_file "${FAKE_HOME}/serverfiles/@test_mod_2572331007" "mod is linked after a retried download"
cleanup_home

start_test "Issue #2 - a mod that always times out is reported as failed"
make_home
echo "2572331007 DayZ-Expansion-Bundle" > "${FAKE_HOME}/workshop.cfg"
out="$(STUB_ALWAYS_TIMEOUT=1 run_dayz workshop)"
rc=$?
assert_contains "${out}" "could not be downloaded" "failure is reported"
assert_not_contains "${out}" "All workshop mods are ready" "does not claim success"
# A partial download leaves files behind; the script must not treat that as done.
assert_no_file "${FAKE_HOME}/serverfiles/@dayz-expansion-bundle" "no symlink for a failed download"
assert_contains "$(cat "${FAKE_HOME}/workshop.cfg")" "DayZ-Expansion-Bundle" "existing mod name is preserved on failure"
assert_not_contains "$(cat "${FAKE_HOME}/workshop.cfg")" "Unknown" "name is not overwritten with Unknown"
cleanup_home

#=======================================================================================#
start_test "Mod names with spaces and capitals become safe symlink names"
make_home
echo "4444444" > "${FAKE_HOME}/workshop.cfg"
out="$(STUB_MOD_NAME_4444444="Cool Mod Pack" run_dayz workshop)"
assert_file "${FAKE_HOME}/serverfiles/@cool_mod_pack" "spaces become underscores, name lowercased"
cleanup_home

start_test "Mod keys are copied into serverfiles/keys"
make_home
echo "5555555" > "${FAKE_HOME}/workshop.cfg"
out="$(run_dayz workshop)"
assert_file "${FAKE_HOME}/serverfiles/keys/5555555.bikey" "mod bikey copied to the server keys folder"
cleanup_home

#=======================================================================================#
start_test "updateconfig rebuilds the workshop= launch line"
make_home
printf '6666666\n7777777\n' > "${FAKE_HOME}/workshop.cfg"
out="$(STUB_MOD_NAME_6666666="Alpha Mod" STUB_MOD_NAME_7777777="Beta" run_dayz workshop)"
out="$(run_dayz updateconfig)"
cfg="$(cat "${FAKE_HOME}/config.ini")"
assert_contains "${cfg}" 'workshop="@alpha_mod;@beta"' "workshop= line is generated in mod order"
assert_eq "$(grep -c '^workshop=' "${FAKE_HOME}/config.ini")" "1" "only one workshop= line exists"
cleanup_home

start_test "updateconfig skips mods that are not installed"
make_home
printf '8888888 Ghost Mod\n' > "${FAKE_HOME}/workshop.cfg"
out="$(run_dayz updateconfig)"
assert_contains "${out}" "is not installed" "uninstalled mod is skipped, not silently included"
assert_contains "$(cat "${FAKE_HOME}/config.ini")" 'workshop=""' "launch line is empty rather than wrong"
cleanup_home

#=======================================================================================#
start_test "mods add / list / remove"
make_home
out="$(run_dayz mods add 1234567890)"
assert_contains "${out}" "Added mod 1234567890" "bare id is added"
out="$(run_dayz mods add "https://steamcommunity.com/sharedfiles/filedetails/?id=9876543210")"
assert_contains "${out}" "Added mod 9876543210" "id is extracted from a workshop URL"
out="$(run_dayz mods add 1234567890)"
assert_contains "${out}" "already listed" "duplicate is refused"
out="$(run_dayz mods list)"
assert_contains "${out}" "1234567890" "list shows the added mod"
out="$(run_dayz mods remove 1234567890)"
assert_not_contains "$(cat "${FAKE_HOME}/workshop.cfg")" "1234567890" "removed mod is gone from workshop.cfg"
assert_contains "$(cat "${FAKE_HOME}/workshop.cfg")" "9876543210" "the other mod is untouched"
cleanup_home

#=======================================================================================#
start_test "status output"
make_home
out="$(run_dayz status)"
assert_contains "${out}" "stopped" "reports a stopped server"
json="$(run_dayz status --json | tail -n1)"
if printf '%s' "${json}" | jq . >/dev/null 2>&1; then ok "status --json emits valid JSON"; else no "status --json emits valid JSON" "${json}"; fi
assert_eq "$(printf '%s' "${json}" | jq -r '.running')" "false" "JSON running is false"
assert_eq "$(printf '%s' "${json}" | jq -r '.port')" "2301" "JSON reports the game port"
cleanup_home

#=======================================================================================#
start_test "Exit codes"
make_home
run_dayz status > /dev/null 2>&1
assert_eq "$?" "0" "a successful command exits 0"
run_dayz workshop > /dev/null 2>&1
assert_eq "$?" "0" "workshop with no mods exits 0"
run_dayz definitelynotacommand > /dev/null 2>&1
rc=$?
if [ "${rc}" -ne 0 ]; then ok "an unknown command exits non-zero"; else no "an unknown command exits non-zero"; fi
run_dayz version > /dev/null 2>&1
assert_eq "$?" "0" "version exits 0"
cleanup_home

#=======================================================================================#
start_test "Crash dumps survive a log clear"
make_home
touch "${FAKE_HOME}/serverprofile/crash.mdmp" "${FAKE_HOME}/serverprofile/old.RPT"
out="$(run_dayz start)"
assert_file "${FAKE_HOME}/serverprofile/crash.mdmp" ".mdmp crash dump is kept"
assert_no_file "${FAKE_HOME}/serverprofile/old.RPT" ".RPT is cleared"
cleanup_home

#=======================================================================================#
start_test "Backup does not recurse and honours retention"
make_home
out="$(run_dayz backup)"
assert_contains "${out}" "Backing up mission folder" "mission folder is archived"
if ls "${FAKE_HOME}/backup/"*.tar >/dev/null 2>&1; then ok "a tar archive is produced"; else no "a tar archive is produced"; fi
# An old archive must be removed by the retention sweep.
touch -d "10 days ago" "${FAKE_HOME}/backup/old-archive.tar" 2>/dev/null
out="$(run_dayz backup)"
assert_no_file "${FAKE_HOME}/backup/old-archive.tar" "archive older than the retention window is deleted"
cleanup_home

#=======================================================================================#
start_test "Config options added in a later version get defaults"
make_home
# A config.ini written by v1 knows nothing about workshop_retries; the script
# must supply a default rather than passing an empty value to seq.
cat > "${FAKE_HOME}/config.ini" <<'OLD'
appid=223350
dayz_id=221100
port=2301
steamlogin=testuser
config=serverDZ.cfg
dayzparameter=" -config=serverDZ.cfg -port=2301"
OLD
echo "1212121" > "${FAKE_HOME}/workshop.cfg"
out="$(run_dayz workshop)"
assert_contains "${out}" "attempt 1/5" "workshop_retries defaults to 5 for an old config"
assert_file "${FAKE_HOME}/serverfiles/@test_mod_1212121" "an old config.ini still works"
cleanup_home

#=======================================================================================#
start_test "systemd unit generation"
make_home
out="$(run_dayz systemd)"
assert_file "${FAKE_HOME}/.config/systemd/user/dayzserver.service" "server unit written"
assert_file "${FAKE_HOME}/.config/systemd/user/dayzserver-monitor.timer" "monitor timer written"
assert_file "${FAKE_HOME}/.config/systemd/user/dayzserver-checkmods.timer" "checkmods timer written"
assert_contains "$(cat "${FAKE_HOME}/.config/systemd/user/dayzserver.service")" "${FAKE_HOME}/dayzserver.sh start" "unit points at the real script path"
assert_contains "${out}" "enable-linger" "explains the linger requirement"
cleanup_home

#=======================================================================================#
# Web GUI. Starts dayzweb.py against the fake home on a loopback port and
# drives it with curl, asserting on the security properties that matter: the
# API refuses unauthenticated callers, mutating calls need a CSRF token, and
# the listener is bound to loopback only.
#=======================================================================================#
start_test "Web GUI"
if [ ! -f "${REPO_ROOT}/dayzweb.py" ]; then
	no "dayzweb.py exists"
else
	make_home
	cp "${REPO_ROOT}/dayzweb.py" "${FAKE_HOME}/dayzweb.py"
	mkdir -p "${FAKE_HOME}/webui"
	cp "${REPO_ROOT}/webui/index.html" "${FAKE_HOME}/webui/index.html"

	# Pick a free port so parallel runs do not collide.
	WEB_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
	COOKIE_JAR="${FAKE_HOME}/cookies.txt"

	( cd "${FAKE_HOME}" && HOME="${FAKE_HOME}" DAYZ_HOME="${FAKE_HOME}" \
		DAYZ_WEB_BIND=127.0.0.1 DAYZ_WEB_PORT="${WEB_PORT}" DAYZ_ALLOW_ROOT=1 \
		PATH="${FAKE_HOME}/bin:${PATH}" \
		python3 dayzweb.py > "${FAKE_HOME}/web.out" 2>&1 ) &
	WEB_PID=$!

	# Wait for the port to accept connections rather than sleeping blindly.
	for _ in $(seq 1 50); do
		if curl -s -o /dev/null "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then break; fi
		sleep 0.2
	done

	if kill -0 "${WEB_PID}" 2>/dev/null; then
		ok "web GUI starts"

		# The generated password is printed once on first run.
		WEB_PASS="$(grep -A2 'password has been generated' "${FAKE_HOME}/web.out" | tail -n1 | tr -d ' ')"
		if [ -n "${WEB_PASS}" ]; then ok "a password is generated on first run"; else no "a password is generated on first run"; fi
		assert_contains "$(cat "${FAKE_HOME}/config.ini")" "web_password_hash" "the hash is stored in config.ini"
		assert_not_contains "$(cat "${FAKE_HOME}/config.ini")" "${WEB_PASS}" "the plaintext password is NOT stored"

		code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/api/status")"
		assert_eq "${code}" "401" "unauthenticated API access is refused"

		code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
			-H 'Content-Type: application/json' -d '{"action":"stop"}' \
			"http://127.0.0.1:${WEB_PORT}/api/control")"
		assert_eq "${code}" "401" "unauthenticated control requests are refused"

		body="$(curl -s -c "${COOKIE_JAR}" -X POST -H 'Content-Type: application/json' \
			-d '{"password":"definitely-wrong"}' "http://127.0.0.1:${WEB_PORT}/api/login")"
		assert_contains "${body}" "Incorrect password" "a wrong password is rejected"

		body="$(curl -s -c "${COOKIE_JAR}" -X POST -H 'Content-Type: application/json' \
			-d "{\"password\":\"${WEB_PASS}\"}" "http://127.0.0.1:${WEB_PORT}/api/login")"
		CSRF="$(printf '%s' "${body}" | jq -r '.csrf // empty')"
		if [ -n "${CSRF}" ]; then ok "login with the correct password succeeds"; else no "login with the correct password succeeds" "${body}"; fi

		body="$(curl -s -b "${COOKIE_JAR}" "http://127.0.0.1:${WEB_PORT}/api/status")"
		assert_eq "$(printf '%s' "${body}" | jq -r '.running')" "false" "authenticated status matches the CLI"

		# A valid session but no CSRF token must still be refused.
		code="$(curl -s -o /dev/null -w '%{http_code}' -b "${COOKIE_JAR}" -X POST \
			-H 'Content-Type: application/json' -d '{"action":"checkmods"}' \
			"http://127.0.0.1:${WEB_PORT}/api/control")"
		assert_eq "${code}" "403" "a mutating request without a CSRF token is refused"

		code="$(curl -s -o /dev/null -w '%{http_code}' -b "${COOKIE_JAR}" -X POST \
			-H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF}" \
			-d '{"action":"rm -rf /"}' "http://127.0.0.1:${WEB_PORT}/api/control")"
		assert_eq "${code}" "400" "an action outside the allowlist is refused"

		body="$(curl -s -b "${COOKIE_JAR}" -X POST -H 'Content-Type: application/json' \
			-H "X-CSRF-Token: ${CSRF}" -d '{"action":"add","value":"1234567890"}' \
			"http://127.0.0.1:${WEB_PORT}/api/mods")"
		assert_contains "$(cat "${FAKE_HOME}/workshop.cfg")" "1234567890" "a mod can be added through the API"

		# steamlogin must never reach the browser.
		body="$(curl -s -b "${COOKIE_JAR}" "http://127.0.0.1:${WEB_PORT}/api/config?file=config.ini")"
		assert_not_contains "${body}" "testuser" "steamlogin is redacted from config.ini"
		assert_contains "${body}" "********" "secrets are shown as placeholders"

		body="$(curl -s -b "${COOKIE_JAR}" "http://127.0.0.1:${WEB_PORT}/api/config?file=/etc/passwd")"
		assert_contains "${body}" "unknown file" "an arbitrary path cannot be read"

		body="$(curl -s "http://127.0.0.1:${WEB_PORT}/")"
		assert_contains "${body}" "DayZ Server Manager" "the UI page is served"
		assert_not_contains "${body}" "https://cdn" "the page loads nothing from a CDN"

		# Bound to loopback only, so it is not exposed by default.
		if command -v ss >/dev/null 2>&1; then
			listen="$(ss -ltnH "sport = :${WEB_PORT}" 2>/dev/null)"
			assert_contains "${listen}" "127.0.0.1:${WEB_PORT}" "listener is bound to 127.0.0.1 only"
		fi

		kill "${WEB_PID}" 2>/dev/null
		wait "${WEB_PID}" 2>/dev/null
	else
		no "web GUI starts" "$(cat "${FAKE_HOME}/web.out")"
	fi
	cleanup_home
fi

#=======================================================================================#
printf "\n"
if [ "${fail}" -eq 0 ]; then
	printf "${green}All %s checks passed.${default}\n" "${pass}"
	exit 0
fi
printf "${red}%s of %s checks failed.${default}\n" "${fail}" "$(( pass + fail ))"
exit 1
