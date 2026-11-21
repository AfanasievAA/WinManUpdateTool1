# WinManUpdateTool1 - Windows Manual Offline Update Tool

A self-contained PowerShell + WinForms tool for **scanning, downloading, installing and uninstalling Windows updates manually**, without relying on a working Windows Update service or contacting Microsoft Update / WSUS servers during the scan.

Scanning is performed against a **local `wsusscn2.cab` catalog** via the Windows Update Agent API (`ServerSelection = ssOthers`). Update files are downloaded from direct Microsoft CDN URLs (or from a local WSUS content store) and applied locally with `wusa.exe` / `DISM` / `msiexec`.

<img width="1282" height="942" alt="Снимок" src="https://github.com/user-attachments/assets/d341f404-1dd5-4a3b-a47f-2f9e6f1d86d3" />


## Features

- **Offline scan** - searches for missing updates using a local `wsusscn2.cab`. No WSUS or Microsoft Update connectivity is required for the scan itself.
- **Download** - fetches update files by direct URLs from `DownloadContents` / `BundledUpdates` (Microsoft CDN). Server-side date checks ensure only newer files are re-downloaded.
- **WSUS download mode (optional)** - pull files from a local WSUS content store instead of the Internet CDN, with automatic fallback to the CDN for missing files.
- **Install** - applies packages locally depending on type:
  - `.msu` → `wusa.exe /quiet /norestart`
  - `.cab` → `DISM /Add-Package /IgnoreCheck` after an *Applicable* check
  - `.msi` → `msiexec /qn /norestart`
  - `.exe` → `/q /norestart` (`ndp*`, `ofv*`, `2553065`) or `/q /z`
- **Uninstall** - `wusa.exe /uninstall /kb:N` and `DISM /Remove-Package` for `Package_for_*` service packages that `wusa` usually cannot remove on Windows 10/11.
- **Audit trail** - every installation is appended to `install-state.json`.
- **Portable** - works from any folder; falls back to `%ProgramData%` / `%LOCALAPPDATA%` if the script folder is read-only.

---

## Requirements

- **Windows 10 / 11**
- **Windows PowerShell 5.1** (built into the OS)
- **Internet access** on first run - to fetch `wsusscn2.cab` (400-600 MB) unless a local copy or a share path is provided
- **Administrator rights** - required for install / uninstall. Scan and download work for any user.
- **STA thread** - the script relaunches itself with `-STA` automatically if started otherwise.

---

## Quick start

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
