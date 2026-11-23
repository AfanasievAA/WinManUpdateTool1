<#
.SYNOPSIS
    Windows Manual Offline Update Tool - manual update install/uninstall manager for Windows (without automatic updates).

.DESCRIPTION
    Self-contained PowerShell tool with a WinForms that does not depend on a working windows update service
      1. Offline scan - searches for missing updates against a local wsusscn2.cab catalog via the Windows Update Agent API (ServerSelection = ssOthers), without contacting WSUS or Microsoft Update servers.
      2. Download - fetches update files by direct URLs taken from DownloadContents/BundledUpdates (Microsoft CDN). A file whose name carries the embedded SHA-1 digest (the same digest WSUS keys its content store on) is verified against it: an intact file already on disk is reused as is with no network round-trips (delete the Updates folder or the KB subfolder to force a re-download), a corrupt or truncated one is re-downloaded (up to 3 attempts) and never left on disk; files whose name carries no digest fall back to server-side date checks. Optionally, files can be pulled from a local WSUS server instead (see .PARAMETER WsusServer).
      3. Install - applies packages locally depending on type: .msu via wusa.exe /quiet /norestart; .cab via DISM after an "Applicable" check and /Add-Package /IgnoreCheck; .msi via msiexec /qn /norestart; .exe with "/q /norestart" (ndp*/ofv*/2553065), "/q" with an automatic "/qn /norestart" retry (MSRT kb890830: its package wraps an MSI that rejects the bare /q with 1639) or "/q /z" (other exe installers); non-CBS Office cabs are extracted and their .msp payloads applied via msiexec /p. Exit codes 3010/1641/3017 mean a reboot is required. Note: .msu installation via wusa needs the wuauserv service running (no WSUS connectivity needed), while .cab installation via DISM works even with the update agent disabled.
      4. Uninstall - wusa.exe /uninstall /kb:N and, additionally, DISM /Remove-Package for Package_for_* service packages that wusa usually cannot remove on Windows 10/11.
      5. Cleanup - reclaims disk space after the installed updates are tested: removes superseded components from the WinSxS store via DISM /StartComponentCleanup (the engine behind the Disk Cleanup item "Windows Update Cleanup"; with /ResetBase updates become permanent), clears the Windows Update caches (SoftwareDistribution\Download, Delivery Optimization) and deletes the update files downloaded by this tool (the wsusscn2.cab catalog copy is kept).
    WSUS download mode (optional): a WSUS server stores update files in its content store (IIS virtual directory "Content" -> WSUSContent folder) as Content/<hash[0:2]>/<hash>.<ext>, where the 40-hex <hash> is the SHA1 hash of the file - the same hash that is embedded in the Microsoft CDN file name. When a WSUS source is configured, the tool maps each CDN URL to the matching WSUS content path, probes it (HTTP HEAD or UNC Test-Path), and downloads from there; if a file is missing on the WSUS server (e.g. the update is not approved/downloaded there), the tool falls back to the Internet CDN automatically. The scan itself always remains offline (local wsusscn2.cab).

.PARAMETER WorkDir
    Working folder (catalog copy, Updates subfolder, log file, state file). The tool is portable by default: it uses the folder where the script file itself is located, e.g. C:\Scripts for C:\Scripts\WinManUpdateTool1.ps1. If that folder is not writable, it falls back to C:\ProgramData\WinManUpdateTool1, then to %LOCALAPPDATA%\WinManUpdateTool1.

.PARAMETER CatalogPath
    Path to a ready-made wsusscn2.cab (e.g. a network share \\srv\wsus\wsusscn2.cab). Can also be typed in the GUI later. Resolution order: the given file -> a local copy in the working folder (server date is checked) -> download from go.microsoft.com/fwlink.

.PARAMETER WsusServer
    Optional download source: http://<server>[:8530][/Content] or a UNC path to the WSUS content folder (e.g. \\wsus\wsus$\WSUSContent). Can also be typed in the GUI. Empty (default) = download from the Internet CDN. The GUI value is saved to settings.json in the working folder on exit and restored on the next start; an explicit -WsusServer parameter overrides the saved value.

.PARAMETER AutoElevate
    Legacy switch with no effect: the tool now always relaunches itself elevated (UAC prompt) at startup when started with user rights. Kept for backward compatibility with existing shortcuts.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
.NOTES
  Author:         Andrew Afanasiev
  Contacts:       AfanasievAA@yandex.ru
  https://github.com/AfanasievAA/WinManUpdateTool1

    Workflow: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected] -> after testing [Cleanup leftovers].
    The first run needs Internet access once to fetch wsusscn2.cab (400-600 MB) unless a local copy or a share path is provided.
    The offline scan usually takes 5-40 minutes and cannot be interrupted (a WUA COM limitation).
    Target systems: Windows 10/11, Windows PowerShell 5.1 (built into the OS).
    The tool needs administrator rights for its operations, so it relaunches itself elevated (UAC prompt) at startup when started with user rights, and it restarts itself on an STA thread for the WinForms GUI.
#>
#Requires -Version 5.1
param(
    [string]$WorkDir = '',
    [string]$CatalogPath = '',
    [string]$WsusServer = '',
    [switch]$AutoElevate
)
$Script:version = '0.6 (23 Nov 2026)'

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
# registry path for the OS build (CurrentBuild + UBR)
$script:RegOsBuild = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

# WSUS content-store file-name layouts probed by Resolve-WsusSource; the integer values are stable and index the candidate list
enum WsusNameStyle {
    Native = 0              # <hash>.<ext> - the native WSUS storage name
    CdnName = 1             # <name>_<hash>.<ext> - the original Microsoft CDN name
    PublishedConcat = 2     # <hash><name>.<ext> - locally published third-party content
    PublishedUnderscore = 3 # <hash>_<name>.<ext> - locally published third-party content
}

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

# The tool has no useful unelevated mode (wusa/DISM/msiexec and service control need admin rights): relaunch itself elevated right at startup when started with user rights; WUOT_ELEVATED guards against a relaunch loop should the elevation not stick
if (-not (Test-IsAdmin) -and -not $env:WUOT_ELEVATED) {
    $env:WUOT_ELEVATED = '1'
    try {
        Restart-ScriptHost -Elevate
    } catch {
        Write-Warning ('Elevated launch was canceled or failed: {0}' -f $_.Exception.Message)
    }
    return
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

# --- User settings (settings.json in the working folder) ---
# Load settings.json into a hashtable (empty when missing or unreadable)
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
$script:sync.RebootNeeded = $false
$script:sync.Result = @()
$script:sync.InstalledList = @()
$script:sync.InstalledOk = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

$script:IsAdmin = Test-IsAdmin
$script:HaveScanResults = $false
$script:HaveInstalledList = $false
$script:ItemMap = @{}
$script:Worker = $null

# Enqueue a log line for the GUI thread to display and append to the log file
function Add-GuiLog {
    param([string]$m)
    $script:sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m))
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

#  BACKGROUND WORKER: runs in its own runspace, the GUI never blocks.  Variables are injected via SessionStateProxy: sync, WorkDir, Mode, CatalogFile, WsusServer, Selected, UninstallSel, ResetBase, IsAdmin, CatalogUrl, SearchCriteria, CancelMsg, plus the shared constants (exit codes, source names, worker modes)
$script:WorkerScript = {
    $counters = @{ Psf = 0 }
    $script:wsusStyle = [WsusNameStyle]::Native    # remembered WSUS file-name layout that matched last, speeds up subsequent files

    # Queue a log line for the GUI thread
    function Write-Log { param([string]$m) $sync.Log.Enqueue(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)) }
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

    # File name from a URL: last path segment, URL-decoded, invalid chars stripped
    function Get-UrlFileName {
        param([string]$Url)
        $name = ''
        try {
            $u = [Uri]$Url
            $name = [Uri]::UnescapeDataString($u.Segments[$u.Segments.Count - 1])
            $name = $name.TrimEnd('/')
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

    # Map a Microsoft CDN URL to the WSUS content store layout: Content/<hash[0:2]>/<hash>.<ext>, where <hash> is the 40-hex SHA1 of the file - the same hash that is embedded in the Microsoft CDN file name (WSUS names content files by their SHA1 and keeps the original extension, e.g. Content/9c/9c8ff...d5.msu). Several name layouts exist in the wild (see [WsusNameStyle]); candidates are probed and the working one is remembered. Returns @{ Url = <http url or unc path>; Style = <[WsusNameStyle] member>; Unc = <bool> } or $null when no mapping/probe matched.
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
        $names[[int][WsusNameStyle]::Native] = ('{0}.{1}' -f $hash, $ext)
        $names[[int][WsusNameStyle]::CdnName] = ('{0}_{1}.{2}' -f $pure, $hash, $ext)
        $names[[int][WsusNameStyle]::PublishedConcat] = ('{0}{1}.{2}' -f $hash, $pure, $ext)
        $names[[int][WsusNameStyle]::PublishedUnderscore] = ('{0}_{1}.{2}' -f $hash, $pure, $ext)
        $all = @([int][WsusNameStyle]::Native, [int][WsusNameStyle]::CdnName, [int][WsusNameStyle]::PublishedConcat, [int][WsusNameStyle]::PublishedUnderscore)
        $first = [int]$script:wsusStyle
        if ($all -notcontains $first) { $first = [int][WsusNameStyle]::Native }
        $order = @($first) + ($all | Where-Object { $_ -ne $first })
        foreach ($oi in $order) {
            $cand = $names[$oi]
            if ($Base -like '\\*') {
                $p = Join-Path $Base ($hash.Substring(0, 2) + '\' + $cand)
                if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ Url = $p; Style = [WsusNameStyle]$oi; Unc = $true } }
            } else {
                $u = $Base + '/' + $hash.Substring(0, 2) + '/' + $cand
                if (Test-HttpUrlExists $u) { return @{ Url = $u; Style = [WsusNameStyle]$oi; Unc = $false } }
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
                at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
            $state = @($state) + $rec
            ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
        } catch {
            Write-Log ('Failed to update install-state.json: {0}' -f $_.Exception.Message)
        }
    }

    # MODE: Offline scan
    # Enumerate missing updates against the local wsusscn2.cab catalog
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

    # Download files of the selected updates (WSUS source first, then Internet CDN)
    function Invoke-Download {
        if (@($Selected).Count -eq 0) { Write-Log 'No updates selected.'; return }
        # download-source state shared by all files of this run: WsusBase = the normalized WSUS content root ('' when disabled/unreachable), SkipWsus = the current file is known to be absent from the WSUS store
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
        $totalItems = @($Selected).Count
        $idx = 0
        foreach ($uuid in $Selected) {
            if ($sync.Cancel) { throw $CancelMsg }
            $it = $null
            foreach ($cand in $sync.Result) { if ($cand.UUID -eq $uuid) { $it = $cand; break } }
            if (-not $it) { continue }
            $idx++
            if (-not $it.Urls -or $it.Urls.Count -eq 0) {
                Set-ItemStatus $uuid 'No direct file URL'
                Write-Log ('{0}: no direct URLs for its files - skipped.' -f $it.KB)
                continue
            }
            if (-not (Test-Path -LiteralPath $it.Dir)) { New-Item -ItemType Directory -Path $it.Dir -Force | Out-Null }
            $fcount = $it.Urls.Count
            $fi = 0
            $itemFail = 0
            foreach ($url in $it.Urls) {
                if ($sync.Cancel) { throw $CancelMsg }
                $fi++
                $name = Get-UrlFileName $url
                $dest = Join-Path $it.Dir $name
                $base = (($idx - 1) + (($fi - 1) / $fcount)) / $totalItems
                $span = (1.0 / $fcount) / $totalItems
                # expected SHA-1 digest: the one embedded in the CDN/WSUS file name (the WSUS store copy is byte-identical, so it matches both sources)
                $nameHash = Get-FileNameHash $name
                $bytes = -1
                $fileOk = $false
                $dlState.SkipWsus = $false
                # fast path: the file is on disk and its bytes match the SHA-1 pinned in its name, so it is exactly what this URL serves - reuse it as is, no probe, no server check (delete the Updates folder or the KB subfolder to force a re-download)
                if ($nameHash -and (Test-Path -LiteralPath $dest) -and (Test-FileIntegrity -Path $dest -ExpectedHash $nameHash)) {
                    Write-Log ('{0}: {1} already downloaded - checksum verified, skipping.' -f $it.KB, $name)
                    continue
                }
                # up to 3 attempts per file: corrupt/truncated downloads and transient network errors are retried, a broken file is never left on disk
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    # choose the download source: WSUS first when configured (unless it proved empty for this file), Internet otherwise
                    $dl = Get-DownloadSource -Url $url -State $dlState -KB $it.KB -Name $name
                    $dlUrl = $dl.Url
                    $dlUnc = $dl.Unc
                    $srcName = $dl.Source
                    $needFetch = $true
                    if (Test-Path -LiteralPath $dest) {
                        # reuse a present file only when it passes the integrity check - protects against corrupt leftovers of earlier runs
                        if (-not (Test-FileIntegrity -Path $dest -ExpectedHash $nameHash)) {
                            Write-Log ('{0}: {1} is present but corrupt (SHA-1 check failed) - re-downloading.' -f $it.KB, $name)
                            Remove-Item -LiteralPath $dest -Force
                        } elseif ($dlUnc) {
                            Write-Log ('{0}: {1} already downloaded - skipping.' -f $it.KB, $name)
                            $needFetch = $false
                        } else {
                            Set-Progress ($base + $span * 0.5) ('{0}: checking {1}' -f $it.KB, $name)
                            if (-not (Test-RemoteNewer -Url $dlUrl -LocalUtc (Get-Item -LiteralPath $dest).LastWriteTimeUtc -NoProxy:($srcName -eq $SrcWsus))) {
                                Write-Log ('{0}: {1} already downloaded and up to date - skipping.' -f $it.KB, $name)
                                $needFetch = $false
                            } else {
                                Write-Log ('{0}: {1} - a newer version exists on the server, re-downloading.' -f $it.KB, $name)
                                Remove-Item -LiteralPath $dest -Force
                            }
                        }
                    }
                    if (-not $needFetch) { $fileOk = $true; break }
                    Set-ItemStatus $uuid ('Downloading {0}/{1}: {2}' -f $fi, $fcount, $name)
                    try {
                        if ($dlUnc) {
                            Write-Log ('{0}: copying {1} from WSUS share' -f $it.KB, $name)
                            Copy-Item -LiteralPath $dlUrl -Destination $dest -Force
                            $bytes = (Get-Item -LiteralPath $dest).Length
                        } else {
                            Write-Log ('{0}: downloading {1} from {2}' -f $it.KB, $name, $srcName)
                            $bytes = Invoke-HttpDownload -Url $dlUrl -DestPath $dest -Label ('{0}: {1}' -f $it.KB, $name) -Base $base -Span $span -NoProxy:($srcName -eq $SrcWsus)
                        }
                    } catch {
                        if ($_.Exception.Message -eq $CancelMsg) { throw }
                        Write-Log ('{0}: downloading {1} from {2} failed: {3}' -f $it.KB, $name, $srcName, $_.Exception.Message)
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
                        if ($isHtml) { Write-Log ('{0}: {1} from {2} is an HTML/XML page, not the package (proxy or captive-portal interference?) - retrying.' -f $it.KB, $name, $srcName) }
                        else { Write-Log ('{0}: {1} from {2} fails the SHA-1 integrity check (expected {3}) - retrying.' -f $it.KB, $name, $srcName, $nameHash) }
                        Remove-Item -LiteralPath $dest -Force
                    }
                    if ($srcName -eq $SrcWsus) { $dlState.SkipWsus = $true }
                }
                if (-not $fileOk) {
                    $itemFail++
                    Set-ItemStatus $uuid ('Download failed: {0}' -f $name)
                    Write-Log ('{0}: {1} could not be downloaded intact after 3 attempts - skipped.' -f $it.KB, $name)
                    continue
                }
                if ($bytes -ge 0) { Write-Log ('{0}: saved {1} ({2:N1} MB)' -f $it.KB, $name, ($bytes / 1MB)) }
            }
            if ($itemFail -gt 0) {
                Set-ItemStatus $uuid ('Downloaded with errors ({0} file(s) failed)' -f $itemFail)
                Write-Log ('{0}: download finished with errors.' -f $it.KB)
            } else {
                Set-ItemStatus $uuid 'Downloaded - ready to install'
                Write-Log ('{0}: download finished.' -f $it.KB)
            }
        }
        Write-Log 'Download: all selected updates processed.'
    }

    #  MODE: Install selected
    # Apply downloaded packages (msu/cab/exe/msi) to the local system
    function Invoke-Install {
        if (-not $IsAdmin) { throw 'Installation requires administrator rights. Restart the tool elevated.' }
        if (@($Selected).Count -eq 0) { Write-Log 'No updates selected.'; return }
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
                $argLine2 = $null
                if ($ext -eq '.msu') {
                    Write-Log ('{0}: wusa.exe (silent install): {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wusa.exe') -ArgumentList ('"{0}" /quiet /norestart' -f $file.FullName) -Wait -PassThru -WindowStyle Hidden
                    $exitCode = $p.ExitCode
                } elseif ($ext -eq '.cab') {
                    Write-Log ('{0}: checking applicability via DISM: {1}' -f $it.KB, $file.Name)
                    $cabInfo = Test-CabApplicable -CabPath $file.FullName
                    if (-not $cabInfo.Ok) {
                        # DISM cannot open non-CBS cabs (exit code 2): Office-family updates are cab containers with .msp payloads.
                        # Extract the patches and apply them with msiexec /p instead of skipping the update.
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
                        $argLine = '"{0}" /q /norestart' -f $file.FullName
                    } elseif ($n.StartsWith('windows-kb890830')) {
                        # MSRT: the documented quiet switch is /q, but the package wraps an MSI whose msiexec rejects a bare /q with 1639 (0x80070667) - retry once with the MSI-style quiet line
                        $argLine = '"{0}" /q' -f $file.FullName
                        $argLine2 = '"{0}" /qn /norestart' -f $file.FullName
                        $exitTool = 'msrt'
                    } else {
                        $argLine = '"{0}" /q /z' -f $file.FullName
                    }
                    Write-Log ('{0}: running installer: {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath $file.FullName -ArgumentList $argLine -Wait -PassThru
                    $exitCode = $p.ExitCode
                    if ($argLine2 -and $exitCode -eq $ExitBadCommandLine) {
                        Write-Log ('{0}: {1} rejected the quiet switch (Win32 1639 ERROR_BAD_COMMAND_LINE) - retrying with the MSI-style quiet line.' -f $it.KB, $file.Name)
                        $p = Start-Process -FilePath $file.FullName -ArgumentList $argLine2 -Wait -PassThru
                        $exitCode = $p.ExitCode
                    }
                } else {
                    Write-Log ('{0}: format {1} is not supported for manual installation - skipped.' -f $it.KB, $ext)
                    continue
                }
                $info = Get-ExitCodeInfo -Code $exitCode -Tool $exitTool
                if ($info.Reboot) { $sync.RebootNeeded = $true }
                if ($info.Ok) { $itemOk++ } else { $itemErr++ }
                Write-Log ('{0}: {1} → exit code {2}: {3}' -f $it.KB, $file.Name, $exitCode, $info.Text)
                Set-ItemStatus $uuid ('Result: {0}' -f $info.Text)
                Add-StateRecord -KB $it.KB -FilePath $file.FullName -Method $ext -Identity $pkgIdentity -ExitCode $exitCode
            }
            $statTxt = 'Done'
            if ($itemErr -gt 0) { $statTxt = ('Completed with errors ({0})' -f $itemErr) }
            elseif ($itemOk -gt 0 -and $sync.RebootNeeded) { $statTxt = 'Installed, reboot required' }
            elseif ($itemOk -gt 0) { $statTxt = 'Installed' }
            Set-ItemStatus $uuid $statTxt
            # Remember items installed without errors to uncheck them in the GUI afterwards
            if ($itemOk -gt 0 -and $itemErr -eq 0) { $sync.InstalledOk.Enqueue([string]$uuid) }
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

    # MODE: List installed updates
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

    # MODE: Uninstall selected
    # Remove the selected QFE entries (wusa) and DISM packages
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

    # MODE: Cleanup leftovers of installed updates (run after the updates are tested)
    # Reclaims disk space: 1) superseded components in the WinSxS store via DISM /StartComponentCleanup - the engine behind the Disk Cleanup item "Windows Update Cleanup" (with $ResetBase also /ResetBase - afterwards updates can no longer be uninstalled);
    # 2) Windows Update caches: SoftwareDistribution\Download (wuauserv/bits are stopped and restored to their previous state) and Delivery Optimization; 3) update files downloaded by this tool (wsusscn2.cab is kept)
    function Invoke-Cleanup {
        if (-not $IsAdmin) { throw 'Cleanup requires administrator rights. Restart the tool elevated.' }
        $freeBefore = [double](Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue).FreeSpace
        Write-Log ('Cleanup: started. Free space on {0}: {1:N1} GB.' -f $env:SystemDrive, ($freeBefore / 1GB))
        # 1) WinSxS superseded components (DISM runs in its own console window and shows its own progress)
        Write-Status 'Removing superseded components (WinSxS)...'
        Set-Progress 0 'DISM /StartComponentCleanup (WinSxS)'
        Write-Log 'Cleanup: removing superseded components from the WinSxS store (the Disk Cleanup "Windows Update Cleanup" engine); this may take 10-30 minutes.'
        if ($ResetBase) { Write-Log 'Cleanup: /ResetBase mode - after this run NO installed update can be uninstalled anymore.' }
        $dismArgs = '/Online /NoRestart /Cleanup-Image /StartComponentCleanup'
        if ($ResetBase) { $dismArgs += ' /ResetBase' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Dism.exe') -ArgumentList $dismArgs -Wait -PassThru
        $sw.Stop()
        $info = Get-ExitCodeInfo -Code $p.ExitCode -Tool 'dism-cleanup'
        if ($info.Reboot) { $sync.RebootNeeded = $true }
        if ($info.Ok) { Write-Log ('Cleanup: component store cleaned in {0:00} min {1:00} sec (DISM exit code {2}: {3}).' -f [int]$sw.Elapsed.TotalMinutes, $sw.Elapsed.Seconds, $p.ExitCode, $info.Text) }
        else { Write-Log ('Cleanup: DISM StartComponentCleanup failed - exit code {0}: {1}.' -f $p.ExitCode, $info.Text) }
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

#  GUI-thread functions: worker launch, list population, completion handling
# Launch the background runspace for the given mode and selections
function Start-Worker {
    param([string]$Mode, [string[]]$Selected = @(), [string[]]$UninstallSel = @(), [bool]$ResetBase = $false)
    if ($sync.Busy) {
        Show-GuiMsg 'An operation is already running, please wait until it finishes.'
        return $false
    }
    $sync.Cancel = $false
    $sync.Busy = $true
    $sync.ScanDone = $false
    $sync.InstalledDone = $false
    $sync.UninstallDone = $false
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
    $rs.SessionStateProxy.SetVariable('ResetBase', $ResetBase)
    $rs.SessionStateProxy.SetVariable('IsAdmin', $script:IsAdmin)
    $rs.SessionStateProxy.SetVariable('CatalogUrl', $script:CatalogUrl)
    $rs.SessionStateProxy.SetVariable('SearchCriteria', $script:SearchCriteria)
    $rs.SessionStateProxy.SetVariable('CancelMsg', $script:CancelMsg)
    # hand the shared constants (exit codes, source names, worker modes) to the worker runspace
    foreach ($cn in 'ExitRebootRequired', 'ExitRebootRequiredAlt', 'ExitRebootInitiated', 'ExitAlreadyInstalled', 'ExitBadCommandLine', 'SrcInternet', 'SrcWsus', 'ModeGetCatalog', 'ModeScan', 'ModeDownload', 'ModeInstall', 'ModeListInstalled', 'ModeUninstall', 'ModeCleanup') { $rs.SessionStateProxy.SetVariable($cn, (Get-Variable -Name $cn -Scope Script).Value) }
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
        $lvi.Tag = [string]$it.UUID
        $lvi.Checked = ($it.Urls.Count -gt 0)
        if ($it.Urls.Count -eq 0) { $lvi.ForeColor = [System.Drawing.Color]::Gray }
        if ($it.Description) { $lvi.ToolTipText = $it.Description }
        [void]$lvUpdates.Items.Add($lvi)
        $script:ItemMap[[string]$it.UUID] = $lvi
    }
    $lvUpdates.EndUpdate()
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

# Handle completion of the background runspace (populate lists, prompt for reboot)
function Receive-WorkerFinished {
    if ($sync.ScanDone) {
        $sync.ScanDone = $false
        $script:HaveScanResults = $true
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
$lblWsusHint.ForeColor = [System.Drawing.Color]::Gray
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($txtWsus, "WSUS download source, used for DOWNLOADS only (the scan always stays offline).`nExamples: http://wsus:8530  |  http://wsus  |  \\wsus\wsus$\WSUSContent`nFiles missing on the WSUS server are automatically downloaded from the Internet instead.")
$panelWsus.Controls.Add($lblWsus, 0, 0)
$panelWsus.Controls.Add($txtWsus, 1, 0)
$panelWsus.Controls.Add($lblWsusHint, 2, 0)

# --- Row 3: action buttons ---
$panelButtons = New-Object System.Windows.Forms.TableLayoutPanel
$panelButtons.Dock = 'Top'
$panelButtons.Height = 36
$panelButtons.ColumnCount = 9
$panelButtons.RowCount = 1
$panelButtons.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
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
$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = 'Download selected'
$btnDownload.AutoSize = $true
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Install selected'
$btnInstall.AutoSize = $true
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
$panelButtons.Controls.Add($btnMarkAll, 3, 0)
$panelButtons.Controls.Add($btnClearAll, 4, 0)
 $panelButtons.Controls.Add($btnCleanup, 5, 0)
 $panelButtons.Controls.Add($btnOpenDir, 6, 0)
 $panelButtons.Controls.Add($btnCancelOp, 7, 0)
$panelButtons.Controls.Add($btnAbout, 8, 0)

# --- Tabs ---
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabUpdates = New-Object System.Windows.Forms.TabPage
$tabUpdates.Text = 'Available updates'
$tabInstalled = New-Object System.Windows.Forms.TabPage
$tabInstalled.Text = 'Installed (uninstall)'

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
[void]$tabUpdates.Controls.Add($lvUpdates)

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

[void]$tabs.TabPages.Add($tabUpdates)
[void]$tabs.TabPages.Add($tabInstalled)

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
        $about.Size = New-Object System.Drawing.Size(520, 260)
        $about.MaximizeBox = $false
        $about.MinimizeBox = $false
        $about.ShowInTaskbar = $false
        $about.Font = $form.Font
        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(12, 12)
        $txt.Size = New-Object System.Drawing.Size(480, 150)
        $txt.Text = ("Windows Manual Update Offline Tool One`nVersion: {0}`nAuthor: Andrew Afanasiev (AfanasievAA@yandex.ru)`n`nManual update install/uninstall manager for Windows without automatic updates: offline scan against a local wsusscn2.cab catalog, download (Internet CDN or a WSUS server), local install via wusa/DISM/msiexec, uninstall.`n`nProject page:" -f $Script:version)
        [void]$about.Controls.Add($txt)
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Location = New-Object System.Drawing.Point(12, 160)
        $link.Size = New-Object System.Drawing.Size(480, 22)
        $link.Text = 'https://github.com/AfanasievAA/WinManUpdateTool1'
        $link.Add_LinkClicked({ try { Start-Process ('https://github.com/AfanasievAA/WinManUpdateTool1') | Out-Null } catch { } })
        [void]$about.Controls.Add($link)
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'OK'
        $btnOk.DialogResult = 'OK'
        $btnOk.Location = New-Object System.Drawing.Point(415, 190)
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
        $btnScan.Enabled = (-not $busy)
        $btnDownload.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnInstall.Enabled = (-not $busy) -and $script:HaveScanResults -and $script:IsAdmin
        $btnCatalogDl.Enabled = (-not $busy)
        $btnMarkAll.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnClearAll.Enabled = (-not $busy) -and $script:HaveScanResults
        $btnRefreshInst.Enabled = (-not $busy)
        $btnUninstall.Enabled = (-not $busy) -and $script:HaveInstalledList -and $script:IsAdmin
        $btnCleanup.Enabled = (-not $busy) -and $script:IsAdmin

        if ($sync.ItemStatus.Count -gt 0) {
            foreach ($key in @($sync.ItemStatus.Keys)) {
                $lvi = $script:ItemMap[$key]
                if ($lvi) { $lvi.SubItems[5].Text = [string]$sync.ItemStatus[$key] }
            }
        }

        $w = $script:Worker
        if ($w -and $w.Handle.IsCompleted) {
            try { $null = $w.PS.EndInvoke($w.Handle) } catch {
                Add-GuiLog ('Background operation error: {0}' -f $_.Exception.Message)
            }
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
$modeTxt = 'fallback folder (the script folder is not writable)'
if ($script:PortableMode) { $modeTxt = 'portable mode (next to the script)' }
Add-GuiLog ('Working folder: {0} - {1}. Update files go to {0}\Updates.' -f $script:WorkDir, $modeTxt)
Add-GuiLog ('Log file: {0}.' -f $script:LogFile)
Add-GuiLog 'Workflow: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected] -> after testing [Cleanup leftovers].'

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
$sync.Cancel = $true
Receive-LogQueue