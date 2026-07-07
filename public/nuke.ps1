# nuke.it2.sh — AV Force-Removal TUI
#
# A get.activated.win-style interactive menu for ripping stubborn antivirus
# bloatware off Windows. Run it in one line:
#
#     irm nuke.it2.sh | iex
#
# The first vendor supported is McAfee — the proper way first (official
# uninstallers), then by force (processes, services, drivers, tasks, AppX,
# folders, registry, autoruns), with an optional whole-drive leftover sweep.
#
# Nothing here is silent-by-default: you pick a target, confirm, and watch it
# work. A full transcript is written to %TEMP% (path printed at the end).
#
# Source: https://github.com/TheTechNetwork/nuke.it2.sh

$ErrorActionPreference = 'Continue'

# The one-liner used to (re)launch this tool — also used to self-elevate.
# The Worker may inject $script:LaunchCommand (and $script:NukeTarget) ahead of
# this script when a target is given in the URL path (e.g. nuke.it2.sh/s1), so
# only set a default when nothing was injected.
if (-not $script:LaunchCommand) { $script:LaunchCommand = 'irm nuke.it2.sh | iex' }

# ===========================================================================
#  Shared UI helpers
# ===========================================================================

function Write-Step { param([string]$Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [+] $Text" -ForegroundColor Green }
function Write-Bad  { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '   ███╗   ██╗██╗   ██╗██╗  ██╗███████╗' -ForegroundColor Red
    Write-Host '   ████╗  ██║██║   ██║██║ ██╔╝██╔════╝' -ForegroundColor Red
    Write-Host '   ██╔██╗ ██║██║   ██║█████╔╝ █████╗  ' -ForegroundColor Red
    Write-Host '   ██║╚██╗██║██║   ██║██╔═██╗ ██╔══╝  ' -ForegroundColor Red
    Write-Host '   ██║ ╚████║╚██████╔╝██║  ██╗███████╗' -ForegroundColor Red
    Write-Host '   ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝' -ForegroundColor Red
    Write-Host '   nuke.it2.sh' -ForegroundColor White -NoNewline
    Write-Host '  —  antivirus search & destroy' -ForegroundColor DarkGray
    Write-Host ''
}

# ===========================================================================
#  Admin / elevation
# ===========================================================================

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    # #Requires -RunAsAdministrator can't be used from `irm | iex` (no script
    # file), so check by hand and offer to relaunch elevated by re-running the
    # same one-liner in a new admin PowerShell.
    if (Test-IsAdmin) { return $true }

    Write-Host ''
    Write-Bad 'This tool must run as Administrator.'
    $ans = Read-Host '  Relaunch elevated now? [Y/n]'
    if ($ans -match '^(n|no)$') {
        Write-Host '  Aborted — re-run from an elevated PowerShell.' -ForegroundColor Yellow
        return $false
    }
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$script:LaunchCommand`"" `
            -Verb RunAs | Out-Null
        Write-Host '  Elevated window launched — you can close this one.' -ForegroundColor Green
    } catch {
        Write-Bad "Could not elevate: $($_.Exception.Message)"
    }
    return $false
}

# ===========================================================================
#  Generic forced-removal primitives (shared by every vendor module)
# ===========================================================================

# MoveFileEx lets us queue locked files (drivers, self-protected binaries) for
# deletion at next reboot — the last resort when nothing else works.
if (-not ('Win32.PendingDelete' -as [type])) {
    Add-Type -Namespace Win32 -Name PendingDelete -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@
}

function Test-PathStartsWith {
    param([string]$Path, [string[]]$Prefixes)
    $normalized = $Path.TrimEnd('\') + '\'
    foreach ($prefix in $Prefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $attr = [System.IO.File]::GetAttributes($Path)
        return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $false }
}

function Remove-LinkOnly {
    # Delete a junction/symlink WITHOUT following it into its target.
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        cmd.exe /d /c "rd /q `"$Path`"" 2>&1 | Out-Null
        if (Test-Path -LiteralPath $Path) {
            try { [System.IO.Directory]::Delete($Path, $false) } catch { }
        }
    } else {
        try { [System.IO.File]::Delete($Path) } catch { }
    }
}

function Remove-NestedReparsePoints {
    # Unlink every junction/symlink inside a tree AS A LINK, without descending
    # through it. Must run before any recursive takeown/icacls/delete so those
    # operations can never traverse a reparse point into unrelated data.
    param([string]$Dir)
    foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if (Test-IsReparsePoint $child.FullName) {
            Remove-LinkOnly $child.FullName
        } elseif ($child.PSIsContainer) {
            Remove-NestedReparsePoints -Dir $child.FullName
        }
    }
}

function Remove-ItemForcefully {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    $full = $item.FullName

    # Safety net: refuse to touch drive roots and top-level system folders,
    # no matter what the caller (or a bad wildcard match) hands us.
    $normalized = $full.TrimEnd('\')
    $protected = @(
        $env:SystemDrive, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)},
        $env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}, $env:ProgramData,
        (Join-Path $env:SystemDrive 'Users')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ((($normalized -split '\\').Count -lt 3) -or ($protected -contains $normalized)) {
        Write-Bad "REFUSING to delete protected path: $full"
        $script:Resistant.Add($full)
        return
    }

    # If the target itself is a junction/symlink, unlink it only — never follow
    # it into (and delete) whatever it points at.
    if (Test-IsReparsePoint $full) {
        Remove-LinkOnly $full
        if (-not (Test-Path -LiteralPath $full)) { Write-Ok "Removed link (target untouched): $full" }
        else { $script:Resistant.Add($full); Write-Bad "Could not remove link: $full" }
        return
    }

    $isDir = Test-Path -LiteralPath $full -PathType Container

    # Strip any nested junctions/symlinks as links first, so the recursive
    # takeown /R, icacls /T and Remove-Item -Recurse below cannot traverse a
    # reparse point into unrelated data (Remove-Item follows them on PS 5.1).
    if ($isDir) { Remove-NestedReparsePoints -Dir $full }

    # 1) plain delete
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $full)) { Write-Ok "Removed: $full"; return }

    # 2) take ownership and grant access, then retry. Grant Administrators
    #    (*S-1-5-32-544) + SYSTEM (*S-1-5-18) by SID so it works on non-English
    #    Windows. NOT Everyone: a surviving Everyone:F ACE would linger as a
    #    world-writable privilege-escalation surface.
    if ($isDir) {
        takeown.exe /F "$full" /R /A /D Y 2>&1 | Out-Null
        icacls.exe "$full" /grant '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
    } else {
        takeown.exe /F "$full" /A 2>&1 | Out-Null
        icacls.exe "$full" /grant '*S-1-5-32-544:F' '*S-1-5-18:F' /C /Q 2>&1 | Out-Null
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $full)) { Write-Ok "Removed after taking ownership: $full"; return }

    # 3) cmd fallback (handles some path/attribute cases PowerShell chokes on)
    if ($isDir) { cmd.exe /d /c "rd /s /q `"$full`"" 2>&1 | Out-Null }
    else        { cmd.exe /d /c "del /f /q `"$full`"" 2>&1 | Out-Null }
    if (-not (Test-Path -LiteralPath $full)) { Write-Ok "Removed via cmd: $full"; return }

    # 4) locked by a running driver/service: queue for deletion at next reboot
    #    (children first — a directory can only be reboot-deleted once empty)
    $targets = @()
    if ($isDir) {
        $targets += @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue |
                      Sort-Object { $_.FullName.Length } -Descending |
                      Select-Object -ExpandProperty FullName)
    }
    $targets += $full
    $queued = 0
    foreach ($target in $targets) {
        if ([Win32.PendingDelete]::MoveFileEx($target, $null, 4)) { $queued++ }  # 4 = MOVEFILE_DELAY_UNTIL_REBOOT
    }
    if ($queued -gt 0) {
        $script:RebootNeeded = $true
        Write-Bad "Locked — $queued item(s) queued for deletion at next reboot: $full"
    } else {
        # Could not delete and could not queue: restore inherited ACLs so the
        # explicit ACE we granted above does not linger on a surviving item.
        icacls.exe "$full" /reset /T /C /Q 2>&1 | Out-Null
        $script:Resistant.Add($full)
        Write-Bad "Still resistant: $full"
    }
}

# ===========================================================================
#  Generic AV/EDR removal engine
#
#  One parametrized engine drives every vendor. A vendor is described by a
#  config hashtable (see the $script:Vendors registry) that is splatted in.
#  The stages mirror the original McAfee routine: official uninstaller first,
#  then force-remove processes → services/drivers → tasks → AppX → folders →
#  registry/autoruns, with an optional whole-drive leftover sweep.
#
#  Two knobs make it cover more than consumer AV:
#    • PreUninstall — a vendor scriptblock run before anything else, used to
#      disable self-protection or run a token/passphrase uninstall (EDRs).
#    • CoreServices — when set, the vendor is treated as tamper-protected: if
#      any core service is STILL present after the uninstall attempt, we stop
#      before the destructive stages. Brute-force deleting a running,
#      self-protecting kernel agent (CrowdStrike, SentinelOne) does not work
#      and can leave the machine unbootable — the supported path is the
#      maintenance token / passphrase from the vendor console.
# ===========================================================================

function Invoke-VendorCleaner {
    # Download and run a vendor's official cleaner/removal tool. Best-effort:
    # URLs and silent-switch support vary by vendor and change over time, so a
    # dead link or a GUI-only tool degrades gracefully instead of aborting.
    param([Parameter(Mandatory = $true)][hashtable]$Cleaner)

    $dest = Join-Path $env:TEMP $Cleaner.Name
    Write-Host "  Downloading $($Cleaner.Name)..." -ForegroundColor Gray
    try {
        # Older Windows defaults to TLS 1.0; force 1.2 so the download works.
        try { [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        Invoke-WebRequest -Uri $Cleaner.Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Bad "Download failed for $($Cleaner.Name) (URL may have moved): $($_.Exception.Message)"
        return
    }
    if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -lt 10240) {
        Write-Bad "$($Cleaner.Name) did not download correctly — skipping."
        return
    }
    if ($Cleaner.Note) { Write-Bad $Cleaner.Note }
    Write-Host ("  Launching $($Cleaner.Name) $($Cleaner.Args)").TrimEnd() -ForegroundColor Gray
    try {
        $sp = @{ FilePath = $dest; PassThru = $true }
        if ($Cleaner.Args) { $sp['ArgumentList'] = $Cleaner.Args }
        $p = Start-Process @sp
        if (-not $p.WaitForExit(1800000)) {          # 30 min ceiling
            Write-Bad "$($Cleaner.Name) is still running — leaving it to finish on its own."
        } else {
            if ($p.ExitCode -in 3010, 1641) { $script:RebootNeeded = $true }   # reboot-required codes
            Write-Ok "$($Cleaner.Name) exited (code $($p.ExitCode))."
        }
    } catch {
        Write-Bad "Could not run $($Cleaner.Name): $($_.Exception.Message)"
    }
}

function Invoke-GenericAvRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$ProductMatch,   # regex vs "DisplayName Publisher" and service DisplayName/PathName
        [string]$ServiceExact = '(?!x)x',                      # regex vs service/process Name (default: never matches)
        [string[]]$FolderNames = @(),                          # folder base names under program roots + each user's AppData
        [string[]]$ExtraFolders = @(),                         # explicit absolute folder paths
        [string[]]$RegKeys = @(),
        [string]$RunKeyMatch = $null,                          # autorun match regex (defaults to $ProductMatch)
        [string[]]$AppxPatterns = @(),
        [string[]]$DeepFilters = @(),                          # wildcard(s) for the deep scan (e.g. '*norton*','*symantec*')
        [string[]]$CoreServices = @(),                         # tamper-protected core services (empty => not protected)
        [scriptblock]$PreUninstall = $null,
        [hashtable[]]$Cleaners = @(),                          # optional public cleaner tools (Name/Url/Args/Note)
        [switch]$DeepScan,
        [switch]$SkipUninstallers
    )

    if (-not $RunKeyMatch) { $RunKeyMatch = $ProductMatch }
    $nameRe = $ProductMatch
    $svcRe  = $ServiceExact

    # ---- inventory --------------------------------------------------------
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $products = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { "$($_.DisplayName) $($_.Publisher)" -match $nameRe -and $_.UninstallString })

    if ($products.Count -gt 0) {
        Write-Host "`nInstalled $DisplayName products:" -ForegroundColor Cyan
        $products | ForEach-Object { Write-Host "   $($_.DisplayName)" }
    } else {
        Write-Host "`nNo $DisplayName products registered in the registry (will still sweep for leftovers)." -ForegroundColor Gray
    }

    # ---- 0) vendor pre-step (unprotect / token uninstall) -----------------
    if ($PreUninstall) {
        Write-Step "$DisplayName pre-removal step"
        try { & $PreUninstall $products } catch { Write-Bad "Pre-step failed: $($_.Exception.Message)" }
    }

    # ---- 1) official uninstallers first -----------------------------------
    # Doing this before force-deleting files keeps Windows Installer state clean
    # and lets the vendor's own uninstaller unhook drivers/WFP filters properly.
    if (-not $SkipUninstallers -and $products.Count -gt 0) {
        Write-Step 'Running official uninstallers'
        foreach ($p in $products) {
            $cmd = $null
            $quiet = $true
            if ($p.QuietUninstallString) {
                $cmd = $p.QuietUninstallString
            } elseif ($p.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
                $cmd = "msiexec.exe /x $($p.PSChildName) /qn /norestart"
            } else {
                $cmd = $p.UninstallString
                $quiet = $false   # may show UI — let it, rather than hang hidden
            }
            Write-Host "  Uninstalling: $($p.DisplayName)" -ForegroundColor Gray
            try {
                $style = 'Normal'
                if ($quiet) { $style = 'Hidden' }
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c "' + $cmd + '"') `
                                      -WindowStyle $style -PassThru
                if (-not $proc.WaitForExit(600000)) {   # 10 min per product
                    # Kill the whole tree (/T): the cmd wrapper AND the msiexec/setup
                    # child it launched. Killing only cmd would orphan the hung
                    # uninstaller, which would keep running while we force-delete.
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $($proc.Id) /T /F" `
                                  -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                    Write-Bad "Timed out: $($p.DisplayName) (continuing with forced removal)"
                } elseif ($proc.ExitCode -in 0, 1605, 3010) {   # ok / already gone / ok-needs-reboot
                    if ($proc.ExitCode -eq 3010) { $script:RebootNeeded = $true }
                    Write-Ok "Uninstalled: $($p.DisplayName)"
                } else {
                    Write-Bad "Uninstaller for $($p.DisplayName) returned $($proc.ExitCode)"
                }
            } catch {
                Write-Bad "Could not run uninstaller for $($p.DisplayName): $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2   # let msiexec settle between products
        }
    }

    # ---- 1b) official vendor cleaner tool (opt-in download) ---------------
    # Most consumer vendors publish a dedicated removal utility. Offer to pull
    # and run it — it often clears leftovers the registered uninstaller leaves.
    if ($Cleaners.Count -gt 0) {
        $names = ($Cleaners | ForEach-Object { $_.Name }) -join ', '
        $ans = Read-Host "  Download & run the official $DisplayName cleaner ($names)? [y/N]"
        if ($ans -match '^(y|yes)$') {
            Write-Step "Running official $DisplayName cleaner tool"
            foreach ($cl in $Cleaners) { Invoke-VendorCleaner -Cleaner $cl }
        }
    }

    # ---- tamper-protection gate (EDRs) ------------------------------------
    # If a protected core service survived the uninstall, self-protection won.
    # Stop before the destructive stages rather than fight (and lose to) a
    # running kernel agent.
    if ($CoreServices.Count -gt 0) {
        $stillProtected = @()
        foreach ($core in $CoreServices) {
            sc.exe query "$core" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 1060) { $stillProtected += $core }   # 1060 = ERROR_SERVICE_DOES_NOT_EXIST
        }
        if ($stillProtected.Count -gt 0) {
            $script:ProtectedBlocked = $true
            $msg = "$DisplayName is still tamper-protected (core service present: $($stillProtected -join ', ')). Supply the maintenance token / passphrase from your $DisplayName console and re-run. Not force-deleting a running protected agent — that would risk an unbootable machine."
            $script:Resistant.Add($msg)
            Write-Bad $msg
            return
        }
        Write-Ok "$DisplayName agent removed — cleaning up leftovers."
    }

    # ---- 2) kill processes ------------------------------------------------
    Write-Step "Killing remaining $DisplayName processes"
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match $nameRe -or $_.Name -match $svcRe -or
        ($_.Path -and $_.Path -match $nameRe)
    })
    if ($procs.Count -eq 0) { Write-Host '  none running' -ForegroundColor Gray }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Ok "Killed: $($p.Name) (PID $($p.Id))"
        } catch {
            Write-Bad "Could not kill $($p.Name): $($_.Exception.Message)"
        }
    }

    # ---- 3) services + kernel drivers -------------------------------------
    Write-Step "Removing $DisplayName services and drivers"
    $services = @()
    foreach ($class in 'Win32_Service', 'Win32_SystemDriver') {
        $services += @(Get-CimInstance -ClassName $class -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match $svcRe -or "$($_.DisplayName) $($_.PathName)" -match $nameRe
        })
    }
    if ($services.Count -eq 0) { Write-Host '  none found' -ForegroundColor Gray }
    foreach ($svc in $services) {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        sc.exe config "$($svc.Name)" start= disabled 2>&1 | Out-Null
        sc.exe delete "$($svc.Name)" 2>&1 | Out-Null
        $deleteExit = $LASTEXITCODE
        if ($deleteExit -eq 0) {
            # sc.exe delete returns 0 even when it only *marks* a still-running
            # service for deletion (the SCM entry survives until the service
            # stops, i.e. at reboot for self-protected services). Re-query.
            sc.exe query "$($svc.Name)" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 1060) {   # ERROR_SERVICE_DOES_NOT_EXIST -> really gone
                Write-Ok "Deleted service: $($svc.Name)"
            } else {
                $script:RebootNeeded = $true
                Write-Ok "Service marked for deletion at reboot: $($svc.Name)"
            }
        } elseif ($deleteExit -eq 1072) {   # already marked for deletion
            $script:RebootNeeded = $true
            Write-Ok "Service marked for deletion at reboot: $($svc.Name)"
        } else {
            $script:Resistant.Add("service: $($svc.Name)")
            Write-Bad "Could not delete service $($svc.Name) (sc.exe exit code $deleteExit)"
        }
    }

    # ---- 4) scheduled tasks -----------------------------------------------
    Write-Step "Removing $DisplayName scheduled tasks"
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        "$($_.TaskName) $($_.TaskPath)" -match $nameRe
    })
    if ($tasks.Count -eq 0) { Write-Host '  none found' -ForegroundColor Gray }
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Ok "Removed task: $($t.TaskPath)$($t.TaskName)"
        } catch {
            Write-Bad "Could not remove task $($t.TaskName): $($_.Exception.Message)"
        }
    }

    # ---- 5) AppX packages -------------------------------------------------
    Write-Step "Removing $DisplayName Store/AppX packages"
    if ($AppxPatterns.Count -eq 0) {
        Write-Host '  n/a for this vendor' -ForegroundColor Gray
    } else {
        try {
            $anyAppx = $false
            foreach ($pat in $AppxPatterns) {
                $appx = @(Get-AppxPackage -AllUsers -Name $pat -ErrorAction SilentlyContinue)
                foreach ($pkg in $appx) {
                    $anyAppx = $true
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                        Write-Ok "Removed AppX: $($pkg.Name)"
                    } catch {
                        Write-Bad "AppX $($pkg.Name): $($_.Exception.Message)"
                    }
                }
                Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like $pat } | ForEach-Object {
                        $anyAppx = $true
                        try {
                            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                            Write-Ok "Deprovisioned: $($_.DisplayName)"
                        } catch {
                            Write-Bad "Provisioned $($_.DisplayName): $($_.Exception.Message)"
                        }
                    }
            }
            if (-not $anyAppx) { Write-Host '  none installed' -ForegroundColor Gray }
        } catch {
            Write-Bad "AppX cleanup failed: $($_.Exception.Message)"
        }
    }

    # ---- 6) known folder nuke ---------------------------------------------
    Write-Step "Deleting known $DisplayName folders"
    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:CommonProgramFiles,
                        ${env:CommonProgramFiles(x86)}, $env:ProgramData)) {
        if ($root) {
            foreach ($name in $FolderNames) {
                $folders.Add((Join-Path $root $name))
            }
        }
    }
    foreach ($userDir in @(Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
        foreach ($name in $FolderNames) {
            foreach ($sub in 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow') {
                $folders.Add((Join-Path $userDir.FullName (Join-Path $sub $name)))
            }
        }
    }
    foreach ($x in $ExtraFolders) { if ($x) { $folders.Add($x) } }
    $found = $false
    foreach ($f in $folders) {
        if (Test-Path -LiteralPath $f) { $found = $true; Remove-ItemForcefully -Path $f }
    }
    if (-not $found) { Write-Host '  none present' -ForegroundColor Gray }

    # ---- 7) registry keys -------------------------------------------------
    Write-Step "Cleaning $DisplayName registry keys"
    foreach ($key in $RegKeys) {
        if (Test-Path -LiteralPath $key) {
            try {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                Write-Ok "Removed: $key"
            } catch {
                $script:Resistant.Add($key)
                Write-Bad "Could not remove ${key}: $($_.Exception.Message)"
            }
        }
    }

    # autorun entries that launch the vendor
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($runKey in $runKeys) {
        if (-not (Test-Path -LiteralPath $runKey)) { continue }
        $entry = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
        if (-not $entry) { continue }
        foreach ($prop in $entry.PSObject.Properties) {
            if ($prop.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
            if ("$($prop.Name) $($prop.Value)" -match $RunKeyMatch) {
                try {
                    Remove-ItemProperty -Path $runKey -Name $prop.Name -Force -ErrorAction Stop
                    Write-Ok "Removed autorun entry: $($prop.Name)"
                } catch {
                    Write-Bad "Could not remove autorun $($prop.Name): $($_.Exception.Message)"
                }
            }
        }
    }

    # ---- 8) optional deep scan --------------------------------------------
    if ($DeepScan -and $DeepFilters.Count -gt 0) {
        Write-Step "Deep-scanning $env:SystemDrive\ for leftovers (this can take a while)"

        # never touch these, even on a match
        $excludeRoots = @(
            (Join-Path $env:windir 'WinSxS'),
            (Join-Path $env:windir 'servicing'),
            (Join-Path $env:SystemDrive '$Recycle.Bin')
        ) | ForEach-Object { $_.TrimEnd('\') + '\' }
        $excludeFiles = @($script:LogFile) | Where-Object { $_ }

        # matches under these roots are program/system data — safe to auto-delete
        $safeRoots = New-Object System.Collections.Generic.List[string]
        foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:CommonProgramFiles,
                         ${env:CommonProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:windir 'Temp'))) {
            if ($r) { $safeRoots.Add($r.TrimEnd('\') + '\') }
        }
        foreach ($userDir in @(Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
            $safeRoots.Add((Join-Path $userDir.FullName 'AppData').TrimEnd('\') + '\')
        }

        # one pass per filter (NTFS wildcard matching ignores case), then dedup
        $hits = @()
        foreach ($filt in $DeepFilters) {
            $hits += @(Get-ChildItem -Path "$env:SystemDrive\" -Filter $filt -Recurse -Force -ErrorAction SilentlyContinue)
        }
        $hits = @($hits | Sort-Object -Property FullName -Unique)
        Write-Host "  $($hits.Count) match(es) found" -ForegroundColor Gray

        # directories first (shortest path first, so children vanish with parents)
        $dirs  = @($hits | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length })
        $files = @($hits | Where-Object { -not $_.PSIsContainer })
        foreach ($hit in ($dirs + $files)) {
            $full = $hit.FullName
            if (-not (Test-Path -LiteralPath $full)) { continue }   # parent already removed
            if ($excludeFiles -contains $full) { continue }
            if (Test-PathStartsWith -Path $full -Prefixes $excludeRoots) { continue }
            if (Test-PathStartsWith -Path $full -Prefixes $safeRoots) {
                Remove-ItemForcefully -Path $full
            } else {
                $script:ReviewOnly.Add($full)   # user data — report, don't delete
            }
        }
    }
}

# ===========================================================================
#  Vendor pre-removal steps (self-protection / token uninstall)
# ===========================================================================

# CrowdStrike Falcon: tamper-protected. The supported uninstall is the sensor
# MSI with the MAINTENANCE_TOKEN pulled from the Falcon console (Host setup and
# management → Sensor update policies → uninstall token). Without it, if
# uninstall protection is on, removal will fail — and we WON'T brute-force it.
$script:PreUninstall_CrowdStrike = {
    param($products)
    $guids = @($products | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' } |
        Select-Object -ExpandProperty PSChildName)
    if ($guids.Count -eq 0) {
        Write-Bad 'No CrowdStrike sensor MSI found in the registry to uninstall.'
        return
    }
    $token = Read-Host '  CrowdStrike maintenance token (leave blank if uninstall protection is OFF)'
    foreach ($g in $guids) {
        $a = "/x $g /qn /norestart"
        if ($token) { $a += " MAINTENANCE_TOKEN=$token" }
        Write-Host "  Running sensor uninstall for $g" -ForegroundColor Gray
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -in 0, 1605, 3010) {
            if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
            Write-Ok "Sensor uninstall returned $($p.ExitCode)"
        } else {
            Write-Bad "Sensor uninstall returned $($p.ExitCode) (wrong or missing maintenance token?)"
        }
    }
}

# SentinelOne: tamper-protected. Disable anti-tamper with the site/group
# passphrase via sentinelctl, then uninstall. Passphrase comes from the S1
# console (Sentinels → the endpoint → Actions → Show Passphrase).
$script:PreUninstall_SentinelOne = {
    param($products)
    $pass = Read-Host '  SentinelOne passphrase (from the S1 console; blank to try without)'
    $s1Root = Join-Path $env:ProgramFiles 'SentinelOne'
    $ctl = $null
    if (Test-Path -LiteralPath $s1Root) {
        $ctl = Get-ChildItem -LiteralPath $s1Root -Recurse -Filter 'sentinelctl.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($ctl) {
        Write-Host "  Found $($ctl.FullName)" -ForegroundColor Gray
        try {
            if ($pass) { & $ctl.FullName unprotect -k $pass 2>&1 | Out-Null }
            else       { & $ctl.FullName unprotect      2>&1 | Out-Null }
            Write-Ok 'Ran sentinelctl unprotect.'
        } catch {
            Write-Bad "sentinelctl unprotect failed: $($_.Exception.Message)"
        }
    } else {
        Write-Bad 'sentinelctl.exe not found under Program Files\SentinelOne.'
    }
    $guids = @($products | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' } |
        Select-Object -ExpandProperty PSChildName)
    foreach ($g in $guids) {
        $a = "/x $g /qn /norestart"
        if ($pass) { $a += " PASSPHRASE=$pass" }
        Write-Host "  Running agent uninstall for $g" -ForegroundColor Gray
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -in 0, 1605, 3010) {
            if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
            Write-Ok "Agent uninstall returned $($p.ExitCode)"
        } else {
            Write-Bad "Agent uninstall returned $($p.ExitCode) (wrong or missing passphrase?)"
        }
    }
}

# Shared helper for EDRs whose uninstall takes a single MSI property (a password
# or company/uninstall code) the admin gets from the vendor console.
function Invoke-TokenMsiUninstall {
    param(
        [object[]]$Products,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Property
    )
    $guids = @($Products | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$' } |
        Select-Object -ExpandProperty PSChildName)
    if ($guids.Count -eq 0) { Write-Bad 'No matching MSI product found to uninstall.'; return }
    $val = Read-Host $Prompt
    foreach ($g in $guids) {
        $a = "/x $g /qn /norestart"
        if ($val) { $a += " $Property=$val" }
        Write-Host "  Running uninstall for $g" -ForegroundColor Gray
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -in 0, 1605, 3010) {
            if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
            Write-Ok "Uninstall returned $($p.ExitCode)"
        } else {
            Write-Bad "Uninstall returned $($p.ExitCode) (wrong or missing $Property?)"
        }
    }
}

# BlackBerry/Cylance PROTECT: uninstall password (device policy) via MSI property.
$script:PreUninstall_Cylance = {
    param($products)
    Invoke-TokenMsiUninstall -Products $products `
        -Prompt '  Cylance uninstall password (blank if the policy has none)' `
        -Property 'UNINSTALLPASSWORD'
}

# VMware Carbon Black Cloud sensor: company/uninstall code from the CB console.
$script:PreUninstall_CarbonBlack = {
    param($products)
    Invoke-TokenMsiUninstall -Products $products `
        -Prompt '  Carbon Black uninstall/company code (blank if none)' `
        -Property 'UNINSTALL_CODE'
}

# ===========================================================================
#  Vendor registry — single source of truth for the menu.
#
#  Each entry: Key/Name/Blurb/Ready for the menu, Protected for the confirm
#  wording, FallbackNote for the summary, and Config (splatted straight into
#  Invoke-GenericAvRemoval). Add a new AV by dropping one object here.
# ===========================================================================

$script:Vendors = @(
    [pscustomobject]@{
        Key = 'mcafee'; Name = 'McAfee'; Ready = $true; Protected = $false
        Blurb = 'Total Protection, LiveSafe, Security Scan, WebAdvisor, enterprise agent'
        FallbackNote = "Anything left? Finish with McAfee's official MCPR tool: https://www.mcafee.com/support"
        Config = @{
            DisplayName  = 'McAfee'
            ProductMatch = 'mcafee'
            ServiceExact = '^(mfe\w*|masvc|macmnsvc|macompatsvc|mctaskmanager|mcapexe|mcawfwk|mccspsvc|mccspservicehost|mcuicnt|mcpvtray|mcshield|mcsacore|mmsshost|modulecoreservice|pefservice|protectedmodulehost|qcshm)$'
            FolderNames  = @('McAfee', 'McAfee.com', 'McAfee Security Scan')
            RegKeys      = @('HKLM:\SOFTWARE\McAfee', 'HKLM:\SOFTWARE\McAfee.com',
                             'HKLM:\SOFTWARE\WOW6432Node\McAfee', 'HKLM:\SOFTWARE\WOW6432Node\McAfee.com',
                             'HKCU:\SOFTWARE\McAfee')
            AppxPatterns = @('*mcafee*')
            DeepFilters  = @('*mcafee*')
            Cleaners     = @(
                @{ Name = 'MCPR.exe'
                   Url  = 'https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe'
                   Args = ''
                   Note = 'MCPR is an interactive GUI — click through it; it may prompt to reboot.' }
            )
        }
    }
    [pscustomobject]@{
        Key = 'norton'; Name = 'Norton / Symantec'; Ready = $true; Protected = $false
        Blurb = 'Norton 360 / Security, NortonLifeLock, Symantec Endpoint Protection'
        FallbackNote = "Norton consumer leftovers: Norton Remove and Reinstall tool. Symantec Endpoint Protection: Broadcom's CleanWipe."
        Config = @{
            DisplayName  = 'Norton / Symantec'
            ProductMatch = 'norton|symantec|nortonlifelock'
            ServiceExact = '^(nortonsecurity|nsservice|nswscsvc|n360|navapsvc|ccsvchst|ccsettmgr|ccevtmgr|smcservice|smc|rtvscan|sepmasterservice|sepwscsvc|symefasi|symcorpui|nis|bhdrvx\w*|eeCtrl|symnets|symtdi|srtsp\w*)$'
            FolderNames  = @('Norton', 'Norton Security', 'NortonInstaller', 'Norton 360',
                             'Symantec', 'Symantec Endpoint Protection')
            RegKeys      = @('HKLM:\SOFTWARE\Norton', 'HKLM:\SOFTWARE\Symantec',
                             'HKLM:\SOFTWARE\WOW6432Node\Norton', 'HKLM:\SOFTWARE\WOW6432Node\Symantec',
                             'HKCU:\SOFTWARE\Norton', 'HKCU:\SOFTWARE\Symantec')
            AppxPatterns = @('*norton*')
            DeepFilters  = @('*norton*', '*symantec*')
        }
    }
    [pscustomobject]@{
        Key = 'avast'; Name = 'Avast / AVG'; Ready = $true; Protected = $false
        Blurb = 'Avast Antivirus / One and AVG (same engine)'
        FallbackNote = "Self-Defense blocking removal? Run avastclear.exe (Avast) or aswclear.exe (AVG) in Safe Mode."
        Config = @{
            DisplayName  = 'Avast / AVG'
            ProductMatch = 'avast|avg technologies|\bavg\b'
            ServiceExact = '^(avast\w*|aswbidsagent|aswbidsdriver|aswidsagent|avastsvc|aswstm|aswvmm|aswsp|aswmonflt|aswsnx|aswrvrt|aswarpot|avg\w*|avgsvc|avgbidsagent|avgtoolsvc|avgntflt|avgstls)$'
            FolderNames  = @('Avast Software', 'AVAST Software', 'AVG')
            RegKeys      = @('HKLM:\SOFTWARE\Avast Software', 'HKLM:\SOFTWARE\AVG',
                             'HKLM:\SOFTWARE\WOW6432Node\Avast Software', 'HKLM:\SOFTWARE\WOW6432Node\AVG',
                             'HKCU:\SOFTWARE\Avast Software', 'HKCU:\SOFTWARE\AVG')
            AppxPatterns = @('*avast*', '*avg*')
            DeepFilters  = @('*avast*', '*avg*')
            Cleaners     = @(
                @{ Name = 'avastclear.exe'
                   Url  = 'https://files.avast.com/iavs9x/avastclear.exe'
                   Args = ''
                   Note = 'avastclear works best in Safe Mode — it can offer to schedule itself there. (Covers Avast; for AVG use aswclear from avg.com/utilities.)' }
            )
        }
    }
    [pscustomobject]@{
        Key = 'crowdstrike'; Name = 'CrowdStrike Falcon'; Ready = $true; Protected = $true
        Blurb = 'Falcon sensor (EDR) — needs the maintenance token from your Falcon console'
        FallbackNote = "Falcon uninstall protection blocks removal without a token. Get it in Falcon: Host setup & management -> Sensor update policies -> uninstall token."
        Config = @{
            DisplayName   = 'CrowdStrike Falcon'
            ProductMatch  = 'crowdstrike|falcon sensor'
            ServiceExact  = '^(csagent|csfalconservice|csfalconcontainer|csdevicecontrol)$'
            CoreServices  = @('csagent', 'CSFalconService')
            FolderNames   = @('CrowdStrike')
            RegKeys       = @('HKLM:\SOFTWARE\CrowdStrike', 'HKLM:\SOFTWARE\WOW6432Node\CrowdStrike')
            DeepFilters   = @('*crowdstrike*')
            PreUninstall  = $script:PreUninstall_CrowdStrike
        }
    }
    [pscustomobject]@{
        Key = 'sentinelone'; Name = 'SentinelOne'; Ready = $true; Protected = $true
        Blurb = 'S1 agent (EDR) — needs the anti-tamper passphrase from your S1 console'
        FallbackNote = "S1 anti-tamper blocks removal without the passphrase. Get it in the S1 console: Sentinels -> the endpoint -> Actions -> Show Passphrase."
        Config = @{
            DisplayName   = 'SentinelOne'
            ProductMatch  = 'sentinelone|sentinel agent|\bsentinel\b'
            ServiceExact  = '^(sentinelagent|sentinelhelperservice|sentinelstaticengine\w*|logprocessorservice|sentinelmemoryscanner|sentinelservicehost|sentinelnetworkmonitor)$'
            CoreServices  = @('SentinelAgent', 'SentinelHelperService', 'LogProcessorService')
            FolderNames   = @('SentinelOne', 'Sentinel')
            RegKeys       = @('HKLM:\SOFTWARE\SentinelOne', 'HKLM:\SOFTWARE\Sentinel Labs',
                             'HKLM:\SOFTWARE\WOW6432Node\SentinelOne')
            DeepFilters   = @('*sentinel*')
            PreUninstall  = $script:PreUninstall_SentinelOne
        }
    }

    # ---- more consumer AV (full force-removal) ----------------------------
    [pscustomobject]@{
        Key = 'bitdefender'; Name = 'Bitdefender'; Ready = $true; Protected = $false
        Blurb = 'Bitdefender consumer + GravityZone Endpoint (BEST) agent'
        FallbackNote = "Leftovers? Bitdefender publishes a per-product Uninstall Tool at bitdefender.com/consumer/support/answer/2681/."
        Config = @{
            DisplayName  = 'Bitdefender'
            ProductMatch = 'bitdefender'
            ServiceExact = '^(vsserv|updatesrv|bdredline\w*|epsecurityservice|epupdateservice|epprotectedservice|epintegrationservice|bdauxsrv)$'
            FolderNames  = @('Bitdefender', 'Bitdefender Agent')
            RegKeys      = @('HKLM:\SOFTWARE\Bitdefender', 'HKLM:\SOFTWARE\WOW6432Node\Bitdefender')
            DeepFilters  = @('*bitdefender*')
        }
    }
    [pscustomobject]@{
        Key = 'eset'; Name = 'ESET'; Ready = $true; Protected = $false
        Blurb = 'ESET NOD32 / Internet Security / Endpoint, ESET Management Agent'
        FallbackNote = "Stubborn? Boot into Safe Mode and run ESETUninstaller.exe (ESET KB SOLN2289)."
        Config = @{
            DisplayName  = 'ESET'
            ProductMatch = 'eset'
            ServiceExact = '^(ekrn|egui|eraagentsvc|eguiproxy)$'
            FolderNames  = @('ESET')
            RegKeys      = @('HKLM:\SOFTWARE\ESET', 'HKLM:\SOFTWARE\WOW6432Node\ESET')
            DeepFilters  = @('*eset*')
        }
    }
    [pscustomobject]@{
        Key = 'webroot'; Name = 'Webroot'; Ready = $true; Protected = $false
        Blurb = 'Webroot SecureAnywhere'
        FallbackNote = "Orphaned Webroot? Support provides a CleanUp / WRUpgradeTool utility."
        Config = @{
            DisplayName  = 'Webroot'
            ProductMatch = 'webroot'
            ServiceExact = '^(wrsvc|wrskyclient|wrcoreservice)$'
            FolderNames  = @('Webroot', 'WRData', 'WRCore', 'WRMIDData')
            RegKeys      = @('HKLM:\SOFTWARE\WRData', 'HKLM:\SOFTWARE\WRCore', 'HKLM:\SOFTWARE\WRMIDData',
                             'HKLM:\SOFTWARE\WOW6432Node\WRData', 'HKLM:\SOFTWARE\WOW6432Node\WRCore')
            DeepFilters  = @('*webroot*')
        }
    }
    [pscustomobject]@{
        Key = 'malwarebytes'; Name = 'Malwarebytes'; Ready = $true; Protected = $false
        Blurb = 'Malwarebytes consumer + Endpoint (Nebula/OneView) agent'
        FallbackNote = "The Malwarebytes Support Tool (mb-clean) removes stubborn installs."
        Config = @{
            DisplayName  = 'Malwarebytes'
            ProductMatch = 'malwarebytes'
            ServiceExact = '^(mbamservice|mbendpointagent|mbcloudea|mbamscheduler)$'
            FolderNames  = @('Malwarebytes', 'Malwarebytes Endpoint Agent')
            RegKeys      = @('HKLM:\SOFTWARE\Malwarebytes', 'HKLM:\SOFTWARE\WOW6432Node\Malwarebytes')
            DeepFilters  = @('*malwarebytes*')
            Cleaners     = @(
                @{ Name = 'mb-support-tool.exe'
                   Url  = 'https://downloads.malwarebytes.com/file/mbst'
                   Args = ''
                   Note = 'Malwarebytes Support Tool — use its Advanced tab -> Clean to fully remove.' }
            )
        }
    }
    [pscustomobject]@{
        Key = 'kaspersky'; Name = 'Kaspersky'; Ready = $true; Protected = $false
        Blurb = 'Kaspersky consumer, Endpoint Security, Network Agent'
        FallbackNote = "kavremover is the official removal tool (offered above)."
        Config = @{
            DisplayName  = 'Kaspersky'
            ProductMatch = 'kaspersky'
            ServiceExact = '^(avp\w*|klnagent|kavfs\w*|ksde\w*|klbackupflt)$'
            FolderNames  = @('Kaspersky Lab', 'Kaspersky Lab Setup Files')
            RegKeys      = @('HKLM:\SOFTWARE\KasperskyLab', 'HKLM:\SOFTWARE\WOW6432Node\KasperskyLab')
            DeepFilters  = @('*kaspersky*')
            Cleaners     = @(
                @{ Name = 'kavremover.exe'
                   Url  = 'https://media.kaspersky.com/utilities/ConsumerUtilities/kavremover.exe'
                   Args = ''
                   Note = 'kavremover GUI — pick the product and remove. Password-protected installs need the KAV password first.' }
            )
        }
    }
    [pscustomobject]@{
        Key = 'avira'; Name = 'Avira'; Ready = $true; Protected = $false
        Blurb = 'Avira Free / Antivirus / Prime'
        FallbackNote = "Leftovers? Avira's RegistryCleaner utility clears them."
        Config = @{
            DisplayName  = 'Avira'
            ProductMatch = 'avira'
            ServiceExact = '^(antivirservice|antivirschedulerservice|avguard|avgnt|avira\.\w+|avirawebcat|aviraphantomvpn)$'
            FolderNames  = @('Avira')
            RegKeys      = @('HKLM:\SOFTWARE\Avira', 'HKLM:\SOFTWARE\WOW6432Node\Avira')
            DeepFilters  = @('*avira*')
        }
    }

    # ---- more EDR / tamper-protected -------------------------------------
    [pscustomobject]@{
        Key = 'trendmicro'; Name = 'Trend Micro'; Ready = $true; Protected = $true
        Blurb = 'Trend Micro consumer + Apex One / OfficeScan (business needs the unload password)'
        FallbackNote = "Business agents self-protect: set the Apex One/OfficeScan uninstall password (or unload the agent) first. Trend support has the SIC removal tool for orphans."
        Config = @{
            DisplayName   = 'Trend Micro'
            ProductMatch  = 'trend micro'
            ServiceExact  = '^(ntrtscan|tmlisten|tmbmserver|amsp|tmccsf|tmusa|tmwscsvc|tmactmon\w*|coreserviceshell|coreframeworkhost)$'
            CoreServices  = @('ntrtscan', 'TmListen', 'Amsp')
            FolderNames   = @('Trend Micro')
            RegKeys       = @('HKLM:\SOFTWARE\TrendMicro', 'HKLM:\SOFTWARE\WOW6432Node\TrendMicro')
            DeepFilters   = @('*trend micro*', '*trendmicro*')
        }
    }
    [pscustomobject]@{
        Key = 'sophos'; Name = 'Sophos'; Ready = $true; Protected = $true
        Blurb = 'Sophos Endpoint / Intercept X (tamper-protected)'
        FallbackNote = "Turn off Tamper Protection in Sophos Central (or with the local tamper password) before removal. Support's SophosZap forcibly removes orphans."
        Config = @{
            DisplayName   = 'Sophos'
            ProductMatch  = 'sophos'
            ServiceExact  = '^(savservice|sntpservice|swi_service|swi_update\w*|sophosfilescanner|sophosmcsagent|sophosmcsclient|sophoshealthservice|sedservice|hmpalertsvc|sophosdiagnosticsservice|sophosnetfilter)$'
            CoreServices  = @('Sophos Endpoint Defense Service', 'SAVService', 'SntpService')
            FolderNames   = @('Sophos')
            RegKeys       = @('HKLM:\SOFTWARE\Sophos', 'HKLM:\SOFTWARE\WOW6432Node\Sophos')
            DeepFilters   = @('*sophos*')
        }
    }
    [pscustomobject]@{
        Key = 'cylance'; Name = 'BlackBerry / Cylance'; Ready = $true; Protected = $true
        Blurb = 'CylancePROTECT / BlackBerry Protect (uninstall password)'
        FallbackNote = "Set/obtain the Cylance uninstall password from the console policy; the tool passes it as UNINSTALLPASSWORD."
        Config = @{
            DisplayName   = 'BlackBerry / Cylance'
            ProductMatch  = 'cylance|blackberry protect'
            ServiceExact  = '^(cylancesvc|cylanceui|cyprotectdrv\w*|cydevflt\w*)$'
            CoreServices  = @('CylanceSvc')
            FolderNames   = @('Cylance')
            RegKeys       = @('HKLM:\SOFTWARE\Cylance', 'HKLM:\SOFTWARE\WOW6432Node\Cylance')
            DeepFilters   = @('*cylance*')
            PreUninstall  = $script:PreUninstall_Cylance
        }
    }
    [pscustomobject]@{
        Key = 'carbonblack'; Name = 'VMware Carbon Black'; Ready = $true; Protected = $true
        Blurb = 'Carbon Black Cloud / Cb Defense sensor (uninstall code)'
        FallbackNote = "Carbon Black needs the company/uninstall code from the CB console; the tool passes it as UNINSTALL_CODE."
        Config = @{
            DisplayName   = 'VMware Carbon Black'
            ProductMatch  = 'carbon black|cb defense|confer'
            ServiceExact  = '^(carbonblack|cbdefense|cbcomms|cbstream\w*|cbk7\w*|repmgr)$'
            CoreServices  = @('CarbonBlack', 'CbDefense')
            FolderNames   = @('CarbonBlack', 'Confer')
            RegKeys       = @('HKLM:\SOFTWARE\CarbonBlack', 'HKLM:\SOFTWARE\Confer',
                             'HKLM:\SOFTWARE\WOW6432Node\CarbonBlack')
            DeepFilters   = @('*carbonblack*', '*confer*')
            PreUninstall  = $script:PreUninstall_CarbonBlack
        }
    }
)

# ===========================================================================
#  Removal runner — sets up transcript/summary state, calls a vendor action.
# ===========================================================================

function Invoke-Removal {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Vendor,
        [switch]$DeepScan
    )

    # Per-run state shared with the removal primitives.
    $script:RebootNeeded    = $false
    $script:ProtectedBlocked = $false
    $script:Resistant       = New-Object System.Collections.Generic.List[string]
    $script:ReviewOnly      = New-Object System.Collections.Generic.List[string]

    # Log name deliberately avoids the vendor name so -DeepScan never eats it.
    $script:LogFile = Join-Path $env:TEMP ("AV-Removal-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    try { Start-Transcript -Path $script:LogFile -Force | Out-Null } catch { }

    Write-Host ''
    Write-Host "  Target : $($Vendor.Name)" -ForegroundColor White
    Write-Host "  Log    : $script:LogFile" -ForegroundColor Gray
    if ($Vendor.Protected) {
        Write-Host "  $($Vendor.Name) is tamper-protected. Have the maintenance token / passphrase from your $($Vendor.Name) console ready." -ForegroundColor Yellow
        Write-Host "  This runs the supported uninstall, then cleans up leftovers. It will NOT brute-force a still-protected agent." -ForegroundColor Yellow
    } else {
        Write-Host "  This forcibly removes ALL $($Vendor.Name) software, services, drivers, tasks and files." -ForegroundColor Yellow
    }
    $confirm = Read-Host "  Type YES to continue"
    if ($confirm -cne 'YES') {
        Write-Host '  Aborted — nothing was changed.' -ForegroundColor Green
        try { Stop-Transcript | Out-Null } catch { }
        return
    }

    $deep = $DeepScan
    if (-not $deep) {
        $d = Read-Host "  Also deep-scan the whole system drive for leftovers? (slow) [y/N]"
        $deep = ($d -match '^(y|yes)$')
    }

    # Splat the vendor's config straight into the generic engine.
    $cfg = $Vendor.Config
    Invoke-GenericAvRemoval @cfg -DeepScan:([bool]$deep)

    # ---- summary ----------------------------------------------------------
    Write-Step 'Summary'
    if ($script:Resistant.Count -gt 0) {
        Write-Host "  Could NOT be removed:" -ForegroundColor Yellow
        $script:Resistant | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        if ($Vendor.FallbackNote) { Write-Host "  $($Vendor.FallbackNote)" -ForegroundColor Yellow }
    }
    if ($script:ReviewOnly.Count -gt 0) {
        Write-Host "  Matches OUTSIDE program locations — review and delete manually if wanted:" -ForegroundColor Cyan
        $script:ReviewOnly | ForEach-Object { Write-Host "    $_" }
    }
    if ($script:Resistant.Count -eq 0 -and $script:ReviewOnly.Count -eq 0) {
        Write-Host '  Clean — no resistant items.' -ForegroundColor Green
    }
    Write-Host "  Log saved to: $script:LogFile" -ForegroundColor Gray

    try { Stop-Transcript | Out-Null } catch { }

    if ($script:RebootNeeded) {
        Write-Host "`n  A reboot is REQUIRED to finish removing locked files/services." -ForegroundColor Yellow
        $answer = Read-Host '  Reboot now? [y/N]'
        if ($answer -match '^(y|yes)$') { Restart-Computer -Force }
    } else {
        Write-Host "`n  Done. A reboot is recommended." -ForegroundColor Green
    }
}

# ===========================================================================
#  Main menu (TUI)
# ===========================================================================

function Show-Menu {
    Show-Banner
    Write-Host '  Pick an antivirus to force-remove:' -ForegroundColor White
    Write-Host ''
    for ($i = 0; $i -lt $script:Vendors.Count; $i++) {
        $v = $script:Vendors[$i]
        $n = $i + 1
        if ($v.Ready) {
            Write-Host ("   {0}) " -f $n) -ForegroundColor White -NoNewline
            Write-Host $v.Name -ForegroundColor Green -NoNewline
            Write-Host "  —  $($v.Blurb)" -ForegroundColor DarkGray
        } else {
            Write-Host ("   {0}) " -f $n) -ForegroundColor DarkGray -NoNewline
            Write-Host "$($v.Name)  (coming soon)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host '   Q) Quit' -ForegroundColor DarkGray
    Write-Host ''
}

# Non-interactive entry: the Worker injects $script:NukeTarget from the URL path
# (a canonical vendor Key, or 'all') so a target can be run in one shot, e.g.
#   irm nuke.it2.sh/mcafee | iex     irm nuke.it2.sh/s1 | iex     irm nuke.it2.sh/all | iex
function Invoke-DirectTarget {
    param([Parameter(Mandatory = $true)][string]$Target)

    Show-Banner
    if ($Target -eq 'all') {
        # 'all' runs every consumer AV automatically. EDRs are left out on
        # purpose — they each need a token/passphrase, so run them by name.
        $todo = @($script:Vendors | Where-Object { $_.Ready -and -not $_.Protected })
        Write-Host "  Target : ALL consumer AV — $($todo.Name -join ', ')" -ForegroundColor White
        $edrs = @($script:Vendors | Where-Object { $_.Ready -and $_.Protected })
        if ($edrs.Count -gt 0) {
            Write-Host "  Skipping EDRs ($($edrs.Name -join ', ')) — run each explicitly, e.g. irm nuke.it2.sh/s1 | iex" -ForegroundColor DarkGray
        }
        foreach ($v in $todo) {
            Invoke-Removal -Vendor $v
            Write-Host ''
        }
        Write-Host '  All consumer AV removals complete.' -ForegroundColor Green
        return
    }

    $vendor = $script:Vendors | Where-Object { $_.Key -eq $Target } | Select-Object -First 1
    if (-not $vendor) {
        Write-Bad "Unknown target '$Target'. Valid: $(( $script:Vendors.Key ) -join ', '), all."
        return
    }
    Invoke-Removal -Vendor $vendor
}

function Start-NukeTui {
    if (-not (Assert-Admin)) { return }

    # Direct target from the URL path (nuke.it2.sh/<vendor>) — skip the menu.
    if ($script:NukeTarget) {
        Invoke-DirectTarget -Target $script:NukeTarget
        return
    }

    while ($true) {
        Show-Menu
        $choice = Read-Host '  Choice'
        if ($choice -match '^(q|quit|exit)$') {
            Write-Host '  Bye.' -ForegroundColor Gray
            return
        }
        $n = 0
        if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $script:Vendors.Count) {
            Write-Bad 'Invalid choice.'
            Start-Sleep -Seconds 1
            continue
        }
        $vendor = $script:Vendors[$n - 1]
        if (-not $vendor.Ready) {
            Write-Bad "$($vendor.Name) support isn't ready yet — McAfee first."
            Start-Sleep -Seconds 2
            continue
        }
        Invoke-Removal -Vendor $vendor
        Write-Host ''
        Read-Host '  Press Enter to return to the menu'
    }
}

Start-NukeTui
