<#
.SYNOPSIS
    Windows Manual Offline Update Tool - manual update install/uninstall manager for Windows (without automatic updates).

.DESCRIPTION
    Self-contained PowerShell tool with a WinForms that does not depend on a working windows update service
      1. Offline scan - searches for missing updates against a local wsusscn2.cab catalog via the Windows Update Agent API (ServerSelection = ssOthers), without contacting WSUS or Microsoft Update servers.
      2. Download - fetches update files by direct URLs taken from DownloadContents/BundledUpdates (Microsoft CDN), with server-side date checks so that only newer files are re-downloaded. Optionally, files can be pulled from a local WSUS server instead (see .PARAMETER WsusServer).
      3. Install - applies packages locally depending on type: .msu via wusa.exe /quiet /norestart; .cab via DISM after an "Applicable" check and /Add-Package /IgnoreCheck; .msi via msiexec /qn /norestart; .exe with "/q /norestart" (ndp*/ofv*/2553065) or "/q /z". Exit codes 3010/1641/3017 mean a reboot is required. Note: .msu installation via wusa needs the wuauserv service running (no WSUS connectivity needed), while .cab installation via DISM works even with the update agent disabled.
      4. Uninstall - wusa.exe /uninstall /kb:N and, additionally, DISM /Remove-Package for Package_for_* service packages that wusa usually cannot remove on Windows 10/11.
    WSUS download mode (optional): a WSUS server stores update files in its content store (IIS virtual directory "Content" -> WSUSContent folder) as Content/<hash[0:2]>/<hash[2:4]>/<file>, where the file name carries the SHA1 hash of the file - the same hash that is embedded in the Microsoft CDN file name. When a WSUS source is configured, the tool maps each CDN URL to the matching WSUS content path, probes it (HTTP HEAD or UNC Test-Path), and downloads from there; if a file is missing on the WSUS server, the tool falls back to the Internet CDN automatically. The scan itself always remains offline (local wsusscn2.cab).

.PARAMETER WorkDir
    Working folder (catalog copy, Updates subfolder, log file, state file). The tool is portable by default: it uses the folder where the script file itself is located, e.g. C:\Scripts for C:\Scripts\WinManUpdateTool1.ps1. If that folder is not writable, it falls back to C:\ProgramData\WinManUpdateTool1, then to %LOCALAPPDATA%\WinManUpdateTool1.

.PARAMETER CatalogPath
    Path to a ready-made wsusscn2.cab (e.g. a network share \\srv\wsus\wsusscn2.cab). Can also be typed in the GUI later. Resolution order: the given file -> a local copy in the working folder (server date is checked) -> download from go.microsoft.com/fwlink.

.PARAMETER WsusServer
    Optional download source: http://<server>[:8530][/Content] or a UNC path to the WSUS content folder (e.g. \\wsus\wsus$\WSUSContent). Can also be typed in the GUI. Empty (default) = download from the Internet CDN.

.PARAMETER AutoElevate
    Relaunch the tool elevated (UAC prompt) if it was started without administrator rights.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -AutoElevate -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
.NOTES
  Author:         Andrew Afanasiev
  Contacts:       AfanasievAA@yandex.ru
    Workflow: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected].
    The first run needs Internet access once to fetch wsusscn2.cab (400-600 MB) unless a local copy or a share path is provided.
    The offline scan usually takes 5-40 minutes and cannot be interrupted (a WUA COM limitation).
    Target systems: Windows 10/11, Windows PowerShell 5.1 (built into the OS).
    The tool must run elevated (STA) for install/uninstall; scan and download work for any user.
#>
#Requires -Version 5.1
param(
    [string]$WorkDir = '',
    [string]$CatalogPath = '',
    [string]$WsusServer = '',
    [switch]$AutoElevate
)
$Script:version = '0.1beta1 (21 Nov 2026)'

$ErrorActionPreference = 'Continue'

# --- Constants ---
$script:CatalogUrl = 'https://go.microsoft.com/fwlink/p/?LinkID=74689'   # official redirect to the latest wsusscn2.cab
$script:SearchCriteria = 'IsInstalled=0 and IsHidden=0 and DeploymentAction=*'
$script:CancelMsg = '##OPERATION-CANCELED##'

# --- Administrator rights ---
# Return $true when the current process runs elevated
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

#  Relaunch with -STA if the host thread is not STA (WinForms requirement), once ---
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA -and -not $env:WUOT_NOSTA) {
    $env:WUOT_NOSTA = '1'
    $hostExe = 'powershell.exe'
    try { $hostExe = (Get-Process -Id $PID).Path } catch { }
    try {
        Start-Process -FilePath $hostExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath) | Out-Null
        return
    } catch {
        Write-Warning ('Failed to relaunch with -STA, continuing on the current thread: {0}' -f $_.Exception.Message)
    }
}

# Auto elevation
if ($AutoElevate -and -not (Test-IsAdmin)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath) | Out-Null
    } catch {
        Write-Warning ('Elevated launch was canceled or failed: {0}' -f $_.Exception.Message)
    }
    return
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

#  BACKGROUND WORKER: runs in its own runspace, the GUI never blocks.  Variables are injected via SessionStateProxy: sync, WorkDir, Mode, CatalogFile, WsusServer, Selected, UninstallSel, IsAdmin, CatalogUrl, SearchCriteria, CancelMsg
$script:WorkerScript = {
    $counters = @{ Psf = 0 }
    $script:wsusStyle = 0    # remembered WSUS file-name pattern that worked (0..2), speeds up subsequent files

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

    # Streamed download with progress and cancel support; returns the byte count
    function Invoke-HttpDownload {
        param([string]$Url, [string]$DestPath, [string]$Label, [double]$Base, [double]$Span)
        $partPath = "$DestPath.part"
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = 'WinManUpdateTool1/1.0'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 180000
            $req.AllowAutoRedirect = $true
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
        param([string]$Url, [datetime]$LocalUtc)
        try {
            Enable-Tls12
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'HEAD'
            $req.Timeout = 20000
            $req.AllowAutoRedirect = $true
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
            $r = $req.GetResponse()
            try { return ([int]$r.StatusCode -eq 200) } finally { $r.Close() }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { return $false }
            throw
        } catch { throw }
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

    # Map a Microsoft CDN URL to the WSUS content store layout: Content/<hash[0:2]>/<hash[2:4]>/<file>. The CDN file name embeds the SHA1 hash of the file, and WSUS stores files under the same hash. Several name layouts exist in the wild; candidates are probed and the working one is remembered. Returns @{ Url = <http url or unc path>; Style = <0..2>; Unc = <bool> } or $null when no mapping/probe matched.
    function Resolve-WsusSource {
        param([string]$Url)
        if ($wsusBase -eq '') { return $null }
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
        $names = @(
            ('{0}_{1}.{2}' -f $hash, $pure, $ext),   # style 0: <hash>_<name>
            ('{0}_{1}.{2}' -f $pure, $hash, $ext),   # style 1: <name>_<hash> (original CDN name)
            ('{0}{1}.{2}' -f $hash, $pure, $ext)     # style 2: <hash><name>
        )
        $first = $script:wsusStyle
        if ($first -lt 0 -or $first -gt 2) { $first = 0 }
        $order = @($first) + (@(0, 1, 2) | Where-Object { $_ -ne $first })
        foreach ($oi in $order) {
            $cand = $names[$oi]
            if ($wsusBase -like '\\*') {
                $p = Join-Path $wsusBase ($hash.Substring(0, 2) + '\' + $hash.Substring(2, 2) + '\' + $cand)
                if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ Url = $p; Style = $oi; Unc = $true } }
            } else {
                $u = $wsusBase + '/' + $hash.Substring(0, 2) + '/' + $hash.Substring(2, 2) + '/' + $cand
                if (Test-HttpUrlExists $u) { return @{ Url = $u; Style = $oi; Unc = $false } }
            }
        }
        return $null
    }

    # Catalog wsusscn2.cab: given path -> local copy (date-checked) -> download from the official fwlink
    function Get-CatalogFile {
        $defaultTarget = Join-Path $WorkDir 'updates\wsusscn2.cab'
        if ($CatalogFile -and (Test-Path -LiteralPath $CatalogFile -PathType Leaf)) {
            Write-Log ('Catalog: using the specified file: {0}' -f $CatalogFile)
            return $CatalogFile
        }
        if (Test-Path -LiteralPath $defaultTarget -PathType Leaf) {
            $localUtc = (Get-Item -LiteralPath $defaultTarget).LastWriteTimeUtc
            Write-Log ('Catalog: local wsusscn2.cab found (modified {0}), checking freshness...' -f (Get-Date $localUtc -Format 'dd.MM.yyyy HH:mm'))
            if (-not (Test-RemoteNewer -Url $CatalogUrl -LocalUtc $localUtc)) {
                Write-Log 'Catalog: the local copy is up to date, no download needed.'
                return $defaultTarget
            }
            Write-Log 'Catalog: a newer wsusscn2.cab exists on the server - refreshing the local copy.'
        } else {
            Write-Log ('Catalog: no local wsusscn2.cab yet - downloading from {0} (400-600 MB, may take a while).' -f $CatalogUrl)
        }
        Invoke-HttpDownload -Url $CatalogUrl -DestPath $defaultTarget -Label 'Catalog wsusscn2.cab' -Base 0 -Span 1 | Out-Null
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

    # Human-readable meaning of an installer exit code
    function Get-ExitCodeInfo {
        param([int]$Code, [string]$Tool)
        $info = @{ Ok = $false; Reboot = $false; Text = '' }
        switch ($Code) {
            0 { $info.Ok = $true; $info.Text = 'success' }
            1 { $info.Ok = $true; $info.Text = 'success (code 1)' }
            3010 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, REBOOT REQUIRED (3010)' }
            3017 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, reboot required (3017)' }
            1641 { $info.Ok = $true; $info.Reboot = $true; $info.Text = 'success, reboot initiated (1641)' }
            2359302 { $info.Ok = $true; $info.Text = 'already installed (2359302)' }
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
        $wsusBase = Get-WsusBase
        if ($wsusBase -ne '') { Write-Log ('WSUS download source enabled: {0} (missing files fall back to the Internet CDN).' -f $wsusBase) } else { Write-Log 'Downloading from the Internet CDN.' }
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
            foreach ($url in $it.Urls) {
                if ($sync.Cancel) { throw $CancelMsg }
                $fi++
                $name = Get-UrlFileName $url
                $dest = Join-Path $it.Dir $name
                $base = (($idx - 1) + (($fi - 1) / $fcount)) / $totalItems
                $span = (1.0 / $fcount) / $totalItems
                # choose the download source: WSUS first when configured, Internet otherwise
                $dlUrl = $url
                $dlUnc = $false
                $srcName = 'Internet'
                if ($wsusBase -ne '') {
                    $ws = $null
                    try { $ws = Resolve-WsusSource -Url $url } catch {
                        Write-Log 'WSUS server is unreachable - disabling the WSUS source for this run and downloading from the Internet CDN.'
                        $wsusBase = ''
                    }
                    if ($ws) {
                        $dlUrl = $ws.Url
                        $dlUnc = $ws.Unc
                        $script:wsusStyle = $ws.Style
                        $srcName = 'WSUS'
                    } elseif ($wsusBase -ne '') {
                        Write-Log ('{0}: {1} was not found on the WSUS server - falling back to the Internet CDN.' -f $it.KB, $name)
                    }
                }
                if (Test-Path -LiteralPath $dest) {
                    if ($dlUnc) {
                        Write-Log ('{0}: {1} already downloaded - skipping.' -f $it.KB, $name)
                        continue
                    }
                    Set-Progress ($base + $span * 0.5) ('{0}: checking {1}' -f $it.KB, $name)
                    if (-not (Test-RemoteNewer -Url $dlUrl -LocalUtc (Get-Item -LiteralPath $dest).LastWriteTimeUtc)) {
                        Write-Log ('{0}: {1} already downloaded and up to date - skipping.' -f $it.KB, $name)
                        continue
                    }
                    Write-Log ('{0}: {1} - a newer version exists on the server, re-downloading.' -f $it.KB, $name)
                }
                Set-ItemStatus $uuid ('Downloading {0}/{1}: {2}' -f $fi, $fcount, $name)
                if ($dlUnc) {
                    Write-Log ('{0}: copying {1} from WSUS share' -f $it.KB, $name)
                    Copy-Item -LiteralPath $dlUrl -Destination $dest -Force
                    $bytes = (Get-Item -LiteralPath $dest).Length
                } else {
                    Write-Log ('{0}: downloading {1} from {2}' -f $it.KB, $name, $srcName)
                    $bytes = Invoke-HttpDownload -Url $dlUrl -DestPath $dest -Label ('{0}: {1}' -f $it.KB, $name) -Base $base -Span $span
                }
                Write-Log ('{0}: saved {1} ({2:N1} MB)' -f $it.KB, $name, ($bytes / 1MB))
            }
            Set-ItemStatus $uuid 'Downloaded - ready to install'
            Write-Log ('{0}: download finished.' -f $it.KB)
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
                $ext = $file.Extension.ToLower()
                $exitCode = -1
                $pkgIdentity = ''
                if ($ext -eq '.msu') {
                    Write-Log ('{0}: wusa.exe (silent install): {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wusa.exe') -ArgumentList ('"{0}" /quiet /norestart' -f $file.FullName) -Wait -PassThru -WindowStyle Hidden
                    $exitCode = $p.ExitCode
                } elseif ($ext -eq '.cab') {
                    Write-Log ('{0}: checking applicability via DISM: {1}' -f $it.KB, $file.Name)
                    $cabInfo = Test-CabApplicable -CabPath $file.FullName
                    if (-not $cabInfo.Ok) {
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
                    } else {
                        $argLine = '"{0}" /q /z' -f $file.FullName
                    }
                    Write-Log ('{0}: running installer: {1}' -f $it.KB, $file.Name)
                    $p = Start-Process -FilePath $file.FullName -ArgumentList $argLine -Wait -PassThru
                    $exitCode = $p.ExitCode
                } else {
                    Write-Log ('{0}: format {1} is not supported for manual installation - skipped.' -f $it.KB, $ext)
                    continue
                }
                $info = Get-ExitCodeInfo -Code $exitCode -Tool $ext
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

    #  Dispatcher
    try {
        switch ($Mode) {
            'GetCatalog' { Set-Progress 0 'Checking wsusscn2.cab'; Get-CatalogFile | Out-Null; Write-Log 'Catalog is ready for the offline scan.' }
            'Scan' { Invoke-Scan }
            'Download' { Invoke-Download }
            'Install' { Invoke-Install }
            'ListInstalled' { Invoke-ListInstalled }
            'Uninstall' { Invoke-Uninstall }
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
    param([string]$Mode, [string[]]$Selected = @(), [string[]]$UninstallSel = @())
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
    $rs.SessionStateProxy.SetVariable('IsAdmin', $script:IsAdmin)
    $rs.SessionStateProxy.SetVariable('CatalogUrl', $script:CatalogUrl)
    $rs.SessionStateProxy.SetVariable('SearchCriteria', $script:SearchCriteria)
    $rs.SessionStateProxy.SetVariable('CancelMsg', $script:CancelMsg)
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
$txtCatalog.Text = $CatalogPath
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
$panelButtons.ColumnCount = 8
$panelButtons.RowCount = 1
$panelButtons.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
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
$btnOpenDir = New-Object System.Windows.Forms.Button
$btnOpenDir.Text = 'Folder'
$btnOpenDir.AutoSize = $true
$btnCancelOp = New-Object System.Windows.Forms.Button
$btnCancelOp.Text = 'Cancel'
$btnCancelOp.AutoSize = $true
$panelButtons.Controls.Add($btnScan, 0, 0)
$panelButtons.Controls.Add($btnDownload, 1, 0)
$panelButtons.Controls.Add($btnInstall, 2, 0)
$panelButtons.Controls.Add($btnMarkAll, 3, 0)
$panelButtons.Controls.Add($btnClearAll, 4, 0)
$panelButtons.Controls.Add($btnOpenDir, 6, 0)
$panelButtons.Controls.Add($btnCancelOp, 7, 0)

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

$btnCatalogDl.Add_Click({ [void](Start-Worker -Mode 'GetCatalog') })

$btnScan.Add_Click({
        Add-GuiLog ('Starting the offline scan. Catalog: "{0}" (empty = the local copy in the working folder, or a download).' -f $txtCatalog.Text)
        [void](Start-Worker -Mode 'Scan')
    })

$btnDownload.Add_Click({
        $sel = Get-CheckedUpdates
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the updates you want to download first.'; return }
        [void](Start-Worker -Mode 'Download' -Selected $sel)
    })

$btnInstall.Add_Click({
        if (-not $script:IsAdmin) {
            Show-GuiMsg "Installation requires administrator rights.`n`nRestart the tool elevated (or with the -AutoElevate switch)."
            return
        }
        $sel = Get-CheckedUpdates
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the updates you want to install first.'; return }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ("Install the selected updates ({0} items)?`n`nPackages are applied locally via wusa/DISM without contacting Windows Update. Do not close the window until it finishes." -f $sel.Count), 'Confirm installation', 'YesNo', 'Question')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-Worker -Mode 'Install' -Selected $sel)
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

$btnRefreshInst.Add_Click({ [void](Start-Worker -Mode 'ListInstalled') })

$btnUninstall.Add_Click({
        if (-not $script:IsAdmin) {
            Show-GuiMsg "Uninstallation requires administrator rights.`n`nRestart the tool elevated."
            return
        }
        $sel = Get-CheckedInstalled
        if ($sel.Count -eq 0) { Show-GuiMsg 'Check the packages you want to uninstall first.'; return }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, ("Uninstall the selected entries ({0} items)?`n`nA reboot may be required afterwards." -f $sel.Count), 'Confirm uninstall', 'YesNo', 'Warning')
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-Worker -Mode 'Uninstall' -UninstallSel $sel)
        }
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
$osName = ''
try { $osName = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $osName = [Environment]::OSVersion.VersionString }
$adminTxt = 'no'
if ($script:IsAdmin) { $adminTxt = 'yes' }
Add-GuiLog ('OS: {0}; elevated rights: {1}.' -f $osName, $adminTxt)
$modeTxt = 'fallback folder (the script folder is not writable)'
if ($script:PortableMode) { $modeTxt = 'portable mode (next to the script)' }
Add-GuiLog ('Working folder: {0} - {1}. Update files go to {0}\Updates.' -f $script:WorkDir, $modeTxt)
Add-GuiLog ('Log file: {0}.' -f $script:LogFile)
if (-not $script:IsAdmin) {
    Add-GuiLog 'Running without administrator rights: scan and download are available. Restart elevated to install/uninstall.'
}
Add-GuiLog 'Workflow: [Scan] -> mark the needed updates -> [Download selected] -> [Install selected].'

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
$sync.Cancel = $true
Receive-LogQueue