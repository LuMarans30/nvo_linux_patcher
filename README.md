# NVO on Linux

The `nvo_linux_patcher.sh` script patches the New Vegas Online (NVO) launcher to work on Linux via Wine.

> [!CAUTION]
> Proceed at your own risk.

## Requirements

- Wine
  - the script uses it to execute registry edits and run 7-Zip inside the prefix
  - optional for Steam/Proton installs, where `protontricks` is used instead when Wine isn't installed
- A 64-bit (win64) Wine prefix
- `curl` or `wget`, `unzip`, `base64`, and `file`.
- A Fallout New Vegas installation (patched with [FNV4GB for Linux](https://www.nexusmods.com/newvegas/mods/62552?tab=files)).
  
`winetricks` (or `protontricks` for Steam/Proton installs) is used if present but is optional (7-Zip is downloaded otherwise).

## Usage

1. Clone the repository and make the script executable:
   
```bash
git clone https://github.com/LuMarans30/nvo_linux_patcher.git
cd nvo_linux_patcher
chmod +x nvo_linux_patcher.sh
```

If you'd rather not clone, the script is self-contained:

```bash
curl -fsSLO https://raw.githubusercontent.com/LuMarans30/nvo_linux_patcher/main/nvo_linux_patcher.sh
chmod +x nvo_linux_patcher.sh
```

2. Run the script with your Wine prefix (it automatically finds the game):
   
```bash
./nvo_linux_patcher.sh --prefix "/path/to/wineprefix"
# or
WINEPREFIX="/path/to/wineprefix" ./nvo_linux_patcher.sh
```
You can also `cd` into the game folder and run `/path/to/nvo_linux_patcher.sh` (the wine prefix will be automatically detected). Copying the script into the game folder is not required.

3. Start the launcher:
   
```bash
WINEPREFIX="/path/to/wineprefix" wine "/path/to/Fallout New Vegas/NVOLauncher2.exe"
```

### Steam / Proton

Steam installs keep the game outside the prefix, so the script detects them automatically by reading your Steam libraries (native, Flatpak, and Snap roots, plus extra libraries from `libraryfolders.vdf`):

```bash
./nvo_linux_patcher.sh
```

It looks for `steamapps/common/Fallout New Vegas` and the matching Proton prefix
`steamapps/compatdata/22380/pfx`. If your setup lives elsewhere, pass both paths explicitly:

```bash
./nvo_linux_patcher.sh \
  --game-dir "$HOME/.local/share/Steam/steamapps/common/Fallout New Vegas" \
  --prefix   "$HOME/.local/share/Steam/steamapps/compatdata/22380/pfx"
```

Launch the game with Proton (not Wine):

```bash
protontricks-launch --appid 22380 "$HOME/.local/share/Steam/steamapps/common/Fallout New Vegas/NVOLauncher2.exe"
```

If you don't have `protontricks`, add `NVOLauncher2.exe` as a non-Steam game and
launch it with the same Proton version as Fallout: New Vegas.

> [!NOTE]
> Your Proton prefix is modified in place. Back it up first if you want.

> [!WARNING]
> Steam's "Verify integrity of game files" feature restores any Steam-managed files the patch overwrote (e.g. `FalloutNV.exe`).
> If you verify, re-apply the FNV4GB patch first, then re-run this script

## Build from source

> [!IMPORTANT]
> The `tar.exe` shim binary is already embedded as base64 inside `nvo_linux_patcher.sh`, so manual compilation is not required.

In case you prefer compiling `nvo_tar_shim.c` from source yourself, you can use the `build_shim.sh` script, which both compiles the C file and embeds the binary in `nvo_linux_patcher.sh`.