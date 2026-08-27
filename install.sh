#!/bin/bash
#=======================================================================================#
#     DayZ Server Manager for Linux - bootstrap installer
#=======================================================================================#
#
# Installs the dependencies, downloads the manager, and hands over to the
# interactive setup.
#
#   curl -fsSL https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main/install.sh | bash
#
# Run it as the user that will own the server (not root). It only writes to
# that user's home directory; the one thing it needs privilege for is
# installing packages, and it asks sudo for exactly that.

set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/main"
FILES=("dayzserver.sh" "dayzweb.py" "webui/index.html")

red="\e[31m"; green="\e[32m"; yellow="\e[33m"; cyan="\e[36m"; bold="\e[1m"; default="\e[0m"

info(){ printf "[ ${cyan}INFO${default} ] %b\n" "$1"; }
good(){ printf "[ ${green}OK${default} ] %b\n" "$1"; }
warn(){ printf "[ ${yellow}WARN${default} ] %b\n" "$1"; }
fail(){ printf "[ ${red}FAIL${default} ] %b\n" "$1"; exit 1; }

printf "\n${bold}DayZ Server Manager for Linux${default} - installer\n\n"

# --- Who are we? --------------------------------------------------------
# Running the game server as root leaves root-owned files everywhere and gives
# a network-facing game server far more privilege than it needs.
if [ "$(id -u)" -eq 0 ]; then
	printf "${red}Do not run this installer as root.${default}\n\n"
	printf "Create a dedicated user first, then run it as that user:\n\n"
	printf "  ${cyan}adduser --disabled-password --gecos \"\" dayz${default}\n"
	printf "  ${cyan}su - dayz${default}\n"
	printf "  ${cyan}curl -fsSL %s/install.sh | bash${default}\n\n" "${REPO_RAW}"
	exit 1
fi

# --- Dependencies -------------------------------------------------------
detect_pkg_manager(){
	if   command -v apt-get &>/dev/null; then echo "apt"
	elif command -v dnf     &>/dev/null; then echo "dnf"
	elif command -v yum     &>/dev/null; then echo "yum"
	elif command -v pacman  &>/dev/null; then echo "pacman"
	elif command -v zypper  &>/dev/null; then echo "zypper"
	else echo "unknown"; fi
}

PKG="$(detect_pkg_manager)"
info "Detected package manager: ${PKG}"

case "${PKG}" in
	apt)    PACKAGES="tmux curl jq wget tar python3 lib32gcc-s1"
	        INSTALL="sudo apt-get update -qq && sudo apt-get install -y" ;;
	dnf)    PACKAGES="tmux curl jq wget tar python3 glibc.i686 libstdc++.i686"
	        INSTALL="sudo dnf install -y" ;;
	yum)    PACKAGES="tmux curl jq wget tar python3 glibc.i686 libstdc++.i686"
	        INSTALL="sudo yum install -y" ;;
	pacman) PACKAGES="tmux curl jq wget tar python lib32-gcc-libs"
	        INSTALL="sudo pacman -S --needed --noconfirm" ;;
	zypper) PACKAGES="tmux curl jq wget tar python3 glibc-32bit libstdc++6-32bit"
	        INSTALL="sudo zypper install -y" ;;
	*)      PACKAGES=""; INSTALL="" ;;
esac

if [ -z "${INSTALL}" ]; then
	warn "Unrecognised distribution. Install these yourself before continuing:"
	printf "    tmux curl jq wget tar python3, and the 32-bit gcc/glibc libraries\n"
else
	# Debian needs i386 enabled before the 32-bit runtime SteamCMD requires is
	# even visible to apt.
	if [ "${PKG}" = "apt" ] && ! dpkg --print-foreign-architectures 2>/dev/null | grep -q i386; then
		info "Enabling the i386 architecture (SteamCMD needs 32-bit libraries)..."
		sudo dpkg --add-architecture i386
	fi
	info "Installing: ${PACKAGES}"
	if ! eval "${INSTALL} ${PACKAGES}"; then
		warn "Package installation reported an error. Continuing - dayzserver.sh will"
		warn "tell you exactly what is still missing."
	else
		good "Dependencies installed."
	fi
fi

# --- Download -----------------------------------------------------------
cd "${HOME}" || fail "Cannot change to ${HOME}"
mkdir -p "${HOME}/webui"

for file in "${FILES[@]}"; do
	# Never clobber a local modification without keeping a copy of it.
	if [ -f "${HOME}/${file}" ]; then
		cp -f "${HOME}/${file}" "${HOME}/${file}.bak.$(date +%Y%m%d-%H%M%S)"
		info "Existing ${file} backed up."
	fi
	info "Downloading ${file}..."
	if ! curl -fsSL "${REPO_RAW}/${file}" -o "${HOME}/${file}"; then
		fail "Could not download ${file}. Check your network connection."
	fi
done

chmod +x "${HOME}/dayzserver.sh"
good "Manager installed in ${HOME}"

# --- Hand over ----------------------------------------------------------
printf "\n${bold}Next${default}\n\n"
printf "  1. ${cyan}./dayzserver.sh setup${default}     configure the server interactively\n"
printf "  2. ${cyan}./dayzserver.sh install${default}   download the DayZ server files\n"
printf "  3. ${cyan}./dayzserver.sh start${default}     start it\n\n"
printf "Optional:\n"
printf "  ${cyan}./dayzserver.sh systemd${default}      run it as a service that survives reboots\n"
printf "  ${cyan}./dayzserver.sh web start${default}    open the web GUI\n\n"

if [ -t 0 ]; then
	read -r -p "Run setup now? [Y/n] " answer
	case "${answer:-Y}" in
		[Yy]*|"") exec "${HOME}/dayzserver.sh" setup ;;
	esac
fi
