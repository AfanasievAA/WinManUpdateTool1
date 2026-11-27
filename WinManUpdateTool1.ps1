<#
.SYNOPSIS
    Windows Manual Offline Update Tool - manual update install/uninstall manager for Windows (without automatic updates).

.DESCRIPTION
    Self-contained PowerShell tool with a WinForms that does not depend on a working windows update service
      1. Offline scan - searches for missing updates against a local wsusscn2.cab catalog via the Windows Update Agent API (ServerSelection = ssOthers), without contacting WSUS or Microsoft Update servers. Requires administrator rights: the scan registers its offline scan package in the Windows Update service store (HKLM), so the button is disabled without elevation.
      2. Download - fetches update files by direct URLs taken from DownloadContents/BundledUpdates (Microsoft CDN). A file whose name carries the embedded SHA-1 digest (the same digest WSUS keys its content store on) is verified against it: an intact file already on disk is reused as is with no network round-trips (delete the Updates folder or the KB subfolder to force a re-download), a corrupt or truncated one is re-downloaded (up to 3 attempts) and never left on disk; files whose name carries no digest fall back to server-side date checks. Optionally, files can be pulled from a local WSUS server instead (see .PARAMETER WsusServer).
      3. Install - applies packages locally depending on type: .msu via wusa.exe /quiet /norestart; .cab via DISM after an "Applicable" check and /Add-Package /IgnoreCheck; .msi via msiexec /qn /norestart; .exe with "/q /norestart" (ndp*/ofv*/2553065), "/q" with an automatic "/qn /norestart" retry (MSRT kb890830: its package wraps an MSI that rejects the bare /q with 1639) or "/q /z" (other exe installers); non-CBS Office cabs are extracted and their .msp payloads applied via msiexec /p. Exit codes 3010/1641/3017 mean a reboot is required. Note: .msu installation via wusa needs the wuauserv service running (no WSUS connectivity needed), while .cab installation via DISM works even with the update agent disabled.
      4. Uninstall - wusa.exe /uninstall /kb:N and, additionally, DISM /Remove-Package for Package_for_* service packages that wusa usually cannot remove on Windows 10/11.
      5. Cleanup - reclaims disk space after the installed updates are tested: removes superseded components from the WinSxS store via DISM /StartComponentCleanup (the engine behind the Disk Cleanup item "Windows Update Cleanup"; with /ResetBase updates become permanent), clears the Windows Update caches (SoftwareDistribution\Download, Delivery Optimization) and deletes the update files downloaded by this tool (the wsusscn2.cab catalog copy is kept).
      6. Download queue - updates found by the offline scan can be added to a persistent queue (the "Download queue" tab). The queue is saved to download-queue.json in the working folder on every change and on exit, so it travels with the portable project folder. On a computer WITH Internet access the tool can be opened without administrator rights and the whole queue downloaded with one button: the queued items carry their direct file URLs (Microsoft CDN or the configured WSUS source), so no catalog and no scan are needed there - the files land in the same Updates\KB_XXXXXXXX subfolders as a local download would. Copy the folder back to the target computer, run [Scan (offline)] again - the downloaded updates are recognized ("files already downloaded") - and [Install selected]. Downloading the queue never re-fetches files that are already in the Updates folder with a matching SHA-1 checksum; the [Force re-download] button re-fetches the whole queue from scratch and overwrites the existing copies. Note: the offline scan itself needs administrator rights (scan package registration in the Windows Update service store), so the offline computer is used with elevation - the unelevated mode is meant for the online computer's downloads.
    WSUS download mode (optional): a WSUS server stores update files in its content store (IIS virtual directory "Content" -> WSUSContent folder) as Content/<hash[0:2]>/<hash>.<ext>, where the 40-hex <hash> is the SHA1 hash of the file - the same hash that is embedded in the Microsoft CDN file name. When a WSUS source is configured, the tool maps each CDN URL to the matching WSUS content path, probes it (HTTP HEAD or UNC Test-Path), and downloads from there; if a file is missing on the WSUS server (e.g. the update is not approved/downloaded there), the tool falls back to the Internet CDN automatically. The scan itself always remains offline (local wsusscn2.cab).

.PARAMETER WorkDir
    Working folder (catalog copy, Updates subfolder, log file, state file). The tool is portable by default: it uses the folder where the script file itself is located, e.g. C:\Scripts for C:\Scripts\WinManUpdateTool1.ps1. If that folder is not writable, it falls back to C:\ProgramData\WinManUpdateTool1, then to %LOCALAPPDATA%\WinManUpdateTool1.

.PARAMETER CatalogPath
    Path to a ready-made wsusscn2.cab (e.g. a network share \\srv\wsus\wsusscn2.cab). Can also be typed in the GUI later. Resolution order: the given file -> a local copy in the working folder (server date is checked) -> download from go.microsoft.com/fwlink.

.PARAMETER WsusServer
    Optional download source: http://<server>[:8530][/Content] or a UNC path to the WSUS content folder (e.g. \\wsus\wsus$\WSUSContent). Can also be typed in the GUI. Empty (default) = download from the Internet CDN. The GUI value is saved to settings.json in the working folder on exit and restored on the next start; an explicit -WsusServer parameter overrides the saved value.

.PARAMETER NoElevate
    Start without asking for administrator rights: the elevation dialog and the automatic UAC relaunch are skipped and the tool runs with user rights - the download queue and file downloads work, while the offline scan (its scan package registration writes to HKLM), install, uninstall and cleanup stay disabled (they need elevation). Without this switch a dialog at startup offers the choice: Yes - relaunch elevated (UAC prompt), No - continue unelevated.

.PARAMETER AutoElevate
    Legacy switch with no effect: kept for backward compatibility with existing shortcuts. When started with user rights the tool offers the elevation choice in a startup dialog (Yes - relaunch elevated, No - continue unelevated); -NoElevate skips the dialog and always continues unelevated.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"

.EXAMPLE
    # On the computer with Internet access: fill the queue on the offline PC first, then download it here without elevation
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -NoElevate
.NOTES
  Author:         Andrew Afanasiev
  Contacts:       AfanasievAA@yandex.ru
  https://github.com/AfanasievAA/WinManUpdateTool1

    Workflow on the target computer: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected] -> after testing [Cleanup leftovers]. The [Scan + Install] button chains the same sequence into one unattended run: it scans, downloads the files that are still missing and installs everything that stays checked.
    Offline -> online workflow (two computers): on the OFFLINE computer run [Scan (offline)], mark the needed updates and press [Add checked to queue]; close the tool (the queue is saved to download-queue.json in the project folder); move the whole project folder to a computer WITH Internet access; start the tool there WITHOUT elevation (answer "No" in the startup dialog or use -NoElevate); on the "Download queue" tab press [Download queue] - the files land in the Updates subfolder; move the Updates folder (or the whole project folder) back to the target computer; run [Scan (offline)] again - the downloaded updates are recognized as "files already downloaded" - and [Install selected].
    The first run needs Internet access once to fetch wsusscn2.cab (400-600 MB) unless a local copy or a share path is provided.
    The offline scan usually takes 5-40 minutes and cannot be interrupted (a WUA COM limitation).
    Target systems: Windows 10/11, Windows PowerShell 5.1 (built into the OS).
    Install/uninstall/cleanup AND the offline scan need administrator rights (the scan registers its scan package in the Windows Update service store, which writes to HKLM): when started with user rights the tool offers the elevation choice in a startup dialog (Yes - relaunch elevated via UAC, No - continue without elevation, then the scan, install, uninstall and cleanup are disabled while the download queue and file downloads work); -NoElevate skips the dialog and never elevates. The tool restarts itself on an STA thread for the WinForms GUI.
#>
#Requires -Version 5.1
param(
    [string]$WorkDir = '',
    [string]$CatalogPath = '',
    [string]$WsusServer = '',
    [switch]$NoElevate,
    [switch]$AutoElevate
)
$Script:version = '0.8 (26 Nov 2026)'

$ErrorActionPreference = 'Continue'

# --- Constants ---
$script:CatalogUrl = 'https://go.microsoft.com/fwlink/p/?LinkID=74689'   # official redirect to the latest wsusscn2.cab
$script:SearchCriteria = 'IsInstalled=0 and IsHidden=0 and DeploymentAction=*'
$script:CancelMsg = '##OPERATION-CANCELED##'
# installer exit codes used by the worker runspaces (injected via Start-Worker)
$script:ExitRebootRequired = 3010                 # ERROR_SUCCESS_REBOOT_REQUIRED (wusa/DISM/msiexec)
$script:ExitRebootRequiredAlt = 3017              # reboot-required success variant (WU stack)
$script:ExitRebootInitiated = 1641                # ERROR_SUCCESS_REBOOT_INITIATED
$script:ExitAlreadyInstalled = 2359302            # DISM: the package is already present
$script:ExitBadCommandLine = -2147023257          # 0x80070667 = HRESULT_FROM_WIN32(1639 ERROR_BAD_COMMAND_LINE), the msiexec signature
# download source names
$script:SrcInternet = 'Internet'
$script:SrcWsus = 'WSUS'
# worker modes (Start-Worker -Mode ... and the worker dispatcher switch)
$script:ModeGetCatalog = 'GetCatalog'
$script:ModeScan = 'Scan'
$script:ModeDownload = 'Download'
$script:ModeInstall = 'Install'
$script:ModeListInstalled = 'ListInstalled'
$script:ModeUninstall = 'Uninstall'
$script:ModeCleanup = 'Cleanup'
$script:ModeDownloadQueue = 'DownloadQueue'
# registry path for the OS build (CurrentBuild + UBR)
$script:RegOsBuild = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

# --- Administrator rights ---
# Return $true when the current process runs elevated
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Relaunch this script in a fresh host process: -Elevate asks UAC and restarts it elevated, otherwise it only restarts it on a fresh STA thread; the argument line is the same in both cases
function Restart-ScriptHost {
    param([switch]$Elevate)
    $hostExe = 'powershell.exe'
    try { $hostExe = (Get-Process -Id $PID).Path } catch { }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath
    if ($Elevate) { Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $argLine | Out-Null }
    else { Start-Process -FilePath $hostExe -ArgumentList $argLine | Out-Null }
}

# Administrator rights: install/uninstall/cleanup need elevation, while the offline scan, the download queue and file downloads work unelevated. When started with user rights: -NoElevate continues unelevated right away; otherwise a startup dialog asks - Yes relaunches the tool elevated (UAC, WUOT_ELEVATED guards against a relaunch loop should the elevation not stick), No continues without elevation (WUOT_UNELEVATED remembers the "No" across the STA relaunch, which does not forward -NoElevate).
if (-not (Test-IsAdmin) -and -not $env:WUOT_ELEVATED -and -not $env:WUOT_UNELEVATED) {
    $wantElevate = $true
    if ($NoElevate) {
        $wantElevate = $false
        $env:WUOT_UNELEVATED = '1'
    } else {
        try { Add-Type -AssemblyName System.Windows.Forms } catch { }
        try {
            $ans = [System.Windows.Forms.MessageBox]::Show($null, "Start WITH administrator rights?`n`nYes - relaunch elevated (UAC prompt): full functionality - offline scan, install, uninstall, cleanup.`nNo - continue WITHOUT elevation: the download queue and file downloads work; the offline scan (needs elevation - it registers a scan package in the Windows Update service store), install, uninstall and cleanup are disabled.`n`n(The -NoElevate switch skips this dialog.)", 'WU Offline Tool', 'YesNo', 'Question', [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
            if ($ans -eq [System.Windows.Forms.DialogResult]::No) {
                $wantElevate = $false
                $env:WUOT_UNELEVATED = '1'
            }
        } catch {
            # no interactive desktop available - keep the legacy behavior (auto-elevate)
        }
    }
    if ($wantElevate) {
        $env:WUOT_ELEVATED = '1'
        try {
            Restart-ScriptHost -Elevate
            return
        } catch {
            Write-Warning ('Elevated launch was canceled or failed: {0} - continuing without elevation.' -f $_.Exception.Message)
        }
    }
}

# Relaunch on a fresh STA thread when the host thread is not STA (WinForms requirement), once; a child of an elevated process stays elevated, so this restart does not lose the elevation
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA -and -not $env:WUOT_NOSTA) {
    $env:WUOT_NOSTA = '1'
    try {
        Restart-ScriptHost
        return
    } catch {
        Write-Warning ('Failed to relaunch with -STA, continuing on the current thread: {0}' -f $_.Exception.Message)
    }
}

# Resolve the working folder: portable by default (script folder), with read-only fallbacks
$script:WorkDir = $null
$candidates = New-Object 'System.Collections.Generic.List[string]'
if ($WorkDir -and $WorkDir.Trim() -ne '') { $candidates.Add($WorkDir.Trim()) }
elseif ($PSScriptRoot) { $candidates.Add($PSScriptRoot) }
$candidates.Add((Join-Path $env:ProgramData 'WinManUpdateTool1'))
$candidates.Add((Join-Path $env:LOCALAPPDATA 'WinManUpdateTool1'))
foreach ($cand in $candidates) {
    try {
        [void](New-Item -ItemType Directory -Path (Join-Path $cand 'Updates') -Force -ErrorAction Stop)
        $script:WorkDir = $cand
        break
    } catch { }
}
if (-not $script:WorkDir) { throw 'Cannot create a writable working folder (tried the script folder, ProgramData and LOCALAPPDATA).' }
$script:PortableMode = ($script:WorkDir -eq $PSScriptRoot)
$script:LogFile = Join-Path $script:WorkDir 'WinManUpdateTool1.log'
$script:SettingsFile = Join-Path $script:WorkDir 'settings.json'
$script:QueueFile = Join-Path $script:WorkDir 'download-queue.json'

# --- User settings (settings.json in the working folder) ---
function Get-SavedSettings {
    $s = @{}
    try {
        if (Test-Path -LiteralPath $script:SettingsFile -PathType Leaf) {
            $obj = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $s[$p.Name] = [string]$p.Value }
        }
    } catch { }
    return $s
}
# Save settings to settings.json, merged over the current file content
function Save-Settings {
    param([hashtable]$Values)
    try {
        $s = Get-SavedSettings
        foreach ($key in $Values.Keys) { $s[$key] = $Values[$key] }
        ConvertTo-Json -InputObject $s -Depth 4 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {
        Add-GuiLog ('Failed to save settings.json: {0}' -f $_.Exception.Message)
    }
}
# An explicit -WsusServer parameter wins; otherwise restore the saved value
$script:SavedSettings = Get-SavedSettings
if ([string]::IsNullOrWhiteSpace($WsusServer) -and $script:SavedSettings.ContainsKey('wsusServer')) { $WsusServer = [string]$script:SavedSettings['wsusServer'] }

# State shared with the background runspace
$script:sync = [hashtable]::Synchronized(@{})
$script:sync.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:sync.ItemStatus = [hashtable]::Synchronized(@{})
$script:sync.Cancel = $false
$script:sync.Busy = $false
$script:sync.Status = ''
$script:sync.Progress = -1
$script:sync.ProgressText = ''
$script:sync.ScanDone = $false
$script:sync.InstalledDone = $false
$script:sync.UninstallDone = $false
$script:sync.QueueDlDone = $false
$script:sync.RebootNeeded = $false
$script:sync.Result = @()
$script:sync.InstalledList = @()
$script:sync.InstalledOk = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

$script:IsAdmin = Test-IsAdmin
$script:HaveScanResults = $false
$script:HaveInstalledList = $false
$script:ItemMap = @{}
$script:Worker = $null
# one-click chain state: AutoChain is set while the [Scan + Install] sequence is running, so the completion handler starts the next step by itself; WorkerMode remembers which step just finished
$script:AutoChain = $false
$script:WorkerMode = ''

# Enqueue a log line for the GUI thread to display and append to the log file
function Add-GuiLog {
    param([string]$m)
    $script:sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m))
}

# Drain queued log lines into the GUI textbox and the log file
function Receive-LogQueue {
    $lines = @()
    $line = $null
    while ($script:sync.Log.TryDequeue([ref]$line)) { $lines += $line }
    if ($lines.Count -eq 0) { return }
    if ($txtLog) {
        $txtLog.AppendText((($lines -join "`r`n") + "`r`n"))
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }
    try { Add-Content -LiteralPath $script:LogFile -Value $lines -Encoding UTF8 -ErrorAction Stop } catch { }
}

# Show a modal message box owned by the main form
function Show-GuiMsg {
    param([string]$Text, [string]$Title = 'WU Offline Tool')
    [System.Windows.Forms.MessageBox]::Show($form, $Text, $Title, 'OK', 'Information') | Out-Null
}

# Enable double buffering on a ListView to reduce redraw flicker
function Enable-LvDoubleBuffer {
    param($Lv)
    try {
        $prop = $Lv.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($prop) { $prop.SetValue($Lv, $true, $null) }
    } catch { }
}

# --- Download queue (persistent, shared between computers via download-queue.json in the working folder) ---
$script:DownloadQueue = @()     # array of item hashtables: UUID, KB, Title, Description, SizeMB, Date, Reboot, Urls, DirName, AddedAt
$script:QueueMap = @{}          # UUID -> ListViewItem of the "Download queue" tab (live status updates from the worker)
$script:ItemStatusBase = @{}    # UUID -> base status text of the available-updates row (the " [queued]" marker is appended to it)

# File name from a URL: the fileName query parameter first, then the last path segment, URL-decoded, invalid chars stripped (GUI-side copy of the worker's helper - the worker runspace cannot see GUI functions)
function Get-UrlFileName {
    param([string]$Url)
    $name = ''
    try {
        $u = [Uri]$Url
        # Microsoft CDN URLs often carry the real file name in the fileName query parameter (.../files/<guid>?fileName=<name>_<sha1>.<ext>) instead of the path
        $q = $u.Query
        if ($q -match '(?i)[?&]fileName=([^&]+)') { $name = [Uri]::UnescapeDataString($Matches[1]) }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = [Uri]::UnescapeDataString($u.Segments[$u.Segments.Count - 1])
            $name = $name.TrimEnd('/')
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'file_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    foreach ($c in @('\', '/', ':', '*', '?', '"', '<', '>', '|')) { $name = $name.Replace($c, '_') }
    return $name
}

# Read download-queue.json into an array of item hashtables (empty when missing or unreadable)
function Get-SavedQueue {
    $list = @()
    try {
        if (Test-Path -LiteralPath $script:QueueFile -PathType Leaf) {
            $obj = Get-Content -LiteralPath $script:QueueFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($obj)) {
                if (-not $e) { continue }
                $urls = @()
                try { foreach ($u in @($e.urls)) { if ($u) { $urls += [string]$u } } } catch { }
                $sizeMb = 0.0
                try { $sizeMb = [math]::Round([double]$e.sizeMB, 1) } catch { }
                $list += @{
                    UUID = [string]$e.uuid; KB = [string]$e.kb; Title = [string]$e.title
                    Description = [string]$e.description; SizeMB = $sizeMb; Date = [string]$e.date
                    Reboot = [string]$e.reboot; Urls = $urls; DirName = [string]$e.dirName
                    AddedAt = [string]$e.addedAt
                }
            }
        }
    } catch {
        Add-GuiLog ('Failed to load download-queue.json: {0}' -f $_.Exception.Message)
    }
    return , $list
}

# Write the current queue to download-queue.json (called on every queue change and on exit); the file travels with the portable project folder
function Save-Queue {
    try {
        $arr = @()
        foreach ($it in $script:DownloadQueue) {
            $arr += [pscustomobject]@{
                uuid = [string]$it.UUID; kb = [string]$it.KB; title = [string]$it.Title
                description = [string]$it.Description; sizeMB = $it.SizeMB; date = [string]$it.Date
                reboot = [string]$it.Reboot; dirName = [string]$it.DirName
                addedAt = [string]$it.AddedAt
                urls = @($it.Urls | ForEach-Object { [string]$_ })
            }
        }
        if ($arr.Count -eq 0) {
            Set-Content -LiteralPath $script:QueueFile -Value '[]' -Encoding UTF8
        } else {
            ConvertTo-Json -InputObject @($arr) -Depth 5 | Set-Content -LiteralPath $script:QueueFile -Encoding UTF8
        }
    } catch {
        Add-GuiLog ('Failed to save download-queue.json: {0}' -f $_.Exception.Message)
    }
}

# Folder name of a queue item inside Updates: the stored DirName, or rebuilt from KB + UUID prefix the way the offline scan named it
function Get-QueueDirName {
    param($It)
    $dn = [string]$It.DirName
    if ([string]::IsNullOrWhiteSpace($dn)) {
        $uuid = [string]$It.UUID
        if ($uuid.Length -ge 8) { $dn = '{0}_{1}' -f $It.KB, $uuid.Substring(0, 8) } else { $dn = [string]$It.KB }
    }
    return $dn
}

# Load the queue saved by a previous session (it was filled on this or another computer and travels with the project folder)
$script:DownloadQueue = Get-SavedQueue

#  BACKGROUND WORKER: runs in its own runspace, the GUI never blocks.  Variables are injected via SessionStateProxy: sync, WorkDir, Mode, CatalogFile, WsusServer, Selected, UninstallSel, ResetBase, IsAdmin, QueueItems, CatalogUrl, SearchCriteria, CancelMsg, plus the shared constants (exit codes, source names, worker modes)
$script:WorkerScript = {
    $counters = @{ Psf = 0 }
    # WSUS content-store file-name layouts probed by Resolve-WsusSource; the values are stable and index the candidate list. Plain integers instead of a PowerShell enum: an enum defined in the main script is visible only in that (main) runspace, while the worker runs in its own runspace where the type cannot be resolved
    $WsusStyleNative = 0              # <hash>.<ext> - the native WSUS storage name
    $WsusStyleCdnName = 1             # <name>_<hash>.<ext> - the original Microsoft CDN name
    $WsusStylePublishedConcat = 2     # <hash><name>.<ext> - locally published third-party content
    $WsusStylePublishedUnderscore = 3 # <hash>_<name>.<ext> - locally published third-party content
    $script:wsusStyle = $WsusStyleNative    # remembered WSUS file-name layout that matched last, speeds up subsequent files

    # Queue a log line for the GUI thread
    function Write-Log { param([string]$m) $sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)) }
    # Update the status-bar text shown in the GUI
    function Write-Status { param([string]$m) $sync.Status = $m }
    # Record the per-update status shown in the status column
    function Set-ItemStatus { param([string]$Uuid, [string]$Status) $sync.ItemStatus[$Uuid] = $Status }

    # Publish progress fraction (0..1) and optional text to the GUI
    function Set-Progress {
        param([double]$Fraction, [string]$Text)
        if ($Fraction -lt 0) { $Fraction = 0 }
        if ($Fraction -gt 1) { $Fraction = 1 }
        $sync.Progress = [int][math]::Round($Fraction * 100)
        if ($PSBoundParameters.ContainsKey('Text')) { $sync.ProgressText = $Text }
    }

    # Ensure TLS 1.2 is enabled for outgoing HTTPS requests
    function Enable-Tls12 {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    }

    # File name from a URL: the fileName query parameter first, then the last path segment, URL-decoded, invalid chars stripped
    function Get-UrlFileName {
        param([string]$Url)
        $name = ''
        try {
            $u = [Uri]$Url
            # Microsoft CDN URLs often carry the real file name in the fileName query parameter (.../files/<guid>?fileName=<name>_<sha1>.<ext>) instead of the path
            $q = $u.Query
            if ($q -match '(?i)[?&]fileName=([^&]+)') { $name = [Uri]::UnescapeDataString($Matches[1]) }
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = [Uri]::UnescapeDataString($u.Segments[$u.Segments.Count - 1])
                $name = $name.TrimEnd('/')
            }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = 'file_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        }
        foreach ($c in @('\', '/', ':', '*', '?', '"', '<', '>', '|')) { $name = $name.Replace($c, '_') }
        return $name
    }

    # 40-hex SHA-1 digest embedded in a Microsoft CDN/WSUS file name (..._<hash>.<ext> or <hash>.<ext>) - the same digest WSUS stores and verifies its content files by; $null when the name carries no digest
    function Get-FileNameHash {
        param([string]$FileName)
        if ($FileName -match '_([0-9a-fA-F]{40})\.[A-Za-z0-9]+$') { return $Matches[1].ToLower() }
        if ($FileName -match '^([0-9a-fA-F]{40})\.[A-Za-z0-9]+$') { return $Matches[1].ToLower() }
        return $null
    }

    # Integrity check of a file on disk: exists, non-empty and (when $ExpectedHash is given) its SHA-1 matches; $true only for an intact file
    function Test-FileIntegrity {
        param([string]$Path, [string]$ExpectedHash)
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
            if ((Get-Item -LiteralPath $Path).Length -le 0) { return $false }
            if ([string]::IsNullOrEmpty($ExpectedHash)) { return $true }
            return ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLower() -eq $ExpectedHash)
        } catch { return $false }
    }

    # True when the file starts with the MSCF cabinet signature - catches HTML/error pages saved as .cab (e.g. by a proxy)
    function Test-CabHeader {
        param([string]$Path)
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $buf = New-Object 'byte[]' 4
                if ($fs.Read($buf, 0, 4) -ne 4) { return $false }
                return ($buf[0] -eq 0x4D -and $buf[1] -eq 0x53 -and $buf[2] -eq 0x43 -and $buf[3] -eq 0x46)
            } finally { $fs.Dispose() }
        } catch { return $false }
    }

    # Streamed download with progress and cancel support; returns the byte count
    function Invoke-HttpDownload {
        param([string]$Url, [string]$DestPath, [string]$Label, [double]$Base, [double]$Span, [switch]$NoProxy)
        $partPath = "$DestPath.part"
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = 'WinManUpdateTool1/1.0'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 180000
            $req.AllowAutoRedirect = $true
            if ($NoProxy) { $req.Proxy = $null }   # intranet WSUS: bypass the system proxy
            $resp = $req.GetResponse()
            try {
                $in = $resp.GetResponseStream()
                $fs = [System.IO.File]::Create($partPath)
                try {
                    $buf = New-Object 'byte[]' 1048576
                    $total = [long]0
                    $len = $resp.ContentLength
                    $lastUi = Get-Date
                    while ($true) {
                        $n = $in.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { break }
                        $fs.Write($buf, 0, $n)
                        $total += $n
                        if ($sync.Cancel) { throw $CancelMsg }
                        if (((Get-Date) - $lastUi).TotalMilliseconds -ge 250) {
                            $lastUi = Get-Date
                            if ($len -gt 0) {
                                Set-Progress ($Base + $Span * ($total / $len)) ('{0}: {1} of {2} MB' -f $Label, [int]($total / 1MB), [int]($len / 1MB))
                            } else {
                                Set-Progress $Base ('{0}: {1} MB' -f $Label, [int]($total / 1MB))
                            }
                        }
                    }
                } finally { $fs.Dispose() }
                # a short read (the server closed the connection early) must fail instead of saving a truncated file
                if ($len -gt 0 -and $total -ne $len) { throw ('Incomplete download: received {0} of {1} bytes' -f $total, $len) }
            } finally { $resp.Close() }
            Move-Item -LiteralPath $partPath -Destination $DestPath -Force
            return $total
        } catch {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    # True - the server reports a newer version of the file (or the check failed, so re-download is the safe choice); False - 304 / date not newer than the local file
    function Test-RemoteNewer {
        param([string]$Url, [datetime]$LocalUtc, [switch]$NoProxy)
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'HEAD'
            $req.Timeout = 20000
            $req.AllowAutoRedirect = $true
            if ($NoProxy) { $req.Proxy = $null }   # intranet WSUS: bypass the system proxy
            $r = $req.GetResponse()
            try {
                $srv = [DateTime]::MinValue
                try { $srv = $r.LastModified } catch { }
                if ($srv -ne [DateTime]::MinValue -and $srv.ToUniversalTime() -le $LocalUtc.AddMinutes(2)) { return $false }
                return $true
            } finally { $r.Close() }
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($resp -and ([int]$resp.StatusCode -eq 304)) { return $false }
            return $true
        } catch {
            return $true
        }
    }

    # HTTP HEAD probe: True when the URL exists (200); False when the server answered otherwise (e.g. 404); throws when the server itself is unreachable
    function Test-HttpUrlExists {
        param([string]$Url)
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'HEAD'
            $req.Timeout = 10000
            $req.AllowAutoRedirect = $true
            $req.Proxy = $null    # intranet WSUS: never route the probe through the system proxy
            $r = $req.GetResponse()
            try { return ([int]$r.StatusCode -eq 200) } finally { $r.Close() }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { return $false }
            throw
        } catch { throw }
    }

    # WSUS reachability probe: any HTTP answer (200/301/403/404...) means the contact was established; only a transport-level failure (DNS, TCP, timeout, proxy) means unreachable. Returns @{ Online = <bool>; Detail = <HTTP status or error text> }
    function Test-WsusServerOnline {
        param([string]$BaseUrl)
        $res = @{ Online = $false; Detail = '' }
        if ($BaseUrl -like '\\*') {
            try { $res.Online = (Test-Path -LiteralPath $BaseUrl) } catch { $res.Detail = $_.Exception.Message }
            if ($res.Online) { $res.Detail = 'share accessible' } elseif ($res.Detail -eq '') { $res.Detail = 'share not accessible' }
            return $res
        }
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($BaseUrl)
            $req.Method = 'HEAD'
            $req.Timeout = 10000
            $req.AllowAutoRedirect = $false
            $req.Proxy = $null    # intranet WSUS: never route the probe through the system proxy
            $r = $req.GetResponse()
            try { $res.Online = $true; $res.Detail = ('HTTP {0}' -f [int]$r.StatusCode) } finally { $r.Close() }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $res.Online = $true; $res.Detail = ('HTTP {0}' -f [int]$_.Exception.Response.StatusCode) }
            else { $res.Detail = ('{0} [{1}]' -f $_.Exception.Message, $_.Exception.Status) }
        } catch {
            $res.Detail = $_.Exception.Message
        }
        return $res
    }

    # Normalize the WSUS source once: accept http(s)://server[:8530][/Content] or a UNC path to WSUSContent
    function Get-WsusBase {
        if ([string]::IsNullOrWhiteSpace($WsusServer)) { return '' }
        $s = $WsusServer.Trim()
        if ($s -like '\\*') { return $s.TrimEnd('\') }
        if ($s -notmatch '^https?://') { $s = 'http://' + $s }
        $s = $s.TrimEnd('/')
        if ($s.ToLower().EndsWith('/content')) { return $s }
        return ($s + '/Content')
    }

    # Map a Microsoft CDN URL to the WSUS content store layout: Content/<hash[0:2]>/<hash>.<ext>, where <hash> is the 40-hex SHA1 of the file - the same hash that is embedded in the Microsoft CDN file name (WSUS names content files by their SHA1 and keeps the original extension, e.g. Content/9c/9c8ff...d5.msu). Several name layouts exist in the wild (see the $WsusStyle* constants at the top of the worker script); candidates are probed and the working one is remembered. Returns @{ Url = <http url or unc path>; Style = <layout id, one of the $WsusStyle* constants>; Unc = <bool> } or $null when no mapping/probe matched.
    function Resolve-WsusSource {
        param([string]$Url, [string]$Base)
        if ($Base -eq '') { return $null }
        $name = Get-UrlFileName $Url
        $hash = $null
        $pure = $null
        $ext = $null
        if ($name -match '^(.+)_([0-9a-fA-F]{40})\.(.+)$') {
            $pure = $Matches[1]
            $hash = $Matches[2].ToLower()
            $ext = $Matches[3]
        } elseif ($name -match '([0-9a-fA-F]{40})(\.[A-Za-z0-9]+)$') {
            $hash = $Matches[1].ToLower()
            $ext = $Matches[2]
            $pure = $name.Substring(0, $name.Length - $hash.Length - $ext.Length)
        }
        if (-not $hash) { return $null }
        # candidate store file names per layout style; the style that matched last is probed first
        $names = @{}
        $names[$WsusStyleNative] = ('{0}.{1}' -f $hash, $ext)
        $names[$WsusStyleCdnName] = ('{0}_{1}.{2}' -f $pure, $hash, $ext)
        $names[$WsusStylePublishedConcat] = ('{0}{1}.{2}' -f $hash, $pure, $ext)
        $names[$WsusStylePublishedUnderscore] = ('{0}_{1}.{2}' -f $hash, $pure, $ext)
        $all = @($WsusStyleNative, $WsusStyleCdnName, $WsusStylePublishedConcat, $WsusStylePublishedUnderscore)
        $first = [int]$script:wsusStyle
        if ($all -notcontains $first) { $first = $WsusStyleNative }
        $order = @($first) + ($all | Where-Object { $_ -ne $first })
        foreach ($oi in $order) {
            $cand = $names[$oi]
            if ($Base -like '\\*') {
                $p = Join-Path $Base ($hash.Substring(0, 2) + '\' + $cand)
                if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ Url = $p; Style = $oi; Unc = $true } }
            } else {
                $u = $Base + '/' + $hash.Substring(0, 2) + '/' + $cand
                if (Test-HttpUrlExists $u) { return @{ Url = $u; Style = $oi; Unc = $false } }
            }
        }
        return $null
    }

    # Pick the download source for one file: the WSUS content store first (when configured and the file is present there), the Internet CDN otherwise; updates the shared $State (WsusBase is cleared when the WSUS probe fails, SkipWsus marks the file as absent from the store for the remaining attempts). Returns an object: Url = what to fetch from, Unc = fetch from a share path by copying, Source = source name for logging
    function Get-DownloadSource {
        param([string]$Url, [hashtable]$State, [string]$KB, [string]$Name)
        if ($State.WsusBase -eq '' -or $State.SkipWsus) { return [pscustomobject]@{ Url = $Url; Unc = $false; Source = $SrcInternet } }
        $ws = $null
        try { $ws = Resolve-WsusSource -Url $Url -Base $State.WsusBase } catch {
            Write-Log ('WSUS probe failed: {0} - disabling the WSUS source for this run and downloading from the Internet CDN.' -f $_.Exception.Message)
            $State.WsusBase = ''
            return [pscustomobject]@{ Url = $Url; Unc = $false; Source = $SrcInternet }
        }
        if ($ws) {
            $script:wsusStyle = $ws.Style
            return [pscustomobject]@{ Url = $ws.Url; Unc = $ws.Unc; Source = $SrcWsus }
        }
        $State.SkipWsus = $true
        Write-Log ('{0}: WSUS contact OK, but {1} is not in its store (the update is most likely not approved/downloaded on that WSUS) - falling back to the Internet CDN.' -f $KB, $Name)
        return [pscustomobject]@{ Url = $Url; Unc = $false; Source = $SrcInternet }
    }

    # Catalog wsusscn2.cab: given path -> local copy (date-checked) -> download from the official fwlink
    function Get-CatalogFile {
        $defaultTarget = Join-Path $WorkDir 'updates\wsusscn2.cab'
        if ($CatalogFile -and (Test-Path -LiteralPath $CatalogFile -PathType Leaf)) {
            if (-not (Test-CabHeader -Path $CatalogFile)) { throw ('Catalog: the specified file is not a valid cabinet: {0}' -f $CatalogFile) }
            Write-Log ('Catalog: using the specified file: {0}' -f $CatalogFile)
            return $CatalogFile
        }
        if (Test-Path -LiteralPath $defaultTarget -PathType Leaf) {
            if (-not (Test-CabHeader -Path $defaultTarget)) {
                Write-Log 'Catalog: the local wsusscn2.cab is not a valid cabinet (truncated or corrupt) - re-downloading it.'
            } else {
                $localUtc = (Get-Item -LiteralPath $defaultTarget).LastWriteTimeUtc
                Write-Log ('Catalog: local wsusscn2.cab found (modified {0}), checking freshness...' -f (Get-Date $localUtc -Format 'dd.MM.yyyy HH:mm'))
                if (-not (Test-RemoteNewer -Url $CatalogUrl -LocalUtc $localUtc)) {
                    Write-Log 'Catalog: the local copy is up to date, no download needed.'
                    return $defaultTarget
                }
                Write-Log 'Catalog: a newer wsusscn2.cab exists on the server - refreshing the local copy.'
            }
        } else {
            Write-Log ('Catalog: no local wsusscn2.cab yet - downloading from {0} (400-600 MB, may take a while).' -f $CatalogUrl)
        }
        Invoke-HttpDownload -Url $CatalogUrl -DestPath $defaultTarget -Label 'Catalog wsusscn2.cab' -Base 0 -Span 1 | Out-Null
        if (-not (Test-CabHeader -Path $defaultTarget)) {
            Remove-Item -LiteralPath $defaultTarget -Force
            throw 'Catalog: the downloaded wsusscn2.cab is not a valid cabinet (the server or a proxy returned garbage instead of the catalog) - deleted. Run the operation again to retry.'
        }
        Write-Log ('Catalog: downloaded to {0}' -f $defaultTarget)
        return $defaultTarget
    }

    # Direct URLs of an update: DownloadContents first, BundledUpdates when empty. Delta-compressed and express .psf files are skipped (not applicable manually).
    function Get-UpdateUrls {
        param($Update)
        $urls = New-Object 'System.Collections.Generic.List[string]'
        $collect = {
            param($ContentCollection)
            foreach ($c in $ContentCollection) {
                $url = $null
                $delta = $false
                try { $delta = [bool]$c.IsDeltaCompressedContent } catch { $delta = $false }
                try { $url = [string]$c.DownloadUrl } catch { $url = $null }
                if ([string]::IsNullOrEmpty($url)) { continue }
                if ($delta) { continue }
                if ($url -match '\.psf($|\?)') { $counters.Psf++; continue }
                if (-not $urls.Contains($url)) { $urls.Add($url) }
            }
        }
        & $collect $Update.DownloadContents
        if ($urls.Count -eq 0) {
            try {
                foreach ($b in $Update.BundledUpdates) { & $collect $b.DownloadContents }
            } catch { }
        }
        return , $urls
    }

    # Human-readable meaning of an installer exit code; $Tool 'msrt' additionally maps the MSRT scan result codes (KB891716)
    function Get-ExitCodeInfo {
        param([int]$Code, [string]$Tool)
        $info = @{ Ok = $false; Reboot = $false; Text = '' }
        if ($Tool -eq 'msrt') {
            switch ($Code) {
                0 { $info.Ok = $true; $info.Text = 'success, no infection found' }
                1 { $info.Text = 'OS environment error (1)' }
                2 { $info.Text = 'not running as administrator (2)' }
                3 { $info.Text = 'not a supported OS (3)' }
                4 { $info.Text = 'scanner initialization error (4) - re-download the tool' }
                6 { $info.Ok = $true; $info.Text = 'infection detected, no errors (6) - see %windir%\debug\mrt.log' }
                7 { $info.Text = 'infection detected with errors (7) - see %windir%\debug\mrt.log' }
                8 { $info.Ok = $true; $info.Text = 'infection removed, manual steps required (8) - see %windir%\debug\mrt.log' }
                9 { $info.Text = 'infection removed with errors (9) - see %windir%\debug\mrt.log' }
                10 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'infection removed, reboot required (10)' }
                11 { $info.Text = 'infection removed with errors (11) - see %windir%\debug\mrt.log' }
                12 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'infection removed, manual steps and reboot required (12)' }
                13 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'infection removed, reboot required (13)' }
            }
            if ($info.Text -ne '') { return $info }
            # codes outside the MSRT table (e.g. MSI 3010/1639) fall through to the generic mapping
        }
        switch ($Code) {
            0 { $info.Ok = $true; $info.Text = 'success' }
            1 { $info.Ok = $true; $info.Text = 'success (code 1)' }
            $ExitRebootRequired { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, REBOOT REQUIRED (3010)' }
            $ExitRebootRequiredAlt { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, reboot required (3017)' }
            $ExitRebootInitiated { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, reboot initiated (1641)' }
            $ExitAlreadyInstalled { $info.Ok = $true; $info.Text = 'already installed (2359302)' }
            1635 { $info.Text = 'patch package could not be opened (1635)' }
            1642 { $info.Text = 'patch target product not found - the Office product is not installed (1642)' }
            87 { $info.Text = 'invalid parameter (87)' }
            112 { $info.Text = 'not enough disk space (112)' }
            5 { $info.Text = 'access denied (5) - run the tool elevated' }
            740 { $info.Text = 'elevation required (740)' }
            default {
                $txt = 'error {0}' -f $Code
                if ($Code -lt 0) {
                    $hex = '0x{0:X8}' -f ($Code -band 0xFFFFFFFF)
                    $txt = ('error {0}' -f $hex)
                    if ($hex -eq '0x800F081E') { $txt = 'package is not applicable to this system (0x800F081E)' }
                    if ($Code -eq $ExitBadCommandLine) { $txt = 'invalid command line for this installer (0x80070667, Win32 1639)' }
                    if ($hex -eq '0x80240020') { $txt = 'installation canceled by the agent (0x80240020); try wusa without /quiet to see the reason' }
                }
                $info.Text = $txt
            }
        }
        return $info
    }

    # .cab applicability probe (the "Applicable : Yes/No" line of DISM output)
    function Test-CabApplicable {
        param([string]$CabPath)
        $result = @{ Ok = $false; Applicable = $false; PackageName = ''; Message = '' }
        try {
            $out = & "$env:SystemRoot\System32\Dism.exe" '/Online' '/English' '/Get-PackageInfo' ('/PackagePath:{0}' -f $CabPath) 2>&1
            $code = $LASTEXITCODE
            $text = ($out | Out-String)
            if ($text -match 'Package Name\s*:\s*(\S.+)') { $result.PackageName = $Matches[1].Trim() }
            if ($code -ne 0) {
                $result.Message = ('DISM /Get-PackageInfo exited with code {0}' -f $code)
                return $result
            }
            foreach ($line in ($text -split "`r?`n")) {
                $parts = $line.Split(':')
                if ($parts.Length -ne 2) { continue }
                if ($parts[0].Trim() -ieq 'Applicable') {
                    $result.Applicable = ($parts[1].Trim() -ieq 'Yes')
                    $result.Ok = $true
                    break
                }
            }
            if (-not $result.Ok) { $result.Message = 'DISM output contains no "Applicable" line - applicability unknown' }
            return $result
        } catch {
            $result.Message = ('Failed to run DISM /Get-PackageInfo: {0}' -f $_.Exception.Message)
            return $result
        }
    }

    # Append a record to install-state.json (audit trail of performed installations)
    function Add-StateRecord {
        param([string]$KB, [string]$FilePath, [string]$Method, [string]$Identity, [int]$ExitCode)
        try {
            $statePath = Join-Path $WorkDir 'install-state.json'
            $state = @()
            if (Test-Path -LiteralPath $statePath) {
                try { $state = @(Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $state = @() }
            }
            $rec = [pscustomobject]@{
                kb = $KB; file = $FilePath; method = $Method; identity = $Identity; exit = $ExitCode
                machine = $env:COMPUTERNAME
                at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $state = @($state) + $rec
            ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
        } catch {
            Write-Log ('Failed to update install-state.json: {0}' -f $_.Exception.Message)
        }
    }

    # MODE: Offline scan. Enumerate missing updates against the local wsusscn2.cab catalog
    function Invoke-Scan {
        Write-Status 'Preparing the catalog...'
        Set-Progress 0 'Checking wsusscn2.cab'
        $catalog = Get-CatalogFile

        Write-Log ('Registering the offline scan source: {0}' -f $catalog)
        $session = New-Object -ComObject Microsoft.Update.Session
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $svcOffline = $null
        try { $svcOffline = $sm.AddScanPackageService('Offline Sync Service', $catalog) }
        catch { $svcOffline = $sm.AddScanPackageService('Offline Sync Service', $catalog, 0) }
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 3          # ssOthers - deliberately NOT ssManagedServer (WSUS)
        $searcher.ServiceID = $svcOffline.ServiceID

        Write-Log ('Starting the offline scan against the local catalog. Criteria: {0}' -f $SearchCriteria)
        Write-Log 'It usually takes 5-40 minutes; the scan itself cannot be interrupted.'
        Write-Status 'Offline scan (local catalog, no WSUS contact)...'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = $searcher.Search($SearchCriteria)
        $sw.Stop()
        Write-Log ('Scan finished in {0:00} min {1:00} sec. Updates found: {2}.' -f [int]$sw.Elapsed.TotalMinutes, $sw.Elapsed.Seconds, $r.Updates.Count)

        $updatesDir = Join-Path $WorkDir 'Updates'
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($u in $r.Updates) {
            if ($sync.Cancel) { throw $CancelMsg }
            try {
                $kb = 'KBUnknown'
                try { if ($u.KBArticleIDs.Count -gt 0) { $kb = 'KB{0}' -f $u.KBArticleIDs[0] } } catch { }
                $uuid = ''
                try { $uuid = [string]$u.Identity.UpdateID } catch { }
                if ([string]::IsNullOrEmpty($uuid)) { $uuid = [Guid]::NewGuid().ToString() }
                $counters.Psf = 0
                $urls = Get-UpdateUrls $u
                $note = ''
                if ($urls.Count -eq 0) { $note = 'no direct file URL' }
                elseif ($counters.Psf -gt 0) { $note = 'some express files (.psf) skipped' }
                $title = ''
                try { $title = [string]$u.Title } catch { }
                $desc = ''
                try { $desc = ([string]$u.Description -replace '\s+', ' ') } catch { }
                if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) + '...' }
                $sizeMb = 0.0
                try { $sizeMb = [math]::Round($u.MaxDownloadSize / 1MB, 1) } catch { }
                $date = ''
                try { if ($u.LastDeploymentChangeTime -and $u.LastDeploymentChangeTime.Year -ge 2000) { $date = $u.LastDeploymentChangeTime.ToString('dd.MM.yyyy') } } catch { }
                $reboot = ''
                try {
                    $rb = $u.InstallationBehavior.RebootBehavior
                    if ($rb -eq 2) { $reboot = 'mandatory' } elseif ($rb -eq 1) { $reboot = 'possible' }
                } catch { }
                $dirName = '{0}_{1}' -f $kb, $uuid.Substring(0, 8)
                $dir = Join-Path $updatesDir $dirName
                $haveAll = $false
                if ($urls.Count -gt 0) {
                    $haveAll = $true
                    foreach ($url in $urls) {
                        $fn = Get-UrlFileName $url
                        if (-not (Test-Path -LiteralPath (Join-Path $dir $fn))) { $haveAll = $false; break }
                    }
                }
                $item = @{
                    UUID = $uuid; KB = $kb; Title = $title; Description = $desc
                    SizeMB = $sizeMb; Date = $date; Reboot = $reboot
                    Urls = $urls; Note = $note; Dir = $dir; DownloadedAll = $haveAll
                }
                $list.Add($item)
            } catch {
                Write-Log ('Skipping an update: failed to read WUA data: {0}' -f $_.Exception.Message)
            }
        }
        $sync.Result = $list.ToArray()
        $sync.ScanDone = $true
        Write-Log 'Done. Mark the needed updates and run [Download selected].'
    }

    # Download-source state shared by all files of one run: WsusBase = the normalized WSUS content root ('' when disabled/unreachable), SkipWsus = the current file is known to be absent from the WSUS store
    function Initialize-DownloadState {
        $dlState = @{ WsusBase = (Get-WsusBase); SkipWsus = $false }
        if ($dlState.WsusBase -ne '') {
            Write-Log ('WSUS download source enabled: {0} (missing files fall back to the Internet CDN).' -f $dlState.WsusBase)
            $probe = Test-WsusServerOnline -BaseUrl $dlState.WsusBase
            if ($probe.Online) { Write-Log ('WSUS contact established, the server answered: {0}.' -f $probe.Detail) }
            else {
                Write-Log ('WSUS server did not answer: {0} - disabling the WSUS source for this run and downloading from the Internet CDN.' -f $probe.Detail)
                $dlState.WsusBase = ''
            }
        } else { Write-Log 'Downloading from the Internet CDN.' }
        return $dlState
    }

    # Download all files of one update item (hashtable with UUID, KB, Urls, Dir); returns the number of failed files, or -1 when the item has no direct URLs at all. Shared by [Download selected] (items from the scan results) and [Download queue] (items from download-queue.json).
    function Invoke-UpdateFilesDownload {
        param([hashtable]$Item, [int]$Index, [int]$Total, [hashtable]$DlState)
        $uuid = [string]$Item.UUID
        if (-not $Item.Urls -or @($Item.Urls).Count -eq 0) {
            Set-ItemStatus $uuid 'No direct file URL'
            Write-Log ('{0}: no direct URLs for its files - skipped.' -f $Item.KB)
            return -1
        }
        if (-not (Test-Path -LiteralPath $Item.Dir)) { New-Item -ItemType Directory -Path $Item.Dir -Force | Out-Null }
        $urls = @($Item.Urls)
        $fcount = $urls.Count
        $fi = 0
        $itemFail = 0
        foreach ($url in $urls) {
            if ($sync.Cancel) { throw $CancelMsg }
            $fi++
            $name = Get-UrlFileName $url
            $dest = Join-Path $Item.Dir $name
            $base = (($Index - 1) + (($fi - 1) / $fcount)) / $Total
            $span = (1.0 / $fcount) / $Total
            # expected SHA-1 digest: the one embedded in the CDN/WSUS file name (the WSUS store copy is byte-identical, so it matches both sources)
            $nameHash = Get-FileNameHash $name
            $bytes = -1
            $fileOk = $false
            $DlState.SkipWsus = $false
            # fast path (skipped by [Force re-download]): the file is on disk and its bytes match the SHA-1 pinned in its name, so it is exactly what this URL serves - reuse it as is, no probe, no server check (delete the Updates folder or the KB subfolder to force a re-download)
            if (-not $ForceRedl -and $nameHash -and (Test-Path -LiteralPath $dest) -and (Test-FileIntegrity -Path $dest -ExpectedHash $nameHash)) {
                Write-Log ('{0}: {1} already downloaded - checksum verified, skipping.' -f $Item.KB, $name)
                continue
            }
            # up to 3 attempts per file: corrupt/truncated downloads and transient network errors are retried, a broken file is never left on disk
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                # choose the download source: WSUS first when configured (unless it proved empty for this file), Internet otherwise
                $dl = Get-DownloadSource -Url $url -State $DlState -KB $Item.KB -Name $name
                $dlUrl = $dl.Url
                $dlUnc = $dl.Unc
                $srcName = $dl.Source
                $needFetch = $true
                if ($ForceRedl) {
                    # [Force re-download]: fetch again even when an intact copy exists. The fresh data is written to a .part file and replaces the old copy (Move-Item -Force) only after the full download
                    # succeeded, so a failed attempt keeps the previous file on disk.
                    if (Test-Path -LiteralPath $dest) { Write-Log ('{0}: {1} - forced re-download, the existing copy is replaced only after a successful fetch.' -f $Item.KB, $name) }
                } elseif (Test-Path -LiteralPath $dest) {
                    # reuse a present file only when it passes the integrity check - protects against corrupt leftovers of earlier runs
                    if (-not (Test-FileIntegrity -Path $dest -ExpectedHash $nameHash)) {
                        Write-Log ('{0}: {1} is present but corrupt (SHA-1 check failed) - re-downloading.' -f $Item.KB, $name)
                        Remove-Item -LiteralPath $dest -Force
                    } elseif ($dlUnc) {
                        Write-Log ('{0}: {1} already downloaded - skipping.' -f $Item.KB, $name)
                        $needFetch = $false
                    } else {
                        Set-Progress ($base + $span * 0.5) ('{0}: checking {1}' -f $Item.KB, $name)
                        if (-not (Test-RemoteNewer -Url $dlUrl -LocalUtc (Get-Item -LiteralPath $dest).LastWriteTimeUtc -NoProxy:($srcName -eq $SrcWsus))) {
                            Write-Log ('{0}: {1} already downloaded and up to date - skipping.' -f $Item.KB, $name)
                            $needFetch = $false
                        } else {
                            Write-Log ('{0}: {1} - a newer version exists on the server, re-downloading.' -f $Item.KB, $name)
                            Remove-Item -LiteralPath $dest -Force
                        }
                    }
                }
                if (-not $needFetch) { $fileOk = $true; break }
                Set-ItemStatus $uuid ('Downloading {0}/{1}: {2}' -f $fi, $fcount, $name)
                try {
                    if ($dlUnc) {
                        Write-Log ('{0}: copying {1} from WSUS share' -f $Item.KB, $name)
                        Copy-Item -LiteralPath $dlUrl -Destination $dest -Force
                        $bytes = (Get-Item -LiteralPath $dest).Length
                    } else {
                        Write-Log ('{0}: downloading {1} from {2}' -f $Item.KB, $name, $srcName)
                        $bytes = Invoke-HttpDownload -Url $dlUrl -DestPath $dest -Label ('{0}: {1}' -f $Item.KB, $name) -Base $base -Span $span -NoProxy:($srcName -eq $SrcWsus)
                    }
                } catch {
                    if ($_.Exception.Message -eq $CancelMsg) { throw }
                    Write-Log ('{0}: downloading {1} from {2} failed: {3}' -f $Item.KB, $name, $srcName, $_.Exception.Message)
                    $bytes = 0
                }
                if (Test-FileIntegrity -Path $dest -ExpectedHash $nameHash) { $fileOk = $true; break }
                # the saved data is garbage: often a small HTML/XML error page (proxy or captive portal) - recognize it to log a clear hint
                if (Test-Path -LiteralPath $dest) {
                    $isHtml = $false
                    try {
                        $fs = [System.IO.File]::OpenRead($dest)
                        try { $isHtml = ($fs.ReadByte() -eq 0x3C) } finally { $fs.Dispose() }
                    } catch { }
                    if ($isHtml) { Write-Log ('{0}: {1} from {2} is an HTML/XML page, not the package (proxy or captive-portal interference?) - retrying.' -f $Item.KB, $name, $srcName) }
                    else { Write-Log ('{0}: {1} from {2} fails the SHA-1 integrity check (expected {3}) - retrying.' -f $Item.KB, $name, $srcName, $nameHash) }
                    Remove-Item -LiteralPath $dest -Force
                }
                if ($srcName -eq $SrcWsus) { $DlState.SkipWsus = $true }
            }
            if (-not $fileOk) {
                $itemFail++
                Set-ItemStatus $uuid ('Download failed: {0}' -f $name)
                Write-Log ('{0}: {1} could not be downloaded intact after 3 attempts - skipped.' -f $Item.KB, $name)
                continue
            }
            if ($bytes -ge 0) { Write-Log ('{0}: saved {1} ({2:N1} MB)' -f $Item.KB, $name, ($bytes / 1MB)) }
        }
        return $itemFail
    }

    # Download files of the selected updates from the scan results (WSUS source first, then Internet CDN)
    function Invoke-Download {
        if (@($Selected).Count -eq 0) { Write-Log 'No updates selected.'; return }
        $dlState = Initialize-DownloadState
        $totalItems = @($Selected).Count
        $idx = 0
        foreach ($uuid in $Selected) {
            if ($sync.Cancel) { throw $CancelMsg }
            $it = $null
            foreach ($cand in $sync.Result) { if ($cand.UUID -eq $uuid) { $it = $cand; break } }
            if (-not $it) { continue }
            $idx++
            $fail = Invoke-UpdateFilesDownload -Item $it -Index $idx -Total $totalItems -DlState $dlState
            if ($fail -lt 0) { continue }
            if ($fail -gt 0) {
                Set-ItemStatus ([string]$it.UUID) ('Downloaded with errors ({0} file(s) failed)' -f $fail)
                Write-Log ('{0}: download finished with errors.' -f $it.KB)
            } else {
                Set-ItemStatus ([string]$it.UUID) 'Downloaded - ready to install'
                Write-Log ('{0}: download finished.' -f $it.KB)
            }
        }
        Write-Log 'Download: all selected updates processed.'
    }

    # MODE: Download queue - download the updates collected in download-queue.json. Used on a computer WITH Internet access: the queue was filled on the offline target computer and each item carries its direct CDN/WSUS file URLs, so no catalog and no scan are needed here (this mode works without administrator rights). The files land in the same Updates\<KB>_<uuid8> subfolders the offline computer names them by, so after copying the folder back and re-scanning there the updates are recognized as already downloaded and can be installed.
    function Invoke-DownloadQueue {
        $queueItems = @($QueueItems)
        if ($queueItems.Count -eq 0) { Write-Log 'The download queue is empty - nothing to download.'; return }
        Write-Log ('Download queue: {0} item(s) queued in download-queue.json.' -f $queueItems.Count)
        $dlState = Initialize-DownloadState
        $updatesDir = Join-Path $WorkDir 'Updates'
        $totalItems = $queueItems.Count
        $idx = 0
        $doneOk = 0
        $doneFail = 0
        foreach ($it in $queueItems) {
            if ($sync.Cancel) { throw $CancelMsg }
            $idx++
            # resolve the item folder exactly the way the offline computer named it: Updates\<KB>_<uuid8>
            $dirName = [string]$it.DirName
            if ([string]::IsNullOrWhiteSpace($dirName)) {
                $uuidStr = [string]$it.UUID
                if ($uuidStr.Length -ge 8) { $dirName = '{0}_{1}' -f $it.KB, $uuidStr.Substring(0, 8) } else { $dirName = [string]$it.KB }
            }
            $it.Dir = Join-Path $updatesDir $dirName
            $fail = Invoke-UpdateFilesDownload -Item $it -Index $idx -Total $totalItems -DlState $dlState
            if ($fail -gt 0) {
                $doneFail++
                Set-ItemStatus ([string]$it.UUID) ('Downloaded with errors ({0} file(s) failed)' -f $fail)
                Write-Log ('{0}: download finished with errors.' -f $it.KB)
            } elseif ($fail -eq 0) {
                $doneOk++
                Set-ItemStatus ([string]$it.UUID) 'Downloaded - copy the Updates folder to the target computer'
                Write-Log ('{0}: download finished.' -f $it.KB)
            } else {
                $doneFail++
            }
        }
        $sync.QueueDlDone = $true
        Write-Log ('Download queue: finished. {0} item(s) fully downloaded, {1} with problems. Copy the Updates folder to the target computer and run [Scan (offline)] there.' -f $doneOk, $doneFail)
    }

    # True when a reboot from earlier installations is pending (CBS or Windows Update flagged it) - in this state new CBS packages (.msu/.cab) are only staged and processed at the next boot, so their quick "success, reboot required" does not mean they are installed
    function Test-RebootPending {
        try {
            if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
            if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
        } catch { }
        return $false
    }

    # Extended diagnostics after a failed DISM operation: the last lines DISM itself printed (when its output was captured) plus the error tail of the CBS servicing log - the real reason lands in the log file instead of only the exit code
    function Write-DismFailureDetails {
        param([string[]]$DismOutput)
        if ($DismOutput -and @($DismOutput).Count -gt 0) {
            # a redirected DISM progress bar is one long line cut by carriage returns: keep the last segment of each line, drop progress-only and empty lines
            $tail = @($DismOutput | ForEach-Object { ([string]$_ -split "`r")[-1] } | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\[+[=\.\s\d%]*\]+$' } | Select-Object -Last 12)
            foreach ($l in $tail) {
                if ($l.Length -gt 300) { $l = $l.Substring(0, 300) + '...' }
                Write-Log ('DISM output: {0}' -f $l)
            }
        }
        try {
            $cbsLog = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
            if (Test-Path -LiteralPath $cbsLog) {
                $errs = @(Get-Content -LiteralPath $cbsLog -Tail 300 -ErrorAction Stop | Where-Object { $_ -match '(?i)error|failed' } | Select-Object -Last 10)
                Write-Log ('CBS log: {0} - last matching lines (the full log is there):' -f $cbsLog)
                if ($errs.Count -eq 0) { Write-Log 'CBS log: no error lines in the tail.' }
                foreach ($l in $errs) { Write-Log ('CBS: {0}' -f $l) }
            } else { Write-Log ('CBS log not found: {0}' -f $cbsLog) }
        } catch { Write-Log ('Could not read the CBS log: {0}' -f $_.Exception.Message) }
        Write-Log ('DISM also writes its own log: {0}.' -f (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'))
    }

    # Extended diagnostics for a failed installer run, written straight into the log file: every quiet line that was tried, file size, version and signature state, and for MSRT the state of its stub folder and mrt.log - enough to analyze the failure later without a live console
    function Write-InstallerDiagnostics {
        param($File, [int]$ExitCode, [string[]]$ArgLines)
        Write-Log ('Diagnostics for {0} (exit code {1}):' -f $File.Name, $ExitCode)
        foreach ($al in @($ArgLines)) { if ($al) { Write-Log ('Command line tried: {0}' -f $al) } }
        try {
            $fi = Get-Item -LiteralPath $File.FullName
            $vi = $fi.VersionInfo
            $sig = (Get-AuthenticodeSignature -LiteralPath $fi.FullName).Status
            Write-Log ('File: {0:N1} MB, version "{1}", product "{2}", signature: {3}.' -f ($fi.Length / 1MB), $vi.FileVersion, $vi.ProductName, $sig)
        } catch { Write-Log ('File metadata unavailable: {0}' -f $_.Exception.Message) }
        if ($File.Name.ToLower().StartsWith('windows-kb890830')) {
            # the package stub extracts its payload (mrt.exe) into %TEMP%\Microsoft\MRTStub and runs it from there - leftovers of a failed run show how far it got
            $stubDir = Join-Path $env:TEMP 'Microsoft\MRTStub'
            if (Test-Path -LiteralPath $stubDir) {
                Write-Log ('MSRT stub folder: {0}, recent files:' -f $stubDir)
                foreach ($f in @(Get-ChildItem -LiteralPath $stubDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) { Write-Log ('MSRT stub: {0} ({1:N1} MB, {2})' -f $f.Name, ($f.Length / 1MB), $f.LastWriteTime) }
            } else { Write-Log ('MSRT stub folder not found: {0} - the package was rejected before extraction.' -f $stubDir) }
            $mrtLog = Join-Path $env:SystemRoot 'debug\mrt.log'
            try {
                if (Test-Path -LiteralPath $mrtLog) {
                    Write-Log ('MSRT log: {0} (last written {1}), last lines:' -f $mrtLog, (Get-Item -LiteralPath $mrtLog).LastWriteTime)
                    foreach ($l in @(Get-Content -LiteralPath $mrtLog -Tail 15 -ErrorAction Stop)) { Write-Log ('MSRT: {0}' -f $l) }
                } else { Write-Log ('MSRT log not found ({0}) - the package did not get far enough to write it.' -f $mrtLog) }
            } catch { Write-Log ('Could not read the MSRT log: {0}' -f $_.Exception.Message) }
        }
    }

    #  MODE: Install selected. Apply downloaded packages (msu/cab/exe/msi) to the local system
    function Invoke-Install {
        if (-not $IsAdmin) { throw 'Installation requires administrator rights. Restart the tool elevated.' }
        if (@($Selected).Count -eq 0) { Write-Log 'No updates selected.'; return }
        # a reboot pending from earlier installations makes new CBS installs (.msu/.cab) unreliable: they are only staged and may reappear in the scan after the reboot - warn so the admin can reboot first
        if (Test-RebootPending) { Write-Log 'WARNING: a reboot from earlier installations is already pending - new .msu/.cab packages will only be staged now. It is recommended to reboot first and run Install again afterwards.' }
        $totalItems = @($Selected).Count
        $idx = 0
        foreach ($uuid in $Selected) {
            if ($sync.Cancel) { throw $CancelMsg }
            $it = $null
            foreach ($cand in $sync.Result) { if ($cand.UUID -eq $uuid) { $it = $cand; break } }
            if (-not $it) { continue }
            $idx++
            $files = @()
            if (Test-Path -LiteralPath $it.Dir) {
                $files = @(Get-ChildItem -LiteralPath $it.Dir -File | Where-Object { $_.Extension -match '^\.(msu|cab|exe|msi)$' })
            }
            if ($files.Count -eq 0) {
                Set-ItemStatus $uuid 'Files not downloaded yet - run Download first'
                Write-Log ('{0}: no installable packages in its folder - skipped.' -f $it.KB)
                continue
            }
            $files = @($files | Sort-Object -Property @{ Expression = {
                        $e = $_.Extension.ToLower()
                        if ($e -eq '.msu') { 0 } elseif ($e -eq '.cab') { 1 } elseif ($e -eq '.exe') { 2 } elseif ($e -eq '.msi') { 3 } else { 9 }
                    }
                })
            $fi = 0
            $itemOk = 0
            $itemErr = 0
            $itemStaged = $false
            foreach ($file in $files) {
                if ($sync.Cancel) { throw $CancelMsg }
                $fi++
                $base = (($idx - 1) + (($fi - 1) / $files.Count)) / $totalItems
                $span = (1.0 / $files.Count) / $totalItems
                Set-Progress ($base + $span * 0.5) ('{0}: installing {1}' -f $it.KB, $file.Name)
                Set-ItemStatus $uuid ('Installing {0}/{1}: {2}' -f $fi, $files.Count, $file.Name)
                # never hand a corrupt file to an installer: a truncated package only produces a cryptic OS error
                if (-not (Test-FileIntegrity -Path $file.FullName -ExpectedHash (Get-FileNameHash $file.Name))) {
                    Remove-Item -LiteralPath $file.FullName -Force
                    Write-Log ('{0}: {1} is corrupt (SHA-1 check failed) - deleted, run Download to re-fetch it.' -f $it.KB, $file.Name)
                    Set-ItemStatus $uuid ('Corrupt file deleted: {0}' -f $file.Name)
                    $itemErr++
                    continue
                }
                $ext = $file.Extension.ToLower()
                $exitCode = -1
                $pkgIdentity = ''
                $exitTool = $ext
                $argCandidates = @()    # quiet lines tried in order for exe installers (a wrapper that does not recognize a switch answers Win32 1639)
                # whether a reboot was already pending when this package started: CBS packages (.msu/.cab) are then only staged, the real installation happens after the reboot
                $rebootWasPending = Test-RebootPending
                if ($rebootWasPending -and ($ext -eq '.msu' -or $ext -eq '.cab')) {
                    Write-Log ('{0}: WARNING: a reboot from a previous update is already pending - {1} will only be staged now, its quick completion does not mean it is installed.' -f $it.KB, $file.Name)
                }
                if ($ext -eq '.msu') {
                    Write-Log ('{0}: wusa.exe (silent install): {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wusa.exe') -ArgumentList ('"{0}" /quiet /norestart' -f $file.FullName) -Wait -PassThru -WindowStyle Hidden
                    $exitCode = $p.ExitCode
                } elseif ($ext -eq '.cab') {
                    Write-Log ('{0}: checking applicability via DISM: {1}' -f $it.KB, $file.Name)
                    $cabInfo = Test-CabApplicable -CabPath $file.FullName
                    if (-not $cabInfo.Ok) {
                        # DISM cannot open non-CBS cabs (exit code 2): Office-family updates are cab containers with .msp payloads. Extract the patches and apply them with msiexec /p instead of skipping the update.
                        $mspDir = Join-Path $file.DirectoryName ($file.BaseName + '.msp')
                        if (Test-Path -LiteralPath $mspDir) { Remove-Item -LiteralPath $mspDir -Recurse -Force }
                        New-Item -ItemType Directory -Path $mspDir -Force | Out-Null
                        & "$env:SystemRoot\System32\expand.exe" $file.FullName '-F:*' $mspDir 2>&1 | Out-Null
                        $msps = @(Get-ChildItem -LiteralPath $mspDir -Filter '*.msp' -File -Recurse -ErrorAction SilentlyContinue)
                        if ($msps.Count -gt 0) {
                            foreach ($msp in $msps) {
                                Write-Log ('{0}: msiexec /p (Office patch from cab): {1}' -f $it.KB, $msp.Name)
                                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList ('/p "{0}" /qn /norestart' -f $msp.FullName) -Wait -PassThru
                                $mspInfo = Get-ExitCodeInfo -Code $p.ExitCode -Tool $ext
                                if ($mspInfo.Reboot) { $sync.RebootNeeded = $true }
                                if ($mspInfo.Ok) { $itemOk++ } else { $itemErr++ }
                                Write-Log ('{0}: {1} → exit code {2}: {3}' -f $it.KB, $msp.Name, $p.ExitCode, $mspInfo.Text)
                                Add-StateRecord -KB $it.KB -FilePath $msp.FullName -Method 'msp' -Identity '' -ExitCode $p.ExitCode
                            }
                            Set-ItemStatus $uuid ('Office patch applied: {0} file(s)' -f $msps.Count)
                            continue
                        }
                        Write-Log ('{0}: skipping {1}: {2}' -f $it.KB, $file.Name, $cabInfo.Message)
                        Set-ItemStatus $uuid ('Check failed: {0}' -f $file.Name)
                        $itemErr++
                        continue
                    }
                    if (-not $cabInfo.Applicable) {
                        Write-Log ('{0}: package {1} is not applicable to this system - skipped.' -f $it.KB, $file.Name)
                        Set-ItemStatus $uuid ('Not applicable: {0}' -f $file.Name)
                        continue
                    }
                    $pkgIdentity = $cabInfo.PackageName
                    Write-Log ('{0}: DISM /Add-Package: {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -ArgumentList ('/Online /Quiet /NoRestart /Add-Package /PackagePath:"{0}" /IgnoreCheck' -f $file.FullName) -Wait -PassThru
                    $exitCode = $p.ExitCode
                } elseif ($ext -eq '.msi') {
                    Write-Log ('{0}: msiexec: {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList ('/i "{0}" /qn /norestart' -f $file.FullName) -Wait -PassThru
                    $exitCode = $p.ExitCode
                } elseif ($ext -eq '.exe') {
                    $n = $file.Name.ToLower()
                    if ($n.StartsWith('ndp') -or $n.StartsWith('ofv') -or $n.Contains('2553065')) {
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /q /norestart' -f $file.FullName); Label = '/q /norestart' }
                    } elseif ($n.StartsWith('windows-kb890830')) {
                        # MSRT: the accepted quiet syntax depends on the wrapper generation - the documented /Q, the Windows Update context markers (/W, /WindowsUpdate) of the 2026 msi-free stub, or the MSI-style line of the older builds - so the candidates are probed in turn until one is accepted
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /Q' -f $file.FullName); Label = '/Q' }
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /W' -f $file.FullName); Label = '/W' }
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /WindowsUpdate' -f $file.FullName); Label = '/WindowsUpdate' }
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /qn /norestart' -f $file.FullName); Label = '/qn /norestart' }
                        $exitTool = 'msrt'
                    } else {
                        $argCandidates += [pscustomobject]@{ Line = ('"{0}" /q /z' -f $file.FullName); Label = '/q /z' }
                    }
                    Write-Log ('{0}: running installer: {1}' -f $it.KB, $file.Name)
                    $tryIdx = 0
                    while ($true) {
                        $p = Start-Process -FilePath $file.FullName -ArgumentList $argCandidates[$tryIdx].Line -Wait -PassThru
                        $exitCode = $p.ExitCode
                        $tryIdx++
                        if ($exitCode -ne $ExitBadCommandLine -or $tryIdx -ge $argCandidates.Count) { break }
                        Write-Log ('{0}: {1} rejected the quiet line {2} (Win32 1639 ERROR_BAD_COMMAND_LINE) - trying the next candidate.' -f $it.KB, $file.Name, $argCandidates[$tryIdx - 1].Label)
                    }
                } else {
                    Write-Log ('{0}: format {1} is not supported for manual installation - skipped.' -f $it.KB, $ext)
                    continue
                }
                $info = Get-ExitCodeInfo -Code $exitCode -Tool $exitTool
                if ($info.Reboot) { $sync.RebootNeeded = $true }
                if ($info.Ok) { $itemOk++ } else { $itemErr++ }
                # a CBS package that returned "reboot required" while a reboot was ALREADY pending was only staged, not installed - report that honestly instead of "installed successfully"
                if ($info.Reboot -and $rebootWasPending -and ($exitTool -eq '.msu' -or $exitTool -eq '.cab')) {
                    $itemStaged = $true
                    Write-Log ('{0}: {1} was only STAGED: a reboot was already pending from a previous update. Reboot, then re-scan and install it again if it still shows as missing.' -f $it.KB, $file.Name)
                }
                # extended diagnostics for failed installers land in the log file: command line, file metadata, signature and, where applicable, DISM/CBS or MSRT log tails
                if (-not $info.Ok) {
                    Write-InstallerDiagnostics -File $file -ExitCode $exitCode -ArgLines @($argCandidates | ForEach-Object { $_.Line })
                    if ($ext -eq '.cab') { Write-DismFailureDetails -DismOutput $null }
                }
                Write-Log ('{0}: {1} → exit code {2}: {3}' -f $it.KB, $file.Name, $exitCode, $info.Text)
                Set-ItemStatus $uuid ('Result: {0}' -f $info.Text)
                Add-StateRecord -KB $it.KB -FilePath $file.FullName -Method $ext -Identity $pkgIdentity -ExitCode $exitCode
            }
            $statTxt = 'Done'
            if ($itemErr -gt 0) { $statTxt = ('Completed with errors ({0})' -f $itemErr) }
            elseif ($itemStaged) { $statTxt = 'Staged, not installed - reboot first, then re-scan and install again if it reappears' }
            elseif ($itemOk -gt 0 -and $sync.RebootNeeded) { $statTxt = 'Installed, reboot required' }
            elseif ($itemOk -gt 0) { $statTxt = 'Installed' }
            Set-ItemStatus $uuid $statTxt
            # Remember items installed without errors to uncheck them in the GUI afterwards; staged-only items stay checked - after the reboot they may need another Install run
            if ($itemOk -gt 0 -and $itemErr -eq 0 -and -not $itemStaged) { $sync.InstalledOk.Enqueue([string]$uuid) }
        }
        Write-Log 'Install: all selected updates processed.'
    }

    # Parse DISM /Get-Packages output into Package_for_* update records
    function Get-DismPackagesFromText {
        param([string]$Text)
        $result = New-Object 'System.Collections.Generic.List[object]'
        if ([string]::IsNullOrEmpty($Text)) { return , $result }
        $chunks = $Text -split 'Package Identity\s*:'
        for ($i = 1; $i -lt $chunks.Count; $i++) {
            $lines = $chunks[$i] -split "`r?`n"
            $identity = $lines[0].Trim()
            $state = ''
            $rtype = ''
            $itime = ''
            foreach ($line in $lines) {
                if ($line -match '^\s*State\s*:\s*(.+?)\s*$') { $state = $Matches[1] }
                elseif ($line -match '^\s*Release Type\s*:\s*(.+?)\s*$') { $rtype = $Matches[1] }
                elseif ($line -match '^\s*Install Time\s*:\s*(.+?)\s*$') { $itime = $Matches[1] }
            }
            if ($identity -like 'Package_for_*' -and $state -eq 'Installed' -and $rtype -eq 'Update' -and $identity -notmatch 'ServicingStack') {
                $result.Add([pscustomobject]@{ Identity = $identity; State = $state; ReleaseType = $rtype; InstallTime = $itime })
            }
        }
        return , $result
    }

    # Build a readable name from a DISM package identity string
    function Get-PrettyPackageName {
        param([string]$Identity)
        $parts = $Identity -split '~'
        if ($parts.Count -ge 5) {
            $base = $parts[0] -replace '^Package_for_', ''
            return ('{0} ({1})' -f $base, $parts[$parts.Count - 1])
        }
        return $Identity
    }

    # Build the installed-updates list from QFE and DISM data
    function Invoke-ListInstalled {
        Write-Status 'Collecting the list of installed updates...'
        $items = New-Object 'System.Collections.Generic.List[object]'
        Write-Log 'Reading the QFE journal (Win32_QuickFixEngineering)...'
        try {
            $qfe = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                    Where-Object { $_.HotFixID -and $_.HotFixID -ne '' } |
                    Sort-Object -Property InstalledOn -Descending)
            foreach ($q in $qfe) {
                $dt = ''
                try { if ($q.InstalledOn) { $dt = $q.InstalledOn.ToString('dd.MM.yyyy') } } catch { }
                $items.Add(@{
                        Key = ('wusa|{0}' -f $q.HotFixID); Name = [string]$q.HotFixID
                        Desc = [string]$q.Description; Type = 'QFE (wusa /uninstall)'; Date = $dt
                    })
            }
            Write-Log ('QFE records: {0}.' -f $qfe.Count)
        } catch {
            Write-Log ('Failed to get the QFE list: {0}' -f $_.Exception.Message)
        }
        Write-Log 'Reading DISM packages (dism /Get-Packages), this takes up to a minute...'
        try {
            $out = & "$env:SystemRoot\System32\Dism.exe" '/Online' '/English' '/Get-Packages' 2>&1
            $text = ($out | Out-String)
            $pkgs = Get-DismPackagesFromText -Text $text
            foreach ($p in $pkgs) {
                $items.Add(@{
                        Key = ('dism|{0}' -f $p.Identity); Name = (Get-PrettyPackageName $p.Identity)
                        Desc = $p.Identity; Type = 'DISM package'; Date = $p.InstallTime
                    })
            }
            Write-Log ('Installed DISM update packages (Package_for_*): {0}.' -f $pkgs.Count)
        } catch {
            Write-Log ('Failed to get the DISM package list: {0}' -f $_.Exception.Message)
        }
        $sync.InstalledList = $items.ToArray()
        $sync.InstalledDone = $true
        Write-Status ''
    }

    # MODE: Uninstall selected. Remove the selected QFE entries (wusa) and DISM packages
    function Invoke-Uninstall {
        if (-not $IsAdmin) { throw 'Uninstallation requires administrator rights. Restart the tool elevated.' }
        if (@($UninstallSel).Count -eq 0) { Write-Log 'Nothing selected for uninstall.'; return }
        $rebootNeeded = $false
        $errCount = 0
        $i = 0
        foreach ($key in $UninstallSel) {
            if ($sync.Cancel) { throw $CancelMsg }
            $i++
            Set-Progress ((($i - 1) + 0.5) / @($UninstallSel).Count) ('Uninstalling {0} of {1}...' -f $i, @($UninstallSel).Count)
            if ($key -like 'wusa|*') {
                $kb = $key.Substring(5)
                $kbNum = $kb -replace '^KB', ''
                Write-Log ('Uninstalling via wusa: {0}...' -f $kb)
                Write-Status ('wusa /uninstall: {0}...' -f $kb)
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wusa.exe') -ArgumentList ('/uninstall /kb:{0} /norestart' -f $kbNum) -Wait -PassThru -WindowStyle Hidden
                $info = Get-ExitCodeInfo -Code $p.ExitCode -Tool 'wusa-uninstall'
                if ($info.Reboot) { $rebootNeeded = $true }
                if (-not $info.Ok) { $errCount++ }
                Write-Log ('wusa /uninstall {0} → exit code {1}: {2}' -f $kb, $p.ExitCode, $info.Text)
                if (-not $info.Ok) {
                    Write-Log ('Hint: some updates cannot be removed silently. Run it manually: wusa.exe /uninstall /kb:{0} /norestart (its window will show the reason).' -f $kbNum)
                }
            } elseif ($key -like 'dism|*') {
                $pkg = $key.Substring(5)
                Write-Log ('Uninstalling via DISM: {0}...' -f $pkg)
                Write-Status ('DISM /Remove-Package: {0}...' -f $pkg)
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -ArgumentList ('/Online /Quiet /NoRestart /Remove-Package /PackageName:"{0}"' -f $pkg) -Wait -PassThru
                $info = Get-ExitCodeInfo -Code $p.ExitCode -Tool 'dism-remove'
                if ($info.Reboot) { $rebootNeeded = $true }
                if (-not $info.Ok) { $errCount++ }
                Write-Log ('DISM /Remove-Package → exit code {0}: {1}' -f $p.ExitCode, $info.Text)
            } else {
                Write-Log ('Unknown uninstall key: {0} - skipped.' -f $key)
            }
        }
        if ($rebootNeeded) { $sync.RebootNeeded = $true }
        $sync.UninstallDone = $true
        Write-Log 'Uninstall: operation finished.'
    }

    # MODE: Cleanup leftovers of installed updates (run after the updates are tested).  Reclaims disk space: 1) superseded components in the WinSxS store via DISM /StartComponentCleanup - the engine behind the Disk Cleanup item "Windows Update Cleanup" (with $ResetBase also /ResetBase - afterwards updates can no longer be uninstalled); 2) Windows Update caches: SoftwareDistribution\Download (wuauserv/bits are stopped and restored to their previous state) and Delivery Optimization; 3) update files downloaded by this tool (wsusscn2.cab is kept)
    function Invoke-Cleanup {
        if (-not $IsAdmin) { throw 'Cleanup requires administrator rights. Restart the tool elevated.' }
        $freeBefore = [double](Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue).FreeSpace
        Write-Log ('Cleanup: started. Free space on {0}: {1:N1} GB.' -f $env:SystemDrive, ($freeBefore / 1GB))
        # 1) WinSxS superseded components (DISM output is captured; on failure its tail and the CBS log tail land in the log file)
        Write-Status 'Removing superseded components (WinSxS)...'
        Set-Progress 0 'DISM /StartComponentCleanup (WinSxS)'
        Write-Log 'Cleanup: removing superseded components from the WinSxS store (the Disk Cleanup "Windows Update Cleanup" engine); this may take 10-30 minutes.'
        if ($ResetBase) { Write-Log 'Cleanup: /ResetBase mode - after this run NO installed update can be uninstalled anymore.' }
        # a pending reboot from a recent install leaves uncommitted components in the store - StartComponentCleanup (especially with /ResetBase) often fails on them with access denied; surface the state before the long run
        if (Test-RebootPending) { Write-Log 'Cleanup: WARNING: a reboot is still pending from recent installations - StartComponentCleanup may fail on the not yet committed components (access denied). Reboot first when possible.' }
        $dismArgs = '/Online /NoRestart /Cleanup-Image /StartComponentCleanup'
        if ($ResetBase) { $dismArgs += ' /ResetBase' }
        # run DISM with its output captured to temp files: the old console window showed the text but closed and lost it, now the output tail lands in the log on failure
        $dismOut = Join-Path $env:TEMP ('wmuo-dism-out-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $dismErr = Join-Path $env:TEMP ('wmuo-dism-err-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -ArgumentList $dismArgs -WindowStyle Hidden -RedirectStandardOutput $dismOut -RedirectStandardError $dismErr -Wait -PassThru
        $sw.Stop()
        $dismText = @()
        try { $dismText = @(Get-Content -LiteralPath $dismOut -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $dismErr -ErrorAction SilentlyContinue) } catch { }
        Remove-Item -LiteralPath $dismOut, $dismErr -Force -ErrorAction SilentlyContinue
        $info = Get-ExitCodeInfo -Code $p.ExitCode -Tool 'dism-cleanup'
        if ($info.Reboot) { $sync.RebootNeeded = $true }
        if ($info.Ok) { Write-Log ('Cleanup: component store cleaned in {0:00} min {1:00} sec (DISM exit code {2}: {3}).' -f [int]$sw.Elapsed.TotalMinutes, $sw.Elapsed.Seconds, $p.ExitCode, $info.Text) }
        else {
            Write-Log ('Cleanup: DISM StartComponentCleanup failed - exit code {0}: {1}.' -f $p.ExitCode, $info.Text)
            Write-DismFailureDetails -DismOutput $dismText
            # access denied right after a big update usually means the servicing stack still has pending work - a retry after a reboot is the first thing to try
            if (Test-RebootPending) { Write-Log 'Cleanup: a reboot is currently pending - reboot and run the cleanup again.' }
        }
        if ($sync.Cancel) { throw $CancelMsg }
        # 2) Windows Update caches
        Write-Status 'Clearing the Windows Update cache...'
        Set-Progress 0.6 'Clearing SoftwareDistribution\Download'
        $wuCache = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        if (Test-Path -LiteralPath $wuCache) {
            $cacheBytes = [double](Get-ChildItem -LiteralPath $wuCache -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            Write-Log ('Cleanup: clearing the Windows Update download cache ({0:N1} MB).' -f ($cacheBytes / 1MB))
            $wasRunning = @{}
            foreach ($svc in @('wuauserv', 'bits')) { $wasRunning[$svc] = ((Get-Service -Name $svc -ErrorAction SilentlyContinue).Status -eq 'Running') }
            Stop-Service -Name @('wuauserv', 'bits') -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path $wuCache '*') -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($svc in @('wuauserv', 'bits')) { if ($wasRunning[$svc]) { Start-Service -Name $svc -ErrorAction SilentlyContinue } }
        } else { Write-Log 'Cleanup: SoftwareDistribution\Download not found - skipped.' }
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Log 'Cleanup: Delivery Optimization cache cleared.'
        } catch { Write-Log 'Cleanup: Delivery Optimization cache skipped (cmdlet unavailable or failed).' }
        if ($sync.Cancel) { throw $CancelMsg }
        # 3) Update files downloaded by this tool (the offline scan catalog is kept)
        Write-Status 'Removing downloaded update files...'
        Set-Progress 0.8 'Removing downloaded files'
        $updatesDir = Join-Path $WorkDir 'Updates'
        if (Test-Path -LiteralPath $updatesDir) {
            $leftovers = @(Get-ChildItem -LiteralPath $updatesDir -Force | Where-Object { $_.Name -ine 'wsusscn2.cab' })
            if ($leftovers.Count -gt 0) {
                $dlBytes = [double]0
                foreach ($lo in $leftovers) {
                    if ($lo.PSIsContainer) { $dlBytes += [double](Get-ChildItem -LiteralPath $lo.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
                    else { $dlBytes += [double]$lo.Length }
                }
                $leftovers | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log ('Cleanup: removed {0} downloaded item(s) from {1} ({2:N1} MB); wsusscn2.cab kept.' -f $leftovers.Count, $updatesDir, ($dlBytes / 1MB))
            } else { Write-Log 'Cleanup: no downloaded update files in the Updates folder.' }
        }
        Set-Progress 1 'Cleanup finished'
        $freeAfter = [double](Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue).FreeSpace
        Write-Log ('Cleanup: finished. Free space on {0}: {1:N1} GB (about {2:N1} GB reclaimed).' -f $env:SystemDrive, ($freeAfter / 1GB), (($freeAfter - $freeBefore) / 1GB))
        Write-Log 'Cleanup: run [Scan (offline)] again to refresh the download states in the update list.'
    }

    #  Dispatcher
    try {
        switch ($Mode) {
            $ModeGetCatalog { Set-Progress 0 'Checking wsusscn2.cab'; Get-CatalogFile | Out-Null; Write-Log 'Catalog is ready for the offline scan.' }
            $ModeScan { Invoke-Scan }
            $ModeDownload { Invoke-Download }
            $ModeInstall { Invoke-Install }
            $ModeListInstalled { Invoke-ListInstalled }
            $ModeUninstall { Invoke-Uninstall }
            $ModeCleanup { Invoke-Cleanup }
            $ModeDownloadQueue { Invoke-DownloadQueue }
        }
    } catch {
        if ($_.Exception.Message -eq $CancelMsg) {
            Write-Log 'Operation canceled by the user.'
        } else {
            Write-Log ('ERROR: {0}' -f $_.Exception.Message)
        }
    } finally {
        $sync.Status = ''
        $sync.Progress = -1
        $sync.ProgressText = ''
    }
}

#  GUI-thread functions: worker launch, list population, completion handling Launch the background runspace for the given mode and selections
function Start-Worker {
    param([string]$Mode, [string[]]$Selected = @(), [string[]]$UninstallSel = @(), [bool]$ResetBase = $false, [bool]$ForceRedl = $false)
    if ($sync.Busy) {
        Show-GuiMsg 'An operation is already running, please wait until it finishes.'
        return $false
    }
    $sync.Cancel = $false
    $sync.Busy = $true
    $script:WorkerMode = $Mode
    $sync.ScanDone = $false
    $sync.InstalledDone = $false
    $sync.UninstallDone = $false
    $sync.QueueDlDone = $false
    $sync.RebootNeeded = $false
    $sync.Status = ''
    $sync.Progress = 0
    $sync.ProgressText = ''
    $sync.ItemStatus.Clear()

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('WorkDir', $script:WorkDir)
    $rs.SessionStateProxy.SetVariable('Mode', $Mode)
    $rs.SessionStateProxy.SetVariable('CatalogFile', ([string]$txtCatalog.Text).Trim())
    $rs.SessionStateProxy.SetVariable('WsusServer', ([string]$txtWsus.Text).Trim())
    $rs.SessionStateProxy.SetVariable('Selected', ([string[]]@($Selected)))
    $rs.SessionStateProxy.SetVariable('UninstallSel', ([string[]]@($UninstallSel)))
    $rs.SessionStateProxy.SetVariable('QueueItems', @($script:DownloadQueue))
    $rs.SessionStateProxy.SetVariable('ForceRedl', [bool]$ForceRedl)
    $rs.SessionStateProxy.SetVariable('ResetBase', $ResetBase)
    $rs.SessionStateProxy.SetVariable('IsAdmin', $script:IsAdmin)
    $rs.SessionStateProxy.SetVariable('CatalogUrl', $script:CatalogUrl)
    $rs.SessionStateProxy.SetVariable('SearchCriteria', $script:SearchCriteria)
    $rs.SessionStateProxy.SetVariable('CancelMsg', $script:CancelMsg)
    # hand the shared constants (exit codes, source names, worker modes) to the worker runspace
    foreach ($cn in 'ExitRebootRequired', 'ExitRebootRequiredAlt', 'ExitRebootInitiated', 'ExitAlreadyInstalled', 'ExitBadCommandLine', 'SrcInternet', 'SrcWsus', 'ModeGetCatalog', 'ModeScan', 'ModeDownload', 'ModeInstall', 'ModeListInstalled', 'ModeUninstall', 'ModeCleanup', 'ModeDownloadQueue') { $rs.SessionStateProxy.SetVariable($cn, (Get-Variable -Name $cn -Scope Script).Value) }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:WorkerScript.ToString())
    $handle = $ps.BeginInvoke()
    $script:Worker = @{ PS = $ps; RS = $rs; Handle = $handle }
    Add-GuiLog ('Operation started: {0}.' -f $Mode)
    return $true
}

# Return the UUIDs of the checked rows in the available-updates list
function Get-CheckedUpdates {
    $sel = @()
    foreach ($item in $lvUpdates.CheckedItems) { $sel += ([string]$item.Tag) }
    return , $sel
}

# Return the keys of the checked rows in the installed-updates list
function Get-CheckedInstalled {
    $sel = @()
    foreach ($item in $lvInstalled.CheckedItems) { $sel += ([string]$item.Tag) }
    return , $sel
}

# Fill the available-updates list from the last scan result
function Update-UpdatesList {
    $lvUpdates.BeginUpdate()
    $lvUpdates.Items.Clear()
    $script:ItemMap.Clear()
    $script:ItemStatusBase.Clear()
    foreach ($it in $sync.Result) {
        $lvi = New-Object System.Windows.Forms.ListViewItem([string]$it.KB)
        [void]$lvi.SubItems.Add([string]$it.Title)
        [void]$lvi.SubItems.Add([string]$it.SizeMB)
        [void]$lvi.SubItems.Add([string]$it.Date)
        [void]$lvi.SubItems.Add([string]$it.Reboot)
        $status = ''
        if ($it.DownloadedAll) { $status = 'files already downloaded' }
        elseif ($it.Note) { $status = $it.Note }
        [void]$lvi.SubItems.Add($status)
        $script:ItemStatusBase[[string]$it.UUID] = $status
        $lvi.Tag = [string]$it.UUID
        $lvi.Checked = ($it.Urls.Count -gt 0)
        if ($it.Urls.Count -eq 0) { $lvi.ForeColor = [System.Drawing.Color]::Gray }
        if ($it.Description) { $lvi.ToolTipText = $it.Description }
        [void]$lvUpdates.Items.Add($lvi)
        $script:ItemMap[[string]$it.UUID] = $lvi
    }
    $lvUpdates.EndUpdate()
    Update-QueueMarkers
    $tabs.SelectedTab = $tabUpdates
    Add-GuiLog ('Update list: {0} entries. Checked by default are the ones with direct download URLs.' -f $sync.Result.Count)
}

# Fill the installed-updates list from the last inventory result
function Update-InstalledList {
    $lvInstalled.BeginUpdate()
    $lvInstalled.Items.Clear()
    foreach ($it in $sync.InstalledList) {
        $lvi = New-Object System.Windows.Forms.ListViewItem([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Desc)
        [void]$lvi.SubItems.Add([string]$it.Type)
        [void]$lvi.SubItems.Add([string]$it.Date)
        $lvi.Tag = [string]$it.Key
        [void]$lvInstalled.Items.Add($lvi)
    }
    $lvInstalled.EndUpdate()
    $tabs.SelectedTab = $tabInstalled
    Add-GuiLog ('Installed updates list: {0} entries.' -f $sync.InstalledList.Count)
}

# Fill the download-queue list from the persistent queue (download-queue.json)
function Update-QueueList {
    $lvQueue.BeginUpdate()
    $lvQueue.Items.Clear()
    $script:QueueMap.Clear()
    $updatesDir = Join-Path $script:WorkDir 'Updates'
    foreach ($it in $script:DownloadQueue) {
        $dir = Join-Path $updatesDir (Get-QueueDirName $it)
        $urls = @($it.Urls)
        $total = $urls.Count
        $have = 0
        foreach ($u in $urls) {
            if (Test-Path -LiteralPath (Join-Path $dir (Get-UrlFileName ([string]$u)))) { $have++ }
        }
        $lvi = New-Object System.Windows.Forms.ListViewItem([string]$it.KB)
        [void]$lvi.SubItems.Add([string]$it.Title)
        [void]$lvi.SubItems.Add([string]$it.SizeMB)
        [void]$lvi.SubItems.Add([string]$it.Date)
        [void]$lvi.SubItems.Add(('{0}/{1}' -f $have, $total))
        $status = 'waiting for download'
        if ($total -eq 0) { $status = 'no direct file URL' }
        elseif ($have -eq $total) { $status = 'files already downloaded' }
        # a final status of the last download run (if this item took part in it) wins over the computed one
        if ($sync.ItemStatus.ContainsKey([string]$it.UUID)) { $status = [string]$sync.ItemStatus[[string]$it.UUID] }
        [void]$lvi.SubItems.Add($status)
        $lvi.Tag = [string]$it.UUID
        if ($it.Description) { $lvi.ToolTipText = $it.Description }
        [void]$lvQueue.Items.Add($lvi)
        $script:QueueMap[[string]$it.UUID] = $lvi
    }
    $lvQueue.EndUpdate()
    $lblQueueHint.Text = ('In queue: {0} (saved to download-queue.json)' -f $script:DownloadQueue.Count)
}

# Append/remove the " [queued]" marker on the available-updates rows
function Update-QueueMarkers {
    $queued = @{}
    foreach ($q in $script:DownloadQueue) { $queued[[string]$q.UUID] = $true }
    foreach ($key in @($script:ItemMap.Keys)) {
        $lvi = $script:ItemMap[$key]
        if (-not $lvi) { continue }
        $txt = ''
        if ($script:ItemStatusBase.ContainsKey([string]$key)) { $txt = [string]$script:ItemStatusBase[[string]$key] }
        if ($queued.ContainsKey([string]$key)) { $txt = if ($txt) { '{0} [queued]' -f $txt } else { '[queued]' } }
        $lvi.SubItems[5].Text = $txt
    }
}

# Handle completion of the background runspace (populate lists, prompt for reboot)
function Receive-WorkerFinished {
    $scanJustDone = $false
    if ($sync.ScanDone) {
        $sync.ScanDone = $false
        $script:HaveScanResults = $true
        $scanJustDone = $true
        Update-UpdatesList
    }
    if ($sync.InstalledDone) {
        $sync.InstalledDone = $false
        $script:HaveInstalledList = $true
        Update-InstalledList
    }
    if ($sync.UninstallDone) {
        $sync.UninstallDone = $false
        Add-GuiLog 'Press [Refresh list] to see the current state of installed updates.'
    }
    if ($sync.QueueDlDone) {
        $sync.QueueDlDone = $false
        Update-QueueList
        $tabs.SelectedTab = $tabQueue
    }

    # One-click chain (the [Scan + Install] button): start the next step automatically once the current worker has finished; the chain is armed only by that button and disarms itself before the install step is launched
    if ($script:AutoChain) {
        if ($sync.Cancel) {
            $script:AutoChain = $false
            Add-GuiLog 'One-click run: cancellation was requested - the remaining steps are not started.'
        } elseif ($scanJustDone) {
            # the scan rebuilt the list and re-checked the updates with direct file URLs: download the checked ones whose files are not on disk yet, or go straight to the install
            $sel = Get-CheckedUpdates
            $missing = @()
            foreach ($uuid in $sel) {
                foreach ($it in $sync.Result) {
                    if ($it.UUID -eq $uuid) {
                        if (-not $it.DownloadedAll) { $missing += $uuid }
                        break
                    }
                }
            }
            if ($sel.Count -eq 0) {
                $script:AutoChain = $false
                Add-GuiLog 'One-click run: nothing is checked after the scan - the installation is not started.'
            } elseif ($missing.Count -gt 0) {
                Add-GuiLog ('One-click run: {0} of {1} checked update(s) still miss their files - downloading them first.' -f $missing.Count, $sel.Count)
                # disarm first and re-arm after a successful launch: a refused launch must never leave the chain armed
                $script:AutoChain = $false
                if (Start-Worker -Mode $script:ModeDownload -Selected $sel) { $script:AutoChain = $true }
            } else {
                $script:AutoChain = $false
                Add-GuiLog ('One-click run: all files are already on disk - installing {0} update(s). Do not close the window until it finishes.' -f $sel.Count)
                [void](Start-Worker -Mode $script:ModeInstall -Selected $sel)
            }
        } elseif ($script:WorkerMode -eq $script:ModeDownload) {
            # the download step of the one-click run has finished - install whatever is still checked (items whose files failed to download are skipped by the install itself)
            $script:AutoChain = $false
            $sel = Get-CheckedUpdates
            if ($sel.Count -eq 0) {
                Add-GuiLog 'One-click run: nothing is checked - the installation is not started.'
            } else {
                Add-GuiLog ('One-click run: download step finished - installing {0} update(s). Do not close the window until it finishes.' -f $sel.Count)
                [void](Start-Worker -Mode $script:ModeInstall -Selected $sel)
            }
        } else {
            # the scan step did not complete (its error is already in the log) - stop the chain
            $script:AutoChain = $false
            Add-GuiLog 'One-click run: the scan step did not complete - the following steps are skipped.'
        }
    }
    # Uncheck updates that were installed without errors
    $okIds = @()
    $tmp = $null
    while ($sync.InstalledOk.TryDequeue([ref]$tmp)) { $okIds += $tmp }
    foreach ($k in $okIds) {
        $lvi = $script:ItemMap[$k]
        if ($lvi -and $lvi.Checked) {
            $lvi.Checked = $false
            Add-GuiLog ('{0}: unchecked (installed successfully).' -f $lvi.Text)
        }
    }

    if ($sync.RebootNeeded) {
        $sync.RebootNeeded = $false
        $ans = [System.Windows.Forms.MessageBox]::Show($form, "The operation finished, but a reboot is required.`n`nReboot the computer now (in 30 seconds)?", 'Reboot required', 'YesNo', 'Question')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            Add-GuiLog 'Reboot command sent (shutdown /r /t 30).'
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/r /t 30 /c "WU Offline Tool: updates were installed, a reboot is required"' | Out-Null
        } else {
            Add-GuiLog 'Remember to reboot the computer to finish the installation.'
        }
    }
}

#  GUI (WinForms)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Windows Manual Update Offline Tool One - Offline Update Manager. $($Script:version)"
$form.Size = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Row 1: wsusscn2.cab catalog ---
$panelCatalog = New-Object System.Windows.Forms.TableLayoutPanel
$panelCatalog.Dock = 'Top'
$panelCatalog.Height = 34
$panelCatalog.ColumnCount = 4
$panelCatalog.RowCount = 1
$panelCatalog.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)
[void]$panelCatalog.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute, 190)))
[void]$panelCatalog.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelCatalog.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelCatalog.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelCatalog.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))

$lblCatalog = New-Object System.Windows.Forms.Label
$lblCatalog.Text = 'Catalog wsusscn2.cab:'
$lblCatalog.TextAlign = 'MiddleLeft'
$lblCatalog.Dock = 'Fill'
$txtCatalog = New-Object System.Windows.Forms.TextBox
$txtCatalog.Dock = 'Fill'
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $txtCatalog.Text = Join-Path $script:WorkDir 'updates\wsusscn2.cab'
} else {
    $txtCatalog.Text = $CatalogPath
}
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.AutoSize = $true
$btnCatalogDl = New-Object System.Windows.Forms.Button
$btnCatalogDl.Text = 'Check / download catalog'
$btnCatalogDl.AutoSize = $true
$panelCatalog.Controls.Add($lblCatalog, 0, 0)
$panelCatalog.Controls.Add($txtCatalog, 1, 0)
$panelCatalog.Controls.Add($btnBrowse, 2, 0)
$panelCatalog.Controls.Add($btnCatalogDl, 3, 0)

# --- Row 2: optional WSUS download source ---
$panelWsus = New-Object System.Windows.Forms.TableLayoutPanel
$panelWsus.Dock = 'Top'
$panelWsus.Height = 34
$panelWsus.ColumnCount = 3
$panelWsus.RowCount = 1
$panelWsus.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 0)
[void]$panelWsus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute, 190)))
[void]$panelWsus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelWsus.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelWsus.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))

$lblWsus = New-Object System.Windows.Forms.Label
$lblWsus.Text = 'WSUS source (optional):'
$lblWsus.TextAlign = 'MiddleLeft'
$lblWsus.Dock = 'Fill'
$txtWsus = New-Object System.Windows.Forms.TextBox
$txtWsus.Dock = 'Fill'
$txtWsus.Text = $WsusServer
$lblWsusHint = New-Object System.Windows.Forms.Label
$lblWsusHint.Text = 'empty = Internet CDN'
$lblWsusHint.TextAlign = 'MiddleLeft'
$lblWsusHint.Dock = 'Fill'
$lblWsusHint.AutoEllipsis = $true
$lblWsusHint.ForeColor = [System.Drawing.Color]::Gray
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($txtWsus, "WSUS download source, used for DOWNLOADS only (the scan always stays offline).`nExamples: http://wsus:8530  |  http://wsus  |  \\wsus\wsus$\WSUSContent`nFiles missing on the WSUS server are automatically downloaded from the Internet instead.")
$panelWsus.Controls.Add($lblWsus, 0, 0)
$panelWsus.Controls.Add($txtWsus, 1, 0)
$panelWsus.Controls.Add($lblWsusHint, 2, 0)

# Align the WSUS input width with the catalog input: the hint label column gets the same trailing width the catalog row spends on its two buttons, so both text boxes are equally wide at any window size (measured once after the form is shown, when the AutoSize button widths are known)
$form.Add_Shown({
        $trail = $btnBrowse.Width + $btnCatalogDl.Width + 6
        if ($trail -gt 60) {
            $panelWsus.ColumnStyles[2] = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $trail)
            $panelWsus.PerformLayout()
        }
    })

# --- Row 3: action buttons ---
$panelButtons = New-Object System.Windows.Forms.TableLayoutPanel
$panelButtons.Dock = 'Top'
$panelButtons.Height = 36
$panelButtons.ColumnCount = 10
$panelButtons.RowCount = 1
$panelButtons.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelButtons.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = 'Scan (offline)'
$btnScan.AutoSize = $true
$toolTip.SetToolTip($btnScan, "Offline scan against the local wsusscn2.cab catalog.`nRequires administrator rights: the scan registers its offline scan package in the Windows Update service store (HKLM).")
$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = 'Download selected'
$btnDownload.AutoSize = $true
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Install selected'
$btnInstall.AutoSize = $true
$btnScanInstall = New-Object System.Windows.Forms.Button
$btnScanInstall.Text = 'Scan + Install'
$btnScanInstall.AutoSize = $true
$toolTip.SetToolTip($btnScanInstall, "One-click run: offline scan, then download of the still-missing files, then install of everything that stays checked.`nPress it once and come back when the log stops - no extra confirmations in between.")
$btnMarkAll = New-Object System.Windows.Forms.Button
$btnMarkAll.Text = 'Mark all'
$btnMarkAll.AutoSize = $true
$btnClearAll = New-Object System.Windows.Forms.Button
$btnClearAll.Text = 'Unmark all'
$btnClearAll.AutoSize = $true
$btnCleanup = New-Object System.Windows.Forms.Button
$btnCleanup.Text = 'Cleanup leftovers'
$btnCleanup.AutoSize = $true
$btnOpenDir = New-Object System.Windows.Forms.Button
$btnOpenDir.Text = 'Folder'
$btnOpenDir.AutoSize = $true
$btnCancelOp = New-Object System.Windows.Forms.Button
$btnCancelOp.Text = 'Cancel'
$btnCancelOp.AutoSize = $true
$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = 'About'
$btnAbout.AutoSize = $true
$panelButtons.Controls.Add($btnScan, 0, 0)
$panelButtons.Controls.Add($btnDownload, 1, 0)
$panelButtons.Controls.Add($btnInstall, 2, 0)
$panelButtons.Controls.Add($btnScanInstall, 3, 0)
$panelButtons.Controls.Add($btnMarkAll, 4, 0)
$panelButtons.Controls.Add($btnClearAll, 5, 0)
$panelButtons.Controls.Add($btnCleanup, 6, 0)
$panelButtons.Controls.Add($btnOpenDir, 7, 0)
$panelButtons.Controls.Add($btnCancelOp, 8, 0)
$panelButtons.Controls.Add($btnAbout, 9, 0)

# --- Tabs ---
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabUpdates = New-Object System.Windows.Forms.TabPage
$tabUpdates.Text = 'Available updates'
$tabInstalled = New-Object System.Windows.Forms.TabPage
$tabInstalled.Text = 'Installed (uninstall)'
$tabQueue = New-Object System.Windows.Forms.TabPage
$tabQueue.Text = 'Download queue'

$lvUpdates = New-Object System.Windows.Forms.ListView
$lvUpdates.Dock = 'Fill'
$lvUpdates.View = 'Details'
$lvUpdates.CheckBoxes = $true
$lvUpdates.FullRowSelect = $true
$lvUpdates.HideSelection = $false
$lvUpdates.ShowItemToolTips = $true
[void]$lvUpdates.Columns.Add('KB', 100)
[void]$lvUpdates.Columns.Add('Update', 420)
$colSize = New-Object System.Windows.Forms.ColumnHeader
$colSize.Text = 'Size, MB'
$colSize.Width = 90
$colSize.TextAlign = 'Right'
[void]$lvUpdates.Columns.Add($colSize)
[void]$lvUpdates.Columns.Add('Date', 85)
[void]$lvUpdates.Columns.Add('Reboot', 105)
[void]$lvUpdates.Columns.Add('Status / files', 260)
Enable-LvDoubleBuffer $lvUpdates

# Queue button above the available-updates list: adds the checked updates to the persistent download queue
$panelUpd = New-Object System.Windows.Forms.TableLayoutPanel
$panelUpd.Dock = 'Top'
$panelUpd.Height = 34
$panelUpd.ColumnCount = 2
$panelUpd.RowCount = 1
$panelUpd.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
[void]$panelUpd.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelUpd.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelUpd.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
$btnAddQueue = New-Object System.Windows.Forms.Button
$btnAddQueue.Text = 'Add checked to queue'
$btnAddQueue.AutoSize = $true
$lblUpdHint = New-Object System.Windows.Forms.Label
$lblUpdHint.Text = 'Queue the checked updates for downloading on another (online) computer - see the "Download queue" tab.'
$lblUpdHint.TextAlign = 'MiddleLeft'
$lblUpdHint.Dock = 'Fill'
$lblUpdHint.ForeColor = [System.Drawing.Color]::Gray
$toolTip.SetToolTip($btnAddQueue, "Adds the checked updates to the persistent download queue (download-queue.json).`nUse this on the OFFLINE computer: the scan finds the updates, the queue stores their direct download URLs, and the files are fetched later on a computer with Internet access ([Download queue] on the next tab).")
$panelUpd.Controls.Add($btnAddQueue, 0, 0)
$panelUpd.Controls.Add($lblUpdHint, 1, 0)

[void]$tabUpdates.Controls.Add($lvUpdates)
[void]$tabUpdates.Controls.Add($panelUpd)

$panelInst = New-Object System.Windows.Forms.TableLayoutPanel
$panelInst.Dock = 'Top'
$panelInst.Height = 34
$panelInst.ColumnCount = 3
$panelInst.RowCount = 1
$panelInst.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
[void]$panelInst.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelInst.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelInst.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelInst.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
$btnRefreshInst = New-Object System.Windows.Forms.Button
$btnRefreshInst.Text = 'Refresh list'
$btnRefreshInst.AutoSize = $true
$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = 'Uninstall selected'
$btnUninstall.AutoSize = $true
$lblInstHint = New-Object System.Windows.Forms.Label
$lblInstHint.Text = 'QFE entries are removed via wusa /uninstall; DISM packages via DISM /Remove-Package.'
$lblInstHint.TextAlign = 'MiddleLeft'
$lblInstHint.Dock = 'Fill'
$panelInst.Controls.Add($btnRefreshInst, 0, 0)
$panelInst.Controls.Add($btnUninstall, 1, 0)
$panelInst.Controls.Add($lblInstHint, 2, 0)

$lvInstalled = New-Object System.Windows.Forms.ListView
$lvInstalled.Dock = 'Fill'
$lvInstalled.View = 'Details'
$lvInstalled.CheckBoxes = $true
$lvInstalled.FullRowSelect = $true
$lvInstalled.HideSelection = $false
[void]$lvInstalled.Columns.Add('Item', 300)
[void]$lvInstalled.Columns.Add('Description', 240)
[void]$lvInstalled.Columns.Add('Type', 170)
[void]$lvInstalled.Columns.Add('Installed on', 120)
Enable-LvDoubleBuffer $lvInstalled
[void]$tabInstalled.Controls.Add($lvInstalled)
[void]$tabInstalled.Controls.Add($panelInst)

# --- Download queue tab: the queue filled on the offline computer, downloaded on the online one ---
$panelQueue = New-Object System.Windows.Forms.TableLayoutPanel
$panelQueue.Dock = 'Top'
$panelQueue.Height = 34
$panelQueue.ColumnCount = 5
$panelQueue.RowCount = 1
$panelQueue.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
[void]$panelQueue.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelQueue.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelQueue.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelQueue.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize)))
[void]$panelQueue.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$panelQueue.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent, 100)))
$btnQueueDl = New-Object System.Windows.Forms.Button
$btnQueueDl.Text = 'Download queue'
$btnQueueDl.AutoSize = $true
$btnQueueRemove = New-Object System.Windows.Forms.Button
$btnQueueRemove.Text = 'Remove selected'
$btnQueueRemove.AutoSize = $true
$btnQueueClear = New-Object System.Windows.Forms.Button
$btnQueueClear.Text = 'Clear queue'
$btnQueueClear.AutoSize = $true
$btnQueueForce = New-Object System.Windows.Forms.Button
$btnQueueForce.Text = 'Force re-download'
$btnQueueForce.AutoSize = $true
$lblQueueHint = New-Object System.Windows.Forms.Label
$lblQueueHint.Text = 'In queue: 0'
$lblQueueHint.TextAlign = 'MiddleLeft'
$lblQueueHint.Dock = 'Fill'
$lblQueueHint.ForeColor = [System.Drawing.Color]::Gray
$toolTip.SetToolTip($btnQueueDl, "Downloads every queued update into the Updates folder from its stored direct URLs (Microsoft CDN or the configured WSUS source).`nRun this on a computer WITH Internet access - no elevation, no catalog and no scan are needed there.`nThe file names and subfolders are the same as on the target computer, so after copying the Updates folder back and re-scanning there the updates are ready to install.")
$toolTip.SetToolTip($btnQueueRemove, "Removes the checked entries from the queue (already downloaded files stay on disk).`nThe queue is saved to download-queue.json immediately.")
$toolTip.SetToolTip($btnQueueClear, 'Removes ALL entries from the queue (already downloaded files stay on disk).')
$toolTip.SetToolTip($btnQueueForce, "Re-downloads ALL queued updates from scratch, even when intact copies (matching SHA-1 checksums) are already in the Updates folder.`nUse this only if you suspect a downloaded file is damaged despite passing the checksum, or when you need fresh copies for sure.`nThe previous copy of a file is overwritten only after the new download finishes successfully, so a failed attempt keeps the old file.")
$panelQueue.Controls.Add($btnQueueDl, 0, 0)
$panelQueue.Controls.Add($btnQueueRemove, 1, 0)
$panelQueue.Controls.Add($btnQueueClear, 2, 0)
$panelQueue.Controls.Add($btnQueueForce, 3, 0)
$panelQueue.Controls.Add($lblQueueHint, 4, 0)

$lvQueue = New-Object System.Windows.Forms.ListView
$lvQueue.Dock = 'Fill'
$lvQueue.View = 'Details'
$lvQueue.CheckBoxes = $true
$lvQueue.FullRowSelect = $true
$lvQueue.HideSelection = $false
$lvQueue.ShowItemToolTips = $true
[void]$lvQueue.Columns.Add('KB', 100)
[void]$lvQueue.Columns.Add('Update', 420)
$colQSize = New-Object System.Windows.Forms.ColumnHeader
$colQSize.Text = 'Size, MB'
$colQSize.Width = 90
$colQSize.TextAlign = 'Right'
[void]$lvQueue.Columns.Add($colQSize)
[void]$lvQueue.Columns.Add('Date', 85)
[void]$lvQueue.Columns.Add('Files', 70)
[void]$lvQueue.Columns.Add('Status / files', 260)
Enable-LvDoubleBuffer $lvQueue
[void]$tabQueue.Controls.Add($lvQueue)
[void]$tabQueue.Controls.Add($panelQueue)

[void]$tabs.TabPages.Add($tabUpdates)
[void]$tabs.TabPages.Add($tabInstalled)
[void]$tabs.TabPages.Add($tabQueue)

# --- Log panel ---
$panelLog = New-Object System.Windows.Forms.Panel
$panelLog.Dock = 'Bottom'
$panelLog.Height = 150
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.Dock = 'Fill'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
[void]$panelLog.Controls.Add($txtLog)

# --- Status strip ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = 'Ready'
$lblStatus.Spring = $true
$lblStatus.TextAlign = 'MiddleLeft'
$pbStatus = New-Object System.Windows.Forms.ToolStripProgressBar
$pbStatus.Width = 220
$lblProgress = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblProgress.Text = ''
$lblProgress.AutoSize = $true
[void]$statusStrip.Items.AddRange(@($lblStatus, $pbStatus, $lblProgress))

# Add order matters: Dock layout is processed from the end of the list
[void]$form.Controls.Add($tabs)
[void]$form.Controls.Add($panelButtons)
[void]$form.Controls.Add($panelWsus)
[void]$form.Controls.Add($panelCatalog)
[void]$form.Controls.Add($panelLog)
[void]$form.Controls.Add($statusStrip)

#  Event handlers
$btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select the wsusscn2.cab catalog file'
        $dlg.Filter = 'Catalog file (*.cab)|*.cab|All files (*.*)|*.*'
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtCatalog.Text = $dlg.FileName
        }
    })

$btnCatalogDl.Add_Click({ [void](Start-Worker -Mode $script:ModeGetCatalog) })

$btnScan.Add_Click({
        $script:AutoChain = $false    # a plain scan must never chain into the download/install steps
        Add-GuiLog ('Starting the offline scan. Catalog: "{0}" (empty = the local copy in the working folder, or a download).' -f $txtCatalog.Text)
        [void](Start-Worker -Mode $script:ModeScan)
    })

$btnDownload.Add_Click({
        $sel = Get-CheckedUpdates
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the updates you want to download first.'; return }
        [void](Start-Worker -Mode $script:ModeDownload -Selected $sel)
    })

$btnInstall.Add_Click({
        $sel = Get-CheckedUpdates
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the updates you want to install first.'; return }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ("Install the selected updates ({0} items)?`n`nPackages are applied locally via wusa/DISM without contacting Windows Update. Do not close the window until it finishes." -f $sel.Count), 'Confirm installation', 'YesNo', 'Question')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-Worker -Mode $script:ModeInstall -Selected $sel)
        }
    })

$btnScanInstall.Add_Click({
        Add-GuiLog ('Starting the one-click run: offline scan, then download of the still-missing files, then install of everything still checked. Catalog: "{0}" (empty = the local copy in the working folder, or a download).' -f $txtCatalog.Text)
        # the chain flag makes the completion handler run the download/install steps by itself - no confirmation dialogs, so the run can be left unattended
        if (Start-Worker -Mode $script:ModeScan) { $script:AutoChain = $true }
    })

$btnMarkAll.Add_Click({ foreach ($item in $lvUpdates.Items) { $item.Checked = $true } })
$btnClearAll.Add_Click({ foreach ($item in $lvUpdates.Items) { $item.Checked = $false } })

$btnOpenDir.Add_Click({
        try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:WorkDir) | Out-Null } catch { }
    })

$btnCancelOp.Add_Click({
        $sync.Cancel = $true
        Add-GuiLog 'Cancellation requested: it takes effect between files/packages (the WUA scan itself cannot be interrupted).'
    })

# About dialog: project info plus a clickable GitHub link
$btnAbout.Add_Click({
        $about = New-Object System.Windows.Forms.Form
        $about.Text = 'About'
        $about.FormBorderStyle = 'FixedDialog'
        $about.StartPosition = 'CenterParent'
        $about.ClientSize = New-Object System.Drawing.Size(504, 302)
        $about.MaximizeBox = $false
        $about.MinimizeBox = $false
        $about.ShowInTaskbar = $false
        $about.Font = $form.Font
        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(12, 12)
        $txt.Size = New-Object System.Drawing.Size(480, 195)
        $txt.Text = ("Windows Manual Update Offline Tool One`nVersion: {0}`nAuthor: Andrew Afanasiev (AfanasievAA@yandex.ru)`n`nManual update install/uninstall manager for Windows without automatic updates: offline scan against a local wsusscn2.cab catalog, download (Internet CDN or a WSUS server), local install via wusa/DISM/msiexec, uninstall, and a persistent download queue for moving update files from an offline to an online computer.`n`nProject page:" -f $Script:version)
        [void]$about.Controls.Add($txt)
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Location = New-Object System.Drawing.Point(12, 215)
        $link.Size = New-Object System.Drawing.Size(480, 22)
        $link.Text = 'https://github.com/AfanasievAA/WinManUpdateTool1'
        $link.Add_LinkClicked({ try { Start-Process ('https://github.com/AfanasievAA/WinManUpdateTool1') | Out-Null } catch { } })
        [void]$about.Controls.Add($link)
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'OK'
        $btnOk.DialogResult = 'OK'
        # anchored to the bottom-right corner and placed with a margin, so DPI/font scaling can no longer push the button half out of the dialog
        $btnOk.Location = New-Object System.Drawing.Point(415, 263)
        $btnOk.Anchor = 'Bottom, Right'
        [void]$about.Controls.Add($btnOk)
        $about.AcceptButton = $btnOk
        [void]$about.ShowDialog($form)
    })

$btnRefreshInst.Add_Click({ [void](Start-Worker -Mode $script:ModeListInstalled) })

$btnUninstall.Add_Click({
        $sel = Get-CheckedInstalled
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the packages you want to uninstall first.'; return }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ("Uninstall the selected entries ({0} items)?`n`nA reboot may be required afterwards." -f $sel.Count), 'Confirm uninstall', 'YesNo', 'Warning')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-Worker -Mode $script:ModeUninstall -UninstallSel $sel)
        }
    })

# Add the checked scan results to the persistent download queue (download-queue.json)
$btnAddQueue.Add_Click({
        $sel = Get-CheckedUpdates
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the updates you want to add to the download queue first.'; return }
        $added = 0
        $refreshed = 0
        $skipped = 0
        foreach ($it in $sync.Result) {
            if ($sel -notcontains [string]$it.UUID) { continue }
            if (-not $it.Urls -or @($it.Urls).Count -eq 0) {
                Add-GuiLog ('{0}: has no direct file URLs - it cannot be downloaded on another computer, not queued.' -f $it.KB)
                $skipped++
                continue
            }
            $entry = @{
                UUID = [string]$it.UUID; KB = [string]$it.KB; Title = [string]$it.Title
                Description = [string]$it.Description; SizeMB = $it.SizeMB; Date = [string]$it.Date
                Reboot = [string]$it.Reboot; Urls = @($it.Urls)
                DirName = (Split-Path -Leaf ([string]$it.Dir))
                AddedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $existingIdx = -1
            for ($i = 0; $i -lt $script:DownloadQueue.Count; $i++) {
                if ([string]$script:DownloadQueue[$i].UUID -eq [string]$it.UUID) { $existingIdx = $i; break }
            }
            if ($existingIdx -ge 0) {
                # the update was scanned again: refresh its stored data (fresh URLs), keep the queue position
                $script:DownloadQueue[$existingIdx] = $entry
                $refreshed++
            } else {
                $script:DownloadQueue += $entry
                $added++
            }
        }
        Save-Queue
        Update-QueueList
        Update-QueueMarkers
        Add-GuiLog ('Download queue: {0} added, {1} refreshed (re-scanned), {2} skipped without URLs, total {3}. Saved to {4}.' -f $added, $refreshed, $skipped, $script:DownloadQueue.Count, $script:QueueFile)
    })

$btnQueueDl.Add_Click({
        if ($script:DownloadQueue.Count -eq 0) {
            Show-GuiMsg 'The download queue is empty. On the offline computer scan the updates and press [Add checked to queue], then move the project folder here.'
            return
        }
        [void](Start-Worker -Mode $script:ModeDownloadQueue)
    })

$btnQueueForce.Add_Click({
        if ($script:DownloadQueue.Count -eq 0) {
            Show-GuiMsg 'The download queue is empty. On the offline computer scan the updates and press [Add checked to queue], then move the project folder here.'
            return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ('Re-download ALL {0} queued updates from scratch, overwriting the existing copies?`n`nUse this only when you suspect a downloaded file is damaged despite passing the checksum check. A failed download keeps the previous file.' -f $script:DownloadQueue.Count), 'Force re-download', 'YesNo', 'Warning')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        [void](Start-Worker -Mode $script:ModeDownloadQueue -ForceRedl:$true)
    })

$btnQueueRemove.Add_Click({
        $sel = @()
        foreach ($item in $lvQueue.CheckedItems) { $sel += ([string]$item.Tag) }
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the queue entries you want to remove first.'; return }
        $kept = @()
        foreach ($q in $script:DownloadQueue) {
            if ($sel -notcontains [string]$q.UUID) { $kept += $q }
        }
        $removed = $script:DownloadQueue.Count - $kept.Count
        $script:DownloadQueue = $kept
        Save-Queue
        Update-QueueList
        Update-QueueMarkers
        Add-GuiLog ('Download queue: removed {0} item(s), {1} left.' -f $removed, $script:DownloadQueue.Count)
    })

$btnQueueClear.Add_Click({
        if ($script:DownloadQueue.Count -eq 0) { return }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ('Remove ALL {0} entries from the download queue? (The already downloaded files stay on disk.)' -f $script:DownloadQueue.Count), 'Clear download queue', 'YesNo', 'Question')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:DownloadQueue = @()
        Save-Queue
        Update-QueueList
        Update-QueueMarkers
        Add-GuiLog 'Download queue: cleared.'
    })

$btnCleanup.Add_Click({
        $ans = [System.Windows.Forms.MessageBox]::Show($form, "Clean up update leftovers?`n`n1) Superseded components in the WinSxS store - the Disk Cleanup 'Windows Update Cleanup' engine (DISM /StartComponentCleanup); superseded updates can NO LONGER be uninstalled afterwards.`n2) Windows Update caches (SoftwareDistribution\Download + Delivery Optimization).`n3) Update files downloaded by this tool (wsusscn2.cab is kept).`n`nRun this only after the installed updates are TESTED.", 'Confirm cleanup', 'YesNo', 'Question')
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $rb = [System.Windows.Forms.MessageBox]::Show($form, "Also run the deep cleanup (/ResetBase)?`n`nIt removes ALL superseded component versions - afterwards NO installed update can be uninstalled at all.", 'Deep cleanup (ResetBase)', 'YesNo', 'Warning', [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        [void](Start-Worker -Mode $script:ModeCleanup -ResetBase ($rb -eq [System.Windows.Forms.DialogResult]::Yes))
    })

$form.Add_FormClosing({
        if ($sync.Busy) {
            $ans = [System.Windows.Forms.MessageBox]::Show($form, 'An operation is still running. Cancel it and exit?', 'WU Offline Tool', 'YesNo', 'Warning')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
                $_.Cancel = $true
                return
            }
            $sync.Cancel = $true
        }
    })

$form.Add_FormClosed({
        Receive-LogQueue
        # Persist the WSUS source (and future settings) to settings.json on exit
        Save-Settings @{ wsusServer = ([string]$txtWsus.Text).Trim() }
        # Persist the download queue: it travels with the project folder to the online computer
        Save-Queue
    })

# --- State polling timer (GUI thread) ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
        Receive-LogQueue

        if ($sync.Status) { $lblStatus.Text = $sync.Status } else { $lblStatus.Text = 'Ready' }
        if ($sync.Progress -ge 0) { $pbStatus.Value = [Math]::Min(100, $sync.Progress) } else { $pbStatus.Value = 0 }
        $lblProgress.Text = $sync.ProgressText

        $busy = $sync.Busy
        $btnScan.Enabled = (-not $busy) -and $script:IsAdmin
        $btnDownload.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnInstall.Enabled = (-not $busy) -and $script:HaveScanResults -and $script:IsAdmin
        $btnScanInstall.Enabled = (-not $busy) -and $script:IsAdmin
        $btnCatalogDl.Enabled = (-not $busy)
        $btnMarkAll.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnClearAll.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnRefreshInst.Enabled = (-not $busy)
        $btnUninstall.Enabled = (-not $busy) -and $script:HaveInstalledList -and $script:IsAdmin
        $btnCleanup.Enabled = (-not $busy) -and $script:IsAdmin
        $btnAddQueue.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnQueueDl.Enabled = (-not $busy)
        $btnQueueRemove.Enabled = (-not $busy)
        $btnQueueClear.Enabled = (-not $busy)
        $btnQueueForce.Enabled = (-not $busy)

        if ($sync.ItemStatus.Count -gt 0) {
            foreach ($key in @($sync.ItemStatus.Keys)) {
                $lvi = $script:ItemMap[$key]
                if ($lvi) { $lvi.SubItems[5].Text = [string]$sync.ItemStatus[$key] }
                $lviQ = $script:QueueMap[$key]
                if ($lviQ) { $lviQ.SubItems[5].Text = [string]$sync.ItemStatus[$key] }
            }
        }

        $w = $script:Worker
        if ($w -and $w.Handle.IsCompleted) {
            try { $null = $w.PS.EndInvoke($w.Handle) } catch {
                Add-GuiLog ('Background operation error: {0}' -f $_.Exception.Message)
            }
            # worker statements that failed without aborting the script land only in the error stream (e.g. the startup type-resolution failure) - surface them instead of losing them silently
            foreach ($er in @($w.PS.Streams.Error)) { Add-GuiLog ('Background operation error: {0}' -f $er.ToString()) }
            try { $w.PS.Dispose() } catch { }
            try { $w.RS.Close() } catch { }
            $script:Worker = $null
            $sync.Busy = $false
            Receive-WorkerFinished
        }
    })

#  Startup
Add-GuiLog ('WU Offline Tool started. PowerShell: {0}' -f $PSVersionTable.PSVersion.ToString())
# Caption plus the exact build number (UBR comes from the registry, not from WMI)
$osName = ''
$osBuild = ''
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $osName = $os.Caption
    $osBuild = $os.BuildNumber
    $ubr = (Get-ItemProperty -Path $script:RegOsBuild -ErrorAction SilentlyContinue).UBR
    if ($ubr) { $osBuild = ('{0}.{1}' -f $osBuild, $ubr) }
} catch { $osName = [Environment]::OSVersion.VersionString; $osBuild = [Environment]::OSVersion.Version.ToString() }
$adminTxt = 'no'
if ($script:IsAdmin) { $adminTxt = 'yes' }
Add-GuiLog ('OS: {0}; build: {1}; elevated rights: {2}.' -f $osName, $osBuild, $adminTxt)
# machine identity for the admin reading another computer's log: computer name plus its domain or workgroup
$machineTxt = $env:COMPUTERNAME
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $domKind = 'workgroup'
    if ($cs.PartOfDomain) { $domKind = 'domain' }
    $machineTxt = ('{0}; {1}: {2}' -f $cs.Name, $domKind, $cs.Domain)
} catch { }
Add-GuiLog ('Computer: {0}.' -f $machineTxt)
$modeTxt = 'fallback folder (the script folder is not writable)'
if ($script:PortableMode) { $modeTxt = 'portable mode (next to the script)' }
Add-GuiLog ('Working folder: {0} - {1}. Update files go to {0}\Updates.' -f $script:WorkDir, $modeTxt)
Add-GuiLog ('Log file: {0}.' -f $script:LogFile)
Add-GuiLog 'Workflow: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected] -> after testing [Cleanup leftovers].'
Add-GuiLog 'One-click: [Scan + Install] runs the whole sequence unattended - scan, download the missing files, install everything checked.'
Add-GuiLog 'Offline -> online workflow: [Scan] on the offline PC -> [Add checked to queue] -> move the project folder to an online PC -> [Download queue] -> move the Updates folder back -> [Scan (offline)] -> [Install selected].'
if (-not $script:IsAdmin) { Add-GuiLog 'Running WITHOUT administrator rights: the offline scan needs elevation too (it registers a scan package in the Windows Update service store), so scan/install/uninstall/cleanup are disabled; the download queue and file downloads work.' }
if ($script:DownloadQueue.Count -gt 0) { Add-GuiLog ('Download queue: {0} item(s) restored from download-queue.json.' -f $script:DownloadQueue.Count) }
Update-QueueList

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
$sync.Cancel = $true
Receive-LogQueue