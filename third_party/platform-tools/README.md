# Bundled Android platform-tools (adb)

AmL Diagnostic ships a private copy of Google platform-tools so users do not
need Android Studio or a PATH install of `adb`.

## Fetch

```powershell
.\scripts\fetch-platform-tools.ps1
.\scripts\fetch-platform-tools.ps1 -Force
```

Produces:

```
third_party/platform-tools/
  windows/   adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll + NOTICE.txt
  darwin/    adb + NOTICE.txt
  linux/     adb + NOTICE.txt
```

Those folders are gitignored — always run the fetch script after clone.

## Packaging

| Host | How it lands next to the app |
|------|------------------------------|
| Windows | `windows/CMakeLists.txt` → `<exe>/platform-tools/` |
| Linux | `linux/CMakeLists.txt` → bundle `platform-tools/` |
| macOS | `macos/scripts/copy_platform_tools.sh` (Xcode embed phase) → `Contents/MacOS/platform-tools/` |

## Runtime resolution

1. `AML_ADB` / `ADB` env override  
2. Bundled `platform-tools/adb`  
3. PATH  
4. `ANDROID_HOME` / `ANDROID_SDK_ROOT`

Keep each OS `NOTICE.txt` when shipping.
