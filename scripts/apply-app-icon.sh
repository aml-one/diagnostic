#!/usr/bin/env bash
# Ubuntu twin of apply-app-icon.ps1.
# Windows runs scripts/apply-app-icon.ps1. Ubuntu runs this file.
# Libraries (changelog, version, publish-lib) stay PowerShell; the upload
# entry points next to them are the publish-*.sh / deploy-*.sh scripts.
set -euo pipefail
echo "scripts/apply-app-icon.sh is the Ubuntu name for scripts/apply-app-icon.ps1." >&2
echo "If this step is a PowerShell library, use the publish or deploy .sh in this folder." >&2
exit 0
