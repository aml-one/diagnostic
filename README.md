# AmL Diagnostic

In-house Flutter tool for Android ANR and performance diagnosis
(Windows now; macOS and Linux targets are scaffolded).

Not a store app — never AmL One, never public downloads.

Pull a bugreport or ANR traces over **adb**, unzip them locally, and send
summaries to DeepSeek. Open traces in Perfetto when you need the timeline.

## Requirements

- Windows 10/11 (primary), or macOS Big Sur 11.7.11 or later on Intel / any later macOS on Apple Silicon, or Ubuntu when building those targets
- A DeepSeek API key, entered once in **Settings** (OS credential store —
  never committed to this repo)
- **adb is bundled** — you do **not** need Android Studio on PATH

### Bundled platform-tools

```powershell
.\scripts\fetch-platform-tools.ps1        # once after clone
.\scripts\fetch-platform-tools.ps1 -Force # refresh
```

Binaries live under `third_party/platform-tools/{windows,darwin,linux}/` and
are copied next to the app on build (`platform-tools/adb[.exe]`).

Resolution order at runtime:

1. `AML_ADB` or `ADB` env override  
2. Bundled `<exeDir>/platform-tools/adb`  
3. PATH  
4. `ANDROID_HOME` / `ANDROID_SDK_ROOT`

## Run

```powershell
Set-Location C:\Users\ambru\source\repos\aml-systems\diagnostic
.\scripts\fetch-platform-tools.ps1
flutter pub get
flutter run -d windows
```

## Use

1. Plug in an Android phone with USB debugging enabled and allow this PC.
2. On Home, pick the device, then **Pick app** to choose the package to watch.
3. **Watch logcat** to stream PID-scoped logs and catch ANRs live, or open
   **Diagnose** to pull a bugreport, parse ANR traces, capture a short
   Perfetto trace, and assemble a report.
4. On the report, **Ask DeepSeek** to summarize the evidence bundle
   (requires the API key from Settings).

## Scope

In-house only. This tool never ships to AmL One, downloads.aml.one, or any
OTA channel — it is a local desktop executable for studio diagnostic use.
