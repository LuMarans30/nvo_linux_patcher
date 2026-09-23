#!/usr/bin/env bash
# =============================================================================
#  New Vegas Online (NVO) on Linux / Wine
# =============================================================================
#
#  Sets up the pieces the NVO launcher needs that Wine doesn't provide:
#
#    1. A tar.exe shim (the launcher shells out to a Windows tar.exe).
#    2. 7-Zip in the prefix (the shim forwards to it).
#    3. The NVO launcher files (v1.15.0).
#    4. The NVO content pack, with the 32-bit game libraries left in the game
#       folder and the 64-bit launcher libraries copied into system32.
#    5. The latest xNVSE.
#    6. DSOAL + OpenAL Soft, forced over Wine's DirectSound.
#
#  It also checks that FalloutNV.exe is 4GB/LAA patched, and points you at the
#  Nexus "FNV4GB for Linux" patch if it isn't.
#
#  Usage:  run it with the Wine prefix to patch (found by walking up from
#          the current directory); the game folder is found in that prefix:
#     chmod +x nvo_linux_patcher.sh
#     ./nvo_linux_patcher.sh
#     WINEPREFIX=~/Games/fallout ./nvo_linux_patcher.sh   # or --prefix; else prompts
#     ./nvo_linux_patcher.sh --game-dir "/path/to/Fallout New Vegas"
#     ./nvo_linux_patcher.sh --no-content                 # skip the ~660 MB pack
#
#  Requires: wine, curl (or wget), unzip, base64.  A 64-bit ("win64") prefix.
#
#  Author:  LuMarans30
#  Source:  https://github.com/LuMarans30/nvo_linux_patcher
# =============================================================================

set -euo pipefail

# ------------------------------- options ------------------------------------
WINEPREFIX="${WINEPREFIX:-}"
GAMEDIR="${GAMEDIR:-}" # found in the prefix if not given
FETCH_CONTENT=1
backed_up=0

NVO_BASE="https://nvo.newvegasonline.com/downloads"
LAUNCHER_URL="$NVO_BASE/NVOLauncher_Update.zip"
CONTENT_URL="$NVO_BASE/NVO_1.zip"
# xNVSE fallback if the GitHub API is unreachable.
XNVSE_VER="6.4.9"
XNVSE_URL="https://github.com/xNVSE/NVSE/releases/download/${XNVSE_VER}/nvse_${XNVSE_VER//./_}.7z"
DSOAL_VER="r695"
DSOAL_URL="https://github.com/kcat/dsoal/releases/download/archive/DSOAL_r695.zip"

while [ $# -gt 0 ]; do
	case "$1" in
	--no-content) FETCH_CONTENT=0 ;;
	--prefix)
		WINEPREFIX="${2:?}"
		shift
		;;
	--game-dir)
		GAMEDIR="${2:?}"
		shift
		;;
	-h | --help)
		awk 'NR>1 && /^set -euo pipefail$/{exit} NR>1{print}' "$0" | sed '$d'
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 2
		;;
	esac
	shift
done

# ------------------------------- helpers ------------------------------------
c_reset='\033[0m'
c_ok='\033[1;32m'
c_info='\033[1;34m'
c_warn='\033[1;33m'
c_err='\033[1;31m'
step() { printf "${c_info}==>${c_reset} %s\n" "$*"; }
ok() { printf "${c_ok}  ok${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}  !!${c_reset} %s\n" "$*" >&2; }
die() {
	printf "${c_err}  xx${c_reset} %s\n" "$*" >&2
	exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
is_game_dir() { [ -n "${1:-}" ] && [ -f "$1/FalloutNV.exe" ]; }
# Wine prefix enclosing the current directory: walk up only, never down.
enclosing_prefix() {
	local d
	d="$(pwd -P)"
	while :; do
		if [ -f "$d/system.reg" ] && [ -d "$d/drive_c" ]; then
			printf '%s\n' "$d"
			return 0
		fi
		[ "$d" = "/" ] && return 1
		d="$(dirname "$d")"
	done
}

# True if the exe has IMAGE_FILE_LARGE_ADDRESS_AWARE (0x20) set in its PE header.
is_laa_patched() {
	local exe="$1" off chars
	[ -f "$exe" ] || return 1
	off="$(od -An -tu4 -j60 -N4 "$exe" 2>/dev/null | tr -d '[:space:]')"
	[ -n "$off" ] || return 1
	chars="$(od -An -tu2 -j"$((off + 22))" -N2 "$exe" 2>/dev/null | tr -d '[:space:]')"
	[ -n "$chars" ] && [ $((chars & 0x20)) -ne 0 ]
}

# Copy a file we're about to overwrite into $BACKUP/<sub>/, keeping the first copy so re-runs never clobber the original.
backup_file() { # src sub [relpath]
	local src="$1" sub="${2:-root}" rel="${3:-$(basename "$1")}" dst
	[ -f "$src" ] || return 0
	rel="${rel//\\//}"                                    # normalise separators
	rel="${rel#/}"                                        # never absolute
	case "$rel" in *..*) rel="$(basename "$rel")" ;; esac # never escapes $BACKUP
	dst="$BACKUP/$sub/$rel"
	[ -e "$dst" ] && return 0
	mkdir -p "$(dirname "$dst")"
	cp -a "$src" "$dst"
	backed_up=$((backed_up + 1))
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Find the wine binary (some distros only ship wine64).
if have wine; then
	WINE=wine
elif have wine64; then
	WINE=wine64
else die "wine not found in PATH."; fi
w_run() { WINEPREFIX="$WINEPREFIX" "$WINE" "$@"; }

# host path -> Z:\... (Z: maps to / in Wine)
to_win() {
	local p
	p="$(realpath "$1")"
	printf 'Z:%s' "${p//\//\\}"
}

download() { # url dest
	local url="$1" dest="$2"
	if have curl; then
		curl -fL --retry 3 --progress-bar -o "$dest" "$url"
	elif have wget; then
		wget --show-progress -O "$dest" "$url"
	else die "Need curl or wget to download files."; fi
}

# Body of a URL on stdout, empty if it can't be fetched (never fails).
fetch() { # url
	{ have curl && curl -fsSL "$1"; } || { have wget && wget -qO- "$1"; } || true
}

# browser_download_url values from a GitHub release JSON whose filename matches
# the given ERE (e.g. 'nvse_[0-9_]+\.7z').
github_asset_urls() { # json filename-ere
	printf '%s' "$1" |
		grep -oE "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]+/$2\"" |
		sed -E 's/.*"(http[^"]+)".*/\1/'
}

# Newest xNVSE via the GitHub API; falls back to the pinned XNVSE_* above.
resolve_xnvse() {
	local json tag url
	json="$(fetch "https://api.github.com/repos/xNVSE/NVSE/releases/latest")"
	[ -n "$json" ] || return 0
	tag="$(printf '%s' "$json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' |
		head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
	url="$(github_asset_urls "$json" 'nvse_[0-9_]+\.7z' | head -1)"
	if [ -n "$tag" ] && [ -n "$url" ]; then
		XNVSE_VER="$tag"
		XNVSE_URL="$url"
	fi
}

# Newest DSOAL build via the GitHub API. Falls back to the pinned DSOAL_* above.
resolve_dsoal() {
	local json url rev best_url="" best_rev=-1
	json="$(fetch "https://api.github.com/repos/kcat/dsoal/releases?per_page=100")"
	[ -n "$json" ] || return 0
	while IFS= read -r url; do
		rev="$(printf '%s' "$url" | sed -nE 's#.*/DSOAL_r([0-9]+)\.zip$#\1#p')"
		[ -n "$rev" ] || continue
		if [ "$rev" -gt "$best_rev" ]; then
			best_rev="$rev"
			best_url="$url"
		fi
	done < <(github_asset_urls "$json" 'DSOAL_r[0-9]+\.zip')
	if [ -n "$best_url" ]; then
		DSOAL_VER="r$best_rev"
		DSOAL_URL="$best_url"
	fi
}

find_7z() {
	local p
	for p in \
		"$WINEPREFIX/drive_c/Program Files/7-Zip/7z.exe" \
		"$WINEPREFIX/drive_c/Program Files (x86)/7-Zip/7z.exe"; do
		[ -f "$p" ] && {
			printf '%s' "$p"
			return 0
		}
	done
	# Custom install dir: fall back to the first 7z.exe anywhere in the prefix.
	p="$(find "$WINEPREFIX/drive_c" -maxdepth 6 -type f -iname '7z.exe' -print -quit 2>/dev/null || true)"
	[ -n "$p" ] && {
		printf '%s' "$p"
		return 0
	}
	return 1
}

# Wait up to $1 seconds for 7z.exe to appear.
wait_for_7z() {
	local deadline
	deadline=$((SECONDS + $1))
	while :; do
		if find_7z; then
			return 0
		fi
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 1
	done
}

# The tar shim only probes the standard 7-Zip directories (plus PATH), so if the
# script located 7-Zip elsewhere, mirror it into the standard dir the shim uses.
# 7z.exe links 7z.dll, so the whole folder is copied, not just the exe.
stage_7z() { # path-to-7z.exe
	local src dst
	src="$(dirname "$1")"
	dst="$WINEPREFIX/drive_c/Program Files/7-Zip"
	mkdir -p "$dst"
	cp -a "$src/." "$dst/"
	printf '%s' "$dst/7z.exe"
}

# --------------------------- resolve wine prefix ----------------------------
# Precedence: --prefix > $WINEPREFIX > enclosing prefix > prompt.
if [ -z "$WINEPREFIX" ]; then
	if WINEPREFIX="$(enclosing_prefix)"; then
		printf "${c_info}Detected Wine prefix:${c_reset} %s\n" "$WINEPREFIX" >&2
	elif [ -t 0 ] && [ -t 2 ]; then
		while :; do
			printf '%b' "${c_info}Wine prefix not set.${c_reset} Enter the path to your Wine prefix: " >&2
			IFS= read -r reply || die "Aborted."
			[ -n "$reply" ] || {
				warn "A prefix path is required."
				continue
			}
			case "$reply" in "~" | "~/*") reply="$HOME${reply#\~}" ;; esac
			if [ -f "$reply/system.reg" ]; then
				WINEPREFIX="$reply"
				break
			fi
			warn "'$reply' does not look like a Wine prefix (no system.reg)."
		done
	else
		die "No WINEPREFIX set and stdin is not a terminal. Set WINEPREFIX or use --prefix."
	fi
fi
export WINEPREFIX

# --------------------------- resolve game dir -------------------------------
# Precedence: --game-dir > an install found inside the selected prefix >
# the current directory > interactive prompt.
find_game_dirs() {
	find "$WINEPREFIX/drive_c" -maxdepth 8 \
		\( -ipath '*/ModOrganizer' -o -iname 'Data' \) -prune -o \
		-type f -iname 'FalloutNV.exe' -print 2>/dev/null |
		while IFS= read -r exe; do dirname "$exe"; done
}

if ! is_game_dir "$GAMEDIR"; then
	candidates=()
	while IFS= read -r d; do candidates+=("$d"); done \
		< <(find_game_dirs | sort -u)

	if [ "${#candidates[@]}" -eq 1 ]; then
		GAMEDIR="${candidates[0]}"
	elif [ "${#candidates[@]}" -eq 0 ]; then
		# Nothing in the prefix: try the current directory, else ask.
		if is_game_dir "$PWD"; then
			GAMEDIR="$PWD"
		elif [ -t 0 ] && [ -t 2 ]; then
			while :; do
				printf '%b' "${c_info}No FalloutNV.exe found in '$WINEPREFIX'.${c_reset} Enter the path to your 'Fallout New Vegas' folder: " >&2
				IFS= read -r reply || die "Aborted."
				[ -n "$reply" ] || {
					warn "A path is required."
					continue
				}
				case "$reply" in "~" | "~/*") reply="$HOME${reply#\~}" ;; esac
				if is_game_dir "$reply"; then
					GAMEDIR="$reply"
					break
				fi
				warn "'$reply' does not contain FalloutNV.exe."
			done
		else
			die "No FalloutNV.exe found in '$WINEPREFIX' and stdin is not a terminal."
		fi
	else
		# Several installs: prefer the current directory if it is one of them.
		for d in "${candidates[@]}"; do
			if [ "$d" = "$PWD" ]; then
				GAMEDIR="$PWD"
				break
			fi
		done
		if ! is_game_dir "$GAMEDIR"; then
			if [ -t 0 ] && [ -t 2 ]; then
				printf '%b' "${c_info}Several Fallout New Vegas installs found in the prefix:${c_reset}\n" >&2
				i=0
				for d in "${candidates[@]}"; do
					i=$((i + 1))
					printf '  %2d) %s\n' "$i" "$d" >&2
				done
				while :; do
					printf '%b' "Choose a game folder [1-${#candidates[@]}]: " >&2
					IFS= read -r reply || die "Aborted."
					if [[ "$reply" =~ ^[0-9]+$ ]] &&
						[ "$reply" -ge 1 ] && [ "$reply" -le "${#candidates[@]}" ]; then
						GAMEDIR="${candidates[$((reply - 1))]}"
						break
					fi
					warn "Enter a number between 1 and ${#candidates[@]}."
				done
			else
				die "Several FalloutNV.exe found in '$WINEPREFIX'; pass --game-dir to choose."
			fi
		fi
	fi
fi

# ------------------------------- preflight ----------------------------------
step "Checking requirements"
have base64 || die "base64 not found (install coreutils)."
have unzip || die "unzip not found (install it: e.g. apt install unzip / zypper in unzip)."
have file || die "the 'file' utility is required (install it: e.g. apt install file / zypper in file)."
have curl || have wget || die "Need curl or wget."
[ -f "$WINEPREFIX/system.reg" ] || die "No Wine prefix at '$WINEPREFIX'. Set WINEPREFIX."
[ -d "$WINEPREFIX/drive_c/windows/syswow64" ] ||
	warn "This does not look like a 64-bit (win64) prefix. The NVO launcher is 64-bit and needs a win64 prefix."

[ -f "$GAMEDIR/FalloutNV.exe" ] || die "FalloutNV.exe not found in '$GAMEDIR'."
[ -w "$GAMEDIR" ] || die "Game folder is not writable: '$GAMEDIR' (GOG installs under Program Files are often read-only)."
ok "Prefix:   $WINEPREFIX"
ok "Game dir: $GAMEDIR"
SYS32="$WINEPREFIX/drive_c/windows/system32"
SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"
BACKUP="$GAMEDIR/nvo-linux-backup"

# --------------------------- 0. 4GB (LAA) patch -----------------------------
step "Checking 4GB (large-address-aware) patch"
if is_laa_patched "$GAMEDIR/FalloutNV.exe"; then
	ok "FalloutNV.exe is 4GB patched"
else
	FOURGB_URL="https://www.nexusmods.com/newvegas/mods/62552?tab=files"
	warn "FalloutNV.exe is not 4GB patched."
	warn 'Download "FNV4GB for Linux" from:'
	warn "  $FOURGB_URL"
	have xdg-open && xdg-open "$FOURGB_URL" >/dev/null 2>&1 || true
	die "Install the patch, then re-run this script."
fi

# --------------------------- 1. 7-Zip (extractor) ---------------------------
step "Ensuring 7-Zip is installed in the prefix"
SEVENZIP="$(find_7z || true)"
if [ -z "$SEVENZIP" ] && have winetricks; then
	WINEPREFIX="$WINEPREFIX" winetricks -q 7zip || true
	SEVENZIP="$(wait_for_7z 20 || true)"
fi
if [ -z "$SEVENZIP" ]; then
	warn "winetricks unavailable/failed; downloading the 7-Zip installer"
	page="$(fetch "https://www.7-zip.org/download.html")"
	ver="$(printf '%s' "$page" | grep -oE '7z[0-9]+-x64\.exe' | sed 's/7z//; s/-x64.exe//' | sort -n | tail -1)"
	[ -n "$ver" ] || ver="2603"
	download "https://www.7-zip.org/a/7z${ver}-x64.exe" "$WORKDIR/7zsetup.exe"
	w_run "$WORKDIR/7zsetup.exe" /S || warn "the 7-Zip installer exited non-zero"
	# /S is synchronous, but let the files settle before giving up.
	SEVENZIP="$(wait_for_7z 60 || true)"
fi
[ -n "$SEVENZIP" ] || die "7-Zip could not be installed. Try: WINEPREFIX='$WINEPREFIX' winetricks 7zip"
w_run "$SEVENZIP" i >/dev/null 2>&1 ||
	die "7-Zip at '$SEVENZIP' is present but failed to run under Wine."
if [ "$SEVENZIP" != "$WINEPREFIX/drive_c/Program Files/7-Zip/7z.exe" ] &&
	[ "$SEVENZIP" != "$WINEPREFIX/drive_c/Program Files (x86)/7-Zip/7z.exe" ]; then
	# Non-standard install: mirror it so the tar shim finds the same 7-Zip.
	warn "7-Zip is outside the standard path; mirroring it for the tar shim"
	SEVENZIP="$(stage_7z "$SEVENZIP")"
	w_run "$SEVENZIP" i >/dev/null 2>&1 ||
		die "mirrored 7-Zip at '$SEVENZIP' failed to run under Wine."
fi
ok "7-Zip: $SEVENZIP"

# The launcher unpacks zips by shelling out to Windows' built-in tar.exe
# (bsdtar), which Wine doesn't ship - hence "Update extraction failed" and
# "Assets decompression error occurred".  This shim forwards to 7-Zip.
# (embedded binary; source = nvo_tar_shim.c, built by build_shim.sh)
# --------------------------- 2. tar.exe shim --------------------------------
step "Installing tar.exe shim (Wine has no Windows tar.exe)"
backup_file "$GAMEDIR/tar.exe" root
backup_file "$SYS32/tar.exe" system32
printf '%s' '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' | base64 -d >"$GAMEDIR/tar.exe"
chmod +x "$GAMEDIR/tar.exe"
cp -f "$GAMEDIR/tar.exe" "$SYS32/tar.exe"
ok "tar.exe -> game dir and system32"

# --------------------------- 3. launcher files ------------------------------
step "Installing NVO launcher files (v1.15.0)"
if [ -f "$GAMEDIR/NVOLauncher2.exe" ]; then
	ok "already present"
else
	download "$LAUNCHER_URL" "$WORKDIR/launcher.zip"
	# back up anything the archive is about to overwrite
	while IFS= read -r f; do
		[ "$f" = imgui.ini ] && continue
		backup_file "$GAMEDIR/$f" root "$f"
	done < <(unzip -Z1 "$WORKDIR/launcher.zip")
	# keep the user's launcher window layout if present
	if [ -f "$GAMEDIR/imgui.ini" ]; then
		unzip -o "$WORKDIR/launcher.zip" -d "$GAMEDIR" -x imgui.ini >/dev/null
	else
		unzip -o "$WORKDIR/launcher.zip" -d "$GAMEDIR" >/dev/null
	fi
	ok "NVOLauncher2.exe + launcher libraries installed"
fi

# --------------------------- 4. content pack --------------------------------
mkdir -p "$GAMEDIR/NVO"
if [ -f "$GAMEDIR/NVO/NVO_1.zip" ]; then
	ok "Content pack already present"
elif [ "$FETCH_CONTENT" = 1 ]; then
	step "Downloading NVO content pack (~660 MB, one time)"
	download "$CONTENT_URL" "$WORKDIR/NVO_1.zip.part"
	mv -f "$WORKDIR/NVO_1.zip.part" "$GAMEDIR/NVO/NVO_1.zip"
	ok "Content pack saved to NVO/NVO_1.zip"
else
	warn "Skipping content pack (--no-content). Re-run without it once you have"
	warn "NVO/NVO_1.zip in the game folder, or the 32-bit libraries won't be installed."
fi

# --------------------------- 5. 32/64-bit lib split -------------------------
step "Splitting 32-bit (game) and 64-bit (launcher) libraries"
# 64-bit launcher libs -> system32, so the launcher keeps finding them while
# the game folder holds the 32-bit ones.  Without the split, the plugin
# NVOPh2.dll fails with "error 126 Module not found".
for f in libcurl.dll zlib1.dll libcrypto-3-x64.dll libssl-3-x64.dll discord_partner_sdk.dll; do
	if [ -f "$GAMEDIR/$f" ] && file "$GAMEDIR/$f" | grep -q 'x86-64'; then
		backup_file "$SYS32/$f" system32
		cp -f "$GAMEDIR/$f" "$SYS32/$f"
	fi
done
# 32-bit game libs -> game folder (unpacked from the content pack)
if [ -f "$GAMEDIR/NVO/NVO_1.zip" ]; then
	backup_file "$GAMEDIR/libcurl.dll" root
	backup_file "$GAMEDIR/zlib1.dll" root
	unzip -o -j "$GAMEDIR/NVO/NVO_1.zip" libcurl.dll zlib1.dll -d "$GAMEDIR" >/dev/null
	if file "$GAMEDIR/libcurl.dll" | grep -q 'Intel i386' &&
		file "$GAMEDIR/zlib1.dll" | grep -q 'Intel i386'; then
		ok "32-bit libcurl.dll + zlib1.dll in the game folder; 64-bit copies in system32"
	else
		warn "Could not extract 32-bit libcurl/zlib1 from the content pack."
	fi
else
	warn "Content pack missing - run the launcher once, then re-run this script."
fi

# --------------------------- 6. xNVSE ---------------------------------------
step "Resolving the latest xNVSE release"
resolve_xnvse
printf '    using xNVSE %s\n' "$XNVSE_VER"
download "$XNVSE_URL" "$WORKDIR/nvse.7z"
while IFS= read -r f; do
	backup_file "$GAMEDIR/$f" root "$f"
done < <(w_run "$SEVENZIP" l -slt "$(to_win "$WORKDIR/nvse.7z")" 2>/dev/null | sed -n 's/^Path = //p')
w_run "$SEVENZIP" x -y -o"$(to_win "$GAMEDIR")" "$(to_win "$WORKDIR/nvse.7z")" >/dev/null
ok "xNVSE $XNVSE_VER installed"

# --------------------------- 7. DSOAL audio ---------------------------------
# Wine's built-in DirectSound divides by zero and crashes during the intro;
# install DSOAL + OpenAL Soft and (section 8) force Wine to use it.
step "Resolving the latest DSOAL + OpenAL Soft release"
resolve_dsoal
printf '    using DSOAL %s\n' "$DSOAL_VER"
download "$DSOAL_URL" "$WORKDIR/DSOAL.zip"
unzip -o "$WORKDIR/DSOAL.zip" -d "$WORKDIR/dsoal_outer" >/dev/null
NESTED="$(find "$WORKDIR/dsoal_outer" -maxdepth 1 -iname 'DSOAL_r*.zip' | head -1)"
[ -n "$NESTED" ] || die "Unexpected DSOAL archive layout."
unzip -o "$NESTED" -d "$WORKDIR/dsoal" >/dev/null
SRC="$(find "$WORKDIR/dsoal" -type d -ipath '*HRTF/Win32' | head -1)"
[ -n "$SRC" ] || SRC="$(find "$WORKDIR/dsoal" -type d -ipath '*Win32' | head -1)"
[ -n "$SRC" ] || die "Could not find Win32 DSOAL files in the archive."
backup_file "$GAMEDIR/dsound.dll" root
backup_file "$GAMEDIR/dsoal-aldrv.dll" root
cp -f "$SRC/dsound.dll" "$SRC/dsoal-aldrv.dll" "$GAMEDIR/"
[ -f "$GAMEDIR/alsoft.ini" ] || cp -f "$SRC/alsoft.ini" "$GAMEDIR/"
# keep the backend in syswow64 too: the launcher may move the game-folder copy
# aside for a session
backup_file "$SYSWOW64/dsoal-aldrv.dll" syswow64
cp -f "$SRC/dsoal-aldrv.dll" "$SYSWOW64/dsoal-aldrv.dll"
ok "DSOAL (HRTF) installed"

# --------------------------- 8. DirectSound override ------------------------
step "Forcing Wine to use DSOAL for the game only"
for app in FalloutNV.exe nvse_loader.exe; do
	w_run reg add "HKCU\\Software\\Wine\\AppDefaults\\$app\\DllOverrides" \
		/v dsound /t REG_SZ /d 'native,builtin' /f >/dev/null
done
# An older version of this script set a prefix-wide override; drop it so other
# games in a shared prefix are left alone.
existing="$(w_run reg query 'HKCU\Software\Wine\DllOverrides' /v dsound 2>/dev/null || true)"
case "$existing" in
*native,builtin*) w_run reg delete 'HKCU\Software\Wine\DllOverrides' /v dsound /f >/dev/null 2>&1 || true ;;
esac
ok 'AppDefaults\{FalloutNV.exe,nvse_loader.exe}  dsound = native,builtin'

# --------------------------- done -------------------------------------------
[ "$backed_up" -eq 0 ] ||
	ok "$backed_up file(s) backed up under $BACKUP"
echo
printf "${c_ok}All set!${c_reset}\n\n"
cat <<EOF
Next steps:
  1. Launch the game through the launcher, e.g.:

       WINEPREFIX="$WINEPREFIX" wine "$GAMEDIR/NVOLauncher2.exe"

  2. In the launcher: log in (Discord/Steam) and press Join.

If the launcher ever reports the content pack/libraries are missing, just
re-run this script - it is safe to run multiple times.
EOF
