#!/usr/bin/env bash
# =============================================================================
#  Rebuild the freestanding tar.exe shim and splice it back into
#  nvo_linux_patcher.sh, which ships the binary inline as base64.
#
#  Toolchain (all x86_64-pc-windows-msvc):
#    * clang
#    * a dlltool     - llvm-dlltool or *-w64-mingw32-dlltool
#    * a PE linker   - lld-link (or a rust-lld, which needs "-flavor link")
#    * kernel32.def  - next to this script; used to build the import library
#
#  Tool discovery can be overridden with: CLANG, DLLTOOL, LLD_LINK, KERNEL32_LIB.
#
#  Usage: ./build_shim.sh
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/nvo_tar_shim.c"
setup="$here/nvo_linux_patcher.sh"
def="$here/kernel32.def"

for f in "$src" "$setup" "$def"; do
	[ -f "$f" ] || {
		echo "missing required file: $f" >&2
		exit 1
	}
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- tools ------------------------------------------------------------------
CLANG="${CLANG:-}"
[ -n "$CLANG" ] || CLANG="$(command -v clang || true)"
[ -n "$CLANG" ] || {
	echo "clang not found (set CLANG=)" >&2
	exit 1
}

DLLTOOL="${DLLTOOL:-}"
if [ -z "$DLLTOOL" ]; then
	for c in llvm-dlltool x86_64-w64-mingw32-dlltool dlltool; do
		if command -v "$c" >/dev/null 2>&1; then
			DLLTOOL="$c"
			break
		fi
	done
fi

# PE linker: prefer a real lld-link, else a rust-lld (needs "-flavor link").
linker=()
if [ -n "${LLD_LINK:-}" ]; then
	linker=("$LLD_LINK")
else
	for c in "$(command -v lld-link 2>/dev/null || true)" \
		/tmp/nvotools/lld-link \
		"$HOME"/.rustup/toolchains/stable-*/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld; do
		[ -n "$c" ] && [ -x "$c" ] || continue
		if "$c" --version >/dev/null 2>&1; then
			linker=("$c")
			break
		fi
	done
fi
[ "${#linker[@]}" -gt 0 ] || {
	echo "lld-link not found (set LLD_LINK=)" >&2
	exit 1
}
case "$(basename "${linker[0]}")" in
lld | rust-lld) linker+=(-flavor link) ;;
esac

# --- kernel32 import library ------------------------------------------------
KERNEL32_LIB="${KERNEL32_LIB:-}"
if [ -z "$KERNEL32_LIB" ] && [ -n "$DLLTOOL" ]; then
	KERNEL32_LIB="$work/kernel32.lib"
	"$DLLTOOL" -m i386:x86-64 -d "$def" -l "$KERNEL32_LIB"
fi
if [ -z "$KERNEL32_LIB" ]; then
	for c in /tmp/nvotools/kernel32.lib "$here/kernel32.lib"; do
		[ -f "$c" ] && {
			KERNEL32_LIB="$c"
			break
		}
	done
fi
[ -n "$KERNEL32_LIB" ] && [ -f "$KERNEL32_LIB" ] || {
	echo "cannot build or find kernel32.lib (set KERNEL32_LIB=)" >&2
	exit 1
}

# --- build ------------------------------------------------------------------
"$CLANG" --target=x86_64-pc-windows-msvc -c "$src" -o "$work/tar_shim.obj" \
	-ffreestanding -fno-stack-protector -mno-stack-arg-probe -fno-builtin -O2

"${linker[@]}" /entry:entry /subsystem:console /nodefaultlib /Brepro \
	"/out:$work/tar.exe" "$work/tar_shim.obj" "$KERNEL32_LIB"

file "$work/tar.exe" | grep -q 'PE32+' || {
	echo "linker did not produce a 64-bit PE" >&2
	exit 1
}

# --- embed ------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || {
	echo "python3 is required to splice the blob into $setup" >&2
	exit 1
}

b64="$(base64 "$work/tar.exe" | tr -d '\n')"
python3 - "$setup" "$b64" <<'PY'
import re
import sys

setup, blob = sys.argv[1], sys.argv[2]
with open(setup, encoding="utf-8") as fh:
    text = fh.read()

# The embedded blob is the single-quoted argument of the decode pipeline.
pattern = re.compile(r"""(printf '%s' ')[A-Za-z0-9+/=]*(' \| base64 -d >"\$GAMEDIR/tar\.exe")""")
text, count = pattern.subn(lambda m: m.group(1) + blob + m.group(2), text)
if count != 1:
    sys.exit(f"error: expected exactly one embedded tar.exe blob, found {count}")

with open(setup, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

printf 'rebuilt tar.exe (%s bytes), sha256 %s\n' \
	"$(wc -c <"$work/tar.exe" | tr -d ' ')" "$(sha256sum "$work/tar.exe" | cut -d' ' -f1)"
printf 'embedded into %s\n' "$setup"
