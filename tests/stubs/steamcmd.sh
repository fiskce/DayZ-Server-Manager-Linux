#!/bin/bash
# Fake SteamCMD for the test harness.
#
# Behaviour is driven by environment variables so a single stub can play every
# role a test needs:
#   STUB_FAIL_UNTIL_ATTEMPT  fail a workshop download until the Nth attempt
#   STUB_ALWAYS_TIMEOUT      never succeed at downloading a workshop item
#   STUB_BUILDID             build id reported by app_info_print
# Every invocation is appended to $STUB_LOG so tests can assert on which mods
# were actually requested.

log(){ [ -n "${STUB_LOG}" ] && printf '%s\n' "$*" >> "${STUB_LOG}"; }

install_dir=""
mod_id=""
app_id=""
mode=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        +force_install_dir) install_dir="$2"; shift 2 ;;
        +login)             shift 2 ;;
        +workshop_download_item)
            mode="workshop"; app_id="$2"; mod_id="$3"; shift 3
            # An optional trailing "validate" is consumed by the loop.
            ;;
        +app_update)        mode="app"; app_id="$2"; shift 2 ;;
        +app_info_print)    mode="info"; app_id="$2"; shift 2 ;;
        +app_info_update)   shift 2 ;;
        +quit)              shift ;;
        validate)           shift ;;
        *)                  shift ;;
    esac
done

case "${mode}" in
    workshop)
        log "workshop_download_item ${app_id} ${mod_id}"
        attempt_file="${STUB_STATE:-/tmp}/attempts_${mod_id}"
        attempt=$(( $(cat "${attempt_file}" 2>/dev/null || echo 0) + 1 ))
        echo "${attempt}" > "${attempt_file}"

        target="${install_dir}/steamapps/workshop/content/${app_id}/${mod_id}"

        if [ -n "${STUB_ALWAYS_TIMEOUT}" ]; then
            # A real timeout leaves partial content behind - reproduce that, so
            # the script cannot pass by checking only whether the folder exists.
            mkdir -p "${target}"
            echo "partial" > "${target}/partial.pbo"
            echo "Downloading item ${mod_id} ...ERROR! Timeout downloading item ${mod_id}"
            exit 1
        fi

        if [ -n "${STUB_FAIL_UNTIL_ATTEMPT}" ] && [ "${attempt}" -lt "${STUB_FAIL_UNTIL_ATTEMPT}" ]; then
            mkdir -p "${target}"
            echo "partial" > "${target}/partial.pbo"
            echo "Downloading item ${mod_id} ...ERROR! Timeout downloading item ${mod_id}"
            exit 1
        fi

        mkdir -p "${target}/keys"
        name="$(eval echo "\${STUB_MOD_NAME_${mod_id}:-Test Mod ${mod_id}}")"
        cat > "${target}/meta.cpp" <<META
protocol = 1;
publishedid = ${mod_id};
name = "${name}";
timestamp = 0;
META
        touch "${target}/keys/${mod_id}.bikey"
        echo "Success. Downloaded item ${mod_id} to \"${target}\" (1234 bytes)"
        ;;
    app)
        log "app_update ${app_id}"
        mkdir -p "${install_dir}/steamapps" "${install_dir}/battleye" "${install_dir}/keys"
        touch "${install_dir}/DayZServer"
        chmod +x "${install_dir}/DayZServer"
        cat > "${install_dir}/steamapps/appmanifest_${app_id}.acf" <<ACF
"AppState"
{
	"appid"		"${app_id}"
	"buildid"		"${STUB_BUILDID:-1000}"
}
ACF
        echo "Success! App '${app_id}' fully installed."
        ;;
    info)
        log "app_info_print ${app_id}"
        cat <<INFO
"${app_id}"
{
	"depots"
	{
		"branches"
		{
			"public"
			{
				"buildid"		"${STUB_BUILDID:-1000}"
			}
		}
	}
}
INFO
        ;;
esac
exit 0
