# AmL Diagnostic

In-house Windows Flutter tool for Android ANR and performance diagnosis.
Not a store app — never AmL One, never public downloads.

Pull a bugreport or ANR traces over **adb**, unzip them locally, and send
summaries to DeepSeek. Open traces in Perfetto when you need the timeline.

## Requirements

- Windows 10/11
- `adb` on `PATH` (Android platform-tools)
- A DeepSeek API key, entered once in **Settings** (stored in Windows
  Credential Manager — never committed to this repo)

## Run

```powershell
Set-Location C:\Users\ambru\source\repos\aml-systems\diagnostic
flutter pub get
flutter run -d windows
```

## Use

1. Plug in an Android phone with USB debugging enabled and allow this PC.
2. On Home, pick the device, then **Pick app** to choose the package to watch.
3. **Watch logcat** to stream PID-scoped logs and catch ANRs live, or open
   **Diagnose** to pull a bugreport, parse ANR traces, capture a short
   Perfetto trace, and assemble a report (stat cards, main-thread stack,
   Perfetto findings, Markdown/JSON export).
4. On the report, **Ask DeepSeek** to summarize the capped evidence bundle
   (requires the API key from Settings) and ask follow-up questions.

## Scope

In-house only. This tool never ships to AmL One, downloads.aml.one, or any
OTA channel — it is a local Windows executable for studio diagnostic use.
