<#
.SYNOPSIS
    Modular, dark-themed WPF software installer and system updater built on winget.

.DESCRIPTION
    Single-file script. On launch it:
      1. Restarts itself elevated (UAC prompt) and in STA mode if it is not already.
      2. Builds a categorized checkbox list from the $Apps table below.
      3. Installs the selected apps through `winget` on a background Runspace, streaming
         winget's output line by line into an embedded log pane. The UI thread never blocks:
         the worker only enqueues text; a DispatcherTimer on the UI thread drains the queue.
      4. Offers system-update buttons that use the same pipeline: update all apps
         (`winget upgrade --all`), Windows + driver updates (PSWindowsUpdate), or both.

    To add software, add a line to $Apps (Category, Name, WingetId, PreChecked).

.PARAMETER DryRun
    Test mode: skips the elevation requirement and simulates winget with fake output so the
    GUI and streaming can be tried without installing anything.

.EXAMPLE
    .\Install-Software.ps1
    .\Install-Software.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

# ============================================================================================
#  1. APPLICATION CATALOG  -  edit this list to change what the installer offers
# ============================================================================================
$Apps = @(
    @{ Category = 'Runtimes & Frameworks'; Name = 'Visual C++ Runtimes All-In-One'; WingetId = 'abbodi1406.vcredist';                PreChecked = $true  }
    @{ Category = 'Runtimes & Frameworks'; Name = '.NET 8 Desktop Runtime';         WingetId = 'Microsoft.DotNet.DesktopRuntime.8'; PreChecked = $true  }

    @{ Category = 'System Utilities';      Name = '7-Zip';                          WingetId = '7zip.7zip';                         PreChecked = $true  }
    @{ Category = 'System Utilities';      Name = 'Notepad++';                      WingetId = 'Notepad++.Notepad++';               PreChecked = $true  }
    @{ Category = 'System Utilities';      Name = 'Microsoft PowerToys';            WingetId = 'Microsoft.PowerToys';               PreChecked = $false }

    @{ Category = 'Dev & Engineering';     Name = 'Git';                            WingetId = 'Git.Git';                           PreChecked = $true  }
    @{ Category = 'Dev & Engineering';     Name = 'VS Code';                        WingetId = 'Microsoft.VisualStudioCode';        PreChecked = $true  }
    @{ Category = 'Dev & Engineering';     Name = 'Windows Terminal';               WingetId = 'Microsoft.WindowsTerminal';         PreChecked = $false }
    @{ Category = 'Dev & Engineering';     Name = 'Sysinternals Suite';             WingetId = 'Microsoft.Sysinternals.Suite';      PreChecked = $false }

    @{ Category = 'Lab, Virtualization & Network Operations'; Name = 'Oracle VirtualBox'; WingetId = 'Oracle.VirtualBox';     PreChecked = $false }
    @{ Category = 'Lab, Virtualization & Network Operations'; Name = 'Vagrant';           WingetId = 'Hashicorp.Vagrant';     PreChecked = $false }
    @{ Category = 'Lab, Virtualization & Network Operations'; Name = 'Nmap';              WingetId = 'Insecure.Nmap';         PreChecked = $false }
    @{ Category = 'Lab, Virtualization & Network Operations'; Name = 'WinSCP';            WingetId = 'WinSCP.WinSCP';         PreChecked = $false }
    @{ Category = 'Lab, Virtualization & Network Operations'; Name = 'PuTTY';             WingetId = 'PuTTY.PuTTY';           PreChecked = $false }

    @{ Category = 'Hardware Diagnostics & System Monitoring'; Name = 'HWiNFO';            WingetId = 'REALiX.HWiNFO';                   PreChecked = $false }
    @{ Category = 'Hardware Diagnostics & System Monitoring'; Name = 'CrystalDiskInfo';   WingetId = 'CrystalDewWorld.CrystalDiskInfo';  PreChecked = $false }
    @{ Category = 'Hardware Diagnostics & System Monitoring'; Name = 'CPU-Z';             WingetId = 'CPUID.CPU-Z';                     PreChecked = $false }
    @{ Category = 'Hardware Diagnostics & System Monitoring'; Name = 'FurMark';           WingetId = 'Geeks3D.FurMark.2';               PreChecked = $false }

    @{ Category = 'Fabrication & Design (3D CAD & Slicers)';  Name = 'Bambu Studio';      WingetId = 'Bambulab.Bambustudio';  PreChecked = $false }
    @{ Category = 'Fabrication & Design (3D CAD & Slicers)';  Name = 'OrcaSlicer';        WingetId = 'SoftFever.OrcaSlicer';  PreChecked = $false }
    @{ Category = 'Fabrication & Design (3D CAD & Slicers)';  Name = 'FreeCAD';           WingetId = 'FreeCAD.FreeCAD';       PreChecked = $false }

    @{ Category = 'Diverse Daily Productivity';               Name = 'VLC Media Player';  WingetId = 'VideoLAN.VLC';          PreChecked = $false }
    @{ Category = 'Diverse Daily Productivity';               Name = 'ShareX';            WingetId = 'ShareX.ShareX';         PreChecked = $false }
    @{ Category = 'Diverse Daily Productivity';               Name = 'Obsidian';          WingetId = 'Obsidian.Obsidian';     PreChecked = $false }
)

# ============================================================================================
#  2. ENVIRONMENT CHECKS: assemblies, elevation, apartment state
# ============================================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA

# WPF needs an STA thread (Windows PowerShell 5.1 defaults to MTA), and winget installs need admin.
# If either is missing, relaunch this same file with the right settings and exit this instance.
if ((-not $isAdmin -and -not $DryRun) -or -not $isSta) {
    if (-not $PSCommandPath) {
        [void][System.Windows.MessageBox]::Show(
            'Please save this script to a .ps1 file and run it from there, so it can restart itself elevated.',
            'Software Installer', 'OK', 'Warning')
        exit 1
    }

    $relaunch = @{
        FilePath     = (Get-Process -Id $PID).Path          # same host: powershell.exe or pwsh.exe
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                         '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        WindowStyle  = 'Hidden'
    }
    if ($DryRun)                          { $relaunch.ArgumentList += '-DryRun' }
    if (-not $isAdmin -and -not $DryRun)  { $relaunch.Verb = 'RunAs' }     # triggers the UAC prompt

    try {
        Start-Process @relaunch
    }
    catch {
        [void][System.Windows.MessageBox]::Show(
            "Administrator rights are required to install software.`n`n$($_.Exception.Message)",
            'Software Installer', 'OK', 'Warning')
    }
    exit
}

# ============================================================================================
#  2b. STARTUP CHECKS: single instance, catalog validation
# ============================================================================================
# Only one installer may run at a time: two would fight over winget's / Windows Installer's single-install
# lock. A dry run uses its own per-session name so it can never collide with a real (elevated) instance.
$mutexName  = if ($DryRun) { 'Local\ModularInstaller.DryRun' } else { 'Global\ModularInstaller.Main' }
$mutexOwned    = $false
$InstanceMutex = $null
try {
    # Create it unowned, then try to take it without waiting. (Passing initiallyOwned=$true would only grant
    # ownership to whoever creates the object, so any process still holding a handle would wrongly block us.)
    $InstanceMutex = [System.Threading.Mutex]::new($false, $mutexName)
    try   { $mutexOwned = $InstanceMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }   # the previous owner was killed; it is ours now
}
catch { $mutexOwned = $false }       # e.g. access denied on a mutex owned by a higher-integrity process
if (-not $mutexOwned) {
    if ($InstanceMutex) { $InstanceMutex.Dispose() }         # don't keep the name alive while the dialog is open
    [void][System.Windows.MessageBox]::Show('Software Installer is already running.', 'Software Installer', 'OK', 'Information')
    exit 0
}

# winget package ids: letters, digits and . _ + - only, and never a leading "-" (which would read as an option).
$WingetIdPattern = '^[A-Za-z0-9][A-Za-z0-9._+\-]*$'

# Reject a malformed $Apps table up front with a readable message, instead of failing halfway through a run.
function Test-AppCatalog($Catalog) {
    $problems = New-Object System.Collections.Generic.List[string]
    $seenIds  = @{}
    $n = 0
    foreach ($entry in @($Catalog)) {
        $n++
        if ($entry -isnot [System.Collections.IDictionary]) { $problems.Add("Entry $n is not a hashtable."); continue }
        $label = "Entry $n" + $(if ($entry['Name'] -is [string] -and $entry['Name']) { " ($($entry['Name']))" } else { '' })

        foreach ($key in 'Category', 'Name', 'WingetId') {
            $value = $entry[$key]
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { $problems.Add("${label}: '$key' must be a non-empty string.") }
            elseif ($value -match '[\x00-\x1F]')                                 { $problems.Add("${label}: '$key' contains control characters.") }
            elseif ($value.Length -gt 80)                                        { $problems.Add("${label}: '$key' is longer than 80 characters.") }
        }
        if ($entry.Contains('PreChecked') -and $entry['PreChecked'] -isnot [bool]) {
            $problems.Add("${label}: 'PreChecked' must be `$true or `$false.")
        }
        $id = $entry['WingetId']
        if ($id -is [string] -and $id) {
            if ($id -notmatch $WingetIdPattern)     { $problems.Add("${label}: WingetId '$id' has characters winget ids never contain.") }
            elseif ($seenIds.ContainsKey($id.ToLower())) { $problems.Add("${label}: WingetId '$id' is listed twice.") }
            else                                    { $seenIds[$id.ToLower()] = $true }
        }
    }
    $problems.ToArray()
}

$catalogProblems = @(Test-AppCatalog $Apps)
if ($catalogProblems.Count -gt 0) {
    [void][System.Windows.MessageBox]::Show(
        ("The app catalog (`$Apps at the top of the script) has problems:`n`n" + ($catalogProblems -join "`n")),
        'Software Installer', 'OK', 'Error')
    exit 1
}

# ============================================================================================
#  3. BACKGROUND WORKER  -  runs inside its own Runspace, never touches the UI
# ============================================================================================
# Kept as a scriptblock so the parser checks it, then passed to the runspace as text.
# Communication with the UI thread is one-way through two thread-safe objects:
#   $Queue - ConcurrentQueue of { Text, Level } log entries the UI drains
#   $State - synchronized hashtable with progress counters and the Cancel flag
$Worker = {
    param($Jobs, $State, $Queue)

    $MaxLineLength = 2000        # a runaway line must not bloat the log or the queue

    function Send-Log([string]$Text, [string]$Level = 'info') {
        if ($Text.Length -gt $MaxLineLength) { $Text = $Text.Substring(0, $MaxLineLength) + ' ...(line truncated)' }
        $Queue.Enqueue([pscustomobject]@{ Text = $Text; Level = $Level })
    }
    function Get-Stamp { (Get-Date).ToString('HH:mm:ss') }

    # winget draws spinners ("- \ | /") and block progress bars with carriage returns. When read
    # line by line that becomes hundreds of junk lines, so drop them.
    # (Block characters are built from code points to keep this file pure ASCII, which Windows PowerShell 5.1 needs.)
    $blocks = -join ([char[]](0x2588, 0x2593, 0x2592, 0x2591))
    # Also drop the CLIXML progress envelope a child powershell.exe can emit when its output is redirected.
    $noise  = [regex]('^\s*$|^\s*[-\\|/]\s*$|[' + $blocks + ']|^\s*\d+(\.\d+)?\s*[KMG]?i?B\s*/\s*\d+(\.\d+)?\s*[KMG]?i?B\s*$|^#< CLIXML|^<Objs ')

    $total = @($Jobs).Count
    $index = 0

    try {
        foreach ($job in $Jobs) {
            $index++

            if ($State.Cancel) {
                Send-Log ("[{0}] Skipped {1} (cancelled)" -f (Get-Stamp), $job.Name) 'warn'
                $State.Skipped++
                continue
            }

            $State.Current = "$($job.Action) $($job.Name) ($index of $total)"
            Send-Log '' 'info'
            Send-Log ("[{0}] ({1}/{2}) {3} {4}" -f (Get-Stamp), $index, $total, $job.Action, $job.Name) 'head'

            # A job without a program was rejected while it was being built (see the New-*Job functions).
            if (-not $job.FileName) {
                Send-Log $job.Error 'err'
                $State.Failed++; $State.Completed++
                continue
            }
            Send-Log "> $($job.Display)" 'cmd'

            $exit = $null
            $proc = $null
            try {
                # The program is started directly (no cmd.exe, no shell parsing). stdout and stderr are read
                # concurrently, each line as it arrives, so nothing waits behind the other stream.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName               = $job.FileName
                $psi.Arguments              = $job.Arguments
                $psi.UseShellExecute        = $false
                $psi.CreateNoWindow         = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.RedirectStandardInput  = $true      # closed right away so the program can never wait on a prompt
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                [void]$proc.Start()
                $State.Process = $proc                   # lets the UI stop it (force-stop, window close)
                $proc.StandardInput.Close()

                $streams = @(
                    @{ Reader = $proc.StandardOutput; Task = $proc.StandardOutput.ReadLineAsync() },
                    @{ Reader = $proc.StandardError;  Task = $proc.StandardError.ReadLineAsync()  }
                )
                $last = $null
                while ($streams.Count -gt 0) {
                    $ready = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($streams | ForEach-Object { $_.Task }))
                    $stream = $streams[$ready]
                    $line   = $stream.Task.Result
                    if ($null -eq $line) {               # this stream reached end-of-file
                        $streams = @($streams | Where-Object { $_ -ne $stream })
                        continue
                    }
                    $stream.Task = $stream.Reader.ReadLineAsync()

                    if ($noise.IsMatch($line)) { continue }
                    $text = $line.TrimEnd()
                    if ($text -eq $last) { continue }    # collapse repeated status lines
                    $last = $text

                    $level = 'info'
                    if     ($text -match '(?i)\b(error|failed|failure)\b')                    { $level = 'err'  }
                    elseif ($text -match '(?i)\b(warning|already installed|no newer)\b')      { $level = 'warn' }
                    elseif ($text -match '(?i)^\s*(successfully|installation completed)')     { $level = 'ok'   }
                    Send-Log $text $level
                }

                $proc.WaitForExit()
                $exit = $proc.ExitCode
            }
            catch {
                Send-Log "Could not run installer: $($_.Exception.Message)" 'err'
            }
            finally {
                # Never leave the program running if this loop is abandoned by an error.
                $State.Process = $null
                if ($proc) {
                    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
                    $proc.Dispose()
                }
            }

            # winget exit codes: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
            $stamp = Get-Stamp
            switch ($exit) {
                0            { Send-Log "[$stamp] OK: $($job.Name) $($job.Past)."                            'ok';   $State.Succeeded++ }
                -1978335135  { Send-Log "[$stamp] OK: $($job.Name) - already installed."                     'ok';   $State.Succeeded++ }
                -1978335189  { Send-Log "[$stamp] OK: $($job.Name) - no applicable updates."                 'ok';   $State.Succeeded++ }
                3010         { Send-Log "[$stamp] OK: $($job.Name) $($job.Past). A restart is required."     'warn'; $State.Succeeded++ }
                -1978335215  {
                    Send-Log "[$stamp] FAILED: $($job.Name) (exit code $exit, installer hash mismatch)."      'err';  $State.Failed++
                    Send-Log 'winget blocked this on purpose: the downloaded file no longer matches the checksum in the package manifest (the publisher replaced the file). Try again after the manifest is updated.' 'warn'
                }
                default      {
                    $why = if ($null -eq $exit) { 'the program did not run' } else { "exit code $exit" }
                    Send-Log "[$stamp] FAILED: $($job.Name) ($why)."                                          'err';  $State.Failed++
                }
            }
            $State.Completed++
        }
    }
    catch {
        Send-Log "Unexpected error: $($_.Exception.Message)" 'err'
    }
    finally {
        $State.Summary = "Finished: $($State.Succeeded) succeeded, $($State.Failed) failed, $($State.Skipped) skipped"
        Send-Log '' 'info'
        Send-Log ("[{0}] {1}" -f (Get-Stamp), $State.Summary) 'head'
    }
}

# ============================================================================================
#  3b. JOB DEFINITIONS  -  what the worker can run
# ============================================================================================
# A job is a plain object: Name/Action/Past build the log wording ("Updating <Name>" ... "<Name> <Past>"),
# Display is the command shown in the log, and FileName + Arguments are what the worker starts. Programs are
# always given by full path (never looked up on PATH at run time). FileName stays empty, with Error set, when
# a job was rejected. In -DryRun mode the program is a harmless cmd.exe fake.
$SystemDir  = [Environment]::SystemDirectory                 # C:\Windows\System32
$FakeDelay  = 'ping -n 2 127.0.0.1 >nul'                     # cmd has no sleep; a 2-ping run is a ~1 second pause
$script:WingetPath = $null

function New-Job([string]$Name, [string]$Action, [string]$Past, [string]$Display, [bool]$NeedsWinget) {
    [pscustomobject]@{ Name = $Name; Action = $Action; Past = $Past; Display = $Display
                       FileName = ''; Arguments = ''; Error = $null; NeedsWinget = $NeedsWinget }
}

# winget is an app-execution alias, so it can't be signature-checked; use the fixed per-user alias location
# and only fall back to a PATH lookup if it is missing. The result is resolved once, then reused.
function Get-WingetPath {
    if (-not $script:WingetPath) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) { $script:WingetPath = $alias }
        else {
            $found = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $script:WingetPath = $found.Source }
        }
    }
    $script:WingetPath
}

# Point a job at winget (real mode) or at a fake (dry run).
function Set-WingetCommand($Job, [string]$WingetArgs, [string]$FakeCommandLine) {
    if ($DryRun) {
        $Job.FileName  = Join-Path $SystemDir 'cmd.exe'
        $Job.Arguments = "/d /c $FakeCommandLine"
        return
    }
    $path = Get-WingetPath
    if ($path) { $Job.FileName = $path; $Job.Arguments = $WingetArgs }
    else       { $Job.Error = 'winget was not found. Install "App Installer" from the Microsoft Store and try again.' }
}

# Install one catalog app: winget install --exact --id <Id> ...
function New-InstallJob($App) {
    $wingetArgs = "install --exact --id $($App.Id) --silent --accept-package-agreements --accept-source-agreements"
    $job = New-Job $App.Name 'Installing' 'installed' "winget $wingetArgs" $true

    # The id is part of the argument string, so accept only characters valid in winget ids.
    if ($App.Id -notmatch $WingetIdPattern) {
        $job.Error = "Invalid winget id '$($App.Id)'. Skipping."
        return $job
    }

    # Fake winget: a few lines with a spinner, a stderr line and delays. Ids ending in ".Fail" simulate an error.
    # The display name is reduced to safe characters because the fake goes through cmd.exe.
    $safeName = $App.Name -replace '[^A-Za-z0-9 .+\-]', '_'
    $fake = "echo Found $safeName [$($App.Id)] Version 1.0.0 & $FakeDelay" +
            " & echo Downloading https://example.invalid/$($App.Id) & echo   - & $FakeDelay & echo   \" +
            " & echo Note: simulated stderr line 1>&2 & echo Successfully verified installer hash" +
            " & echo Starting package install... & $FakeDelay"
    if ($App.Id -like '*.Fail') { $fake += ' & echo Simulated failure & exit /b 1' }
    else                        { $fake += ' & echo Successfully installed' }

    Set-WingetCommand $job $wingetArgs $fake
    $job
}

# Upgrade every installed package winget knows about (including ones with an unknown version).
function New-WingetUpgradeJob {
    $wingetArgs = 'upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements'
    $job = New-Job 'installed applications' 'Updating' 'updated' "winget $wingetArgs" $true

    $fake = "echo Name Id Version Available & echo Fake App Fake.App 1.0 2.0 & $FakeDelay" +
            " & echo Found Fake App [Fake.App] Version 2.0 & echo Downloading https://example.invalid/Fake.App & $FakeDelay" +
            " & echo Successfully installed & echo 1 package updated"

    Set-WingetCommand $job $wingetArgs $fake
    $job
}

# Windows Update + driver patches through the PSWindowsUpdate module. Restarts are never forced: the job only
# reports that one is pending.
function New-WindowsUpdateJob {
    $job = New-Job 'Windows Update' 'Running' 'finished' `
        'powershell Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot   (PSWindowsUpdate module)' $false

    if ($DryRun) {
        $job.FileName  = Join-Path $SystemDir 'cmd.exe'
        $job.Arguments = "/d /c echo [+] Checking for Windows and driver updates & $FakeDelay" +
                         " & echo   Downloaded  KB5000001  120 MB  Fake Cumulative Update & $FakeDelay" +
                         " & echo   Installed   KB5000001  120 MB  Fake Cumulative Update & $FakeDelay" +
                         " & echo WARNING: A restart is required to finish some updates. Reboot when convenient."
        return $job
    }

    # Runs in a child Windows PowerShell 5.1 (PSWindowsUpdate targets it), passed as -EncodedCommand so no quoting
    # can go wrong, with $ProgressPreference silenced so no progress records pollute the pipe.
    #
    # Supply-chain guard: the child runs elevated, so it only loads module code that an unprivileged process
    # can't have tampered with. The module must live under Program Files (admin-writable only), it is installed
    # there for all users if missing, and every code file must carry a valid signature from the module author.
    # The marker line below splits the helper functions from the main logic (the build/tests rely on it).
    $child = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-TrustedModule([string]$Root = $env:ProgramFiles) {
    Get-Module -ListAvailable -Name PSWindowsUpdate |
        Where-Object { $_.ModuleBase.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Version -Descending | Select-Object -First 1
}

# Returns one entry per code file that is unsigned, tampered with, or signed by someone other than the author.
function Test-ModuleSignatures([string]$Base, [string]$Signer = 'Michal Gajda') {
    @(Get-ChildItem -LiteralPath $Base -Recurse -File |
        Where-Object { $_.Extension -in '.psd1', '.psm1', '.ps1', '.ps1xml', '.dll', '.exe' } |
        ForEach-Object {
            $sig = Get-AuthenticodeSignature -LiteralPath $_.FullName
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*$Signer*") { '{0} ({1})' -f $_.Name, $sig.Status }
        })
}
# ---- main ----
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $module = Get-TrustedModule
    if (-not $module) {
        Write-Host '[+] Installing PSWindowsUpdate for all users (Program Files) from the PowerShell Gallery...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers
        $module = Get-TrustedModule
    }
    if (-not $module) { throw 'PSWindowsUpdate was not found under Program Files.' }

    $problems = Test-ModuleSignatures $module.ModuleBase
    if ($problems.Count -gt 0) { throw ('PSWindowsUpdate failed the signature check and was NOT loaded: ' + ($problems -join ', ')) }
    Write-Host ('[+] PSWindowsUpdate {0} verified (valid signature from the module author).' -f $module.Version)

    Import-Module -Name (Join-Path $module.ModuleBase 'PSWindowsUpdate.psd1') -Force
    Write-Host '[+] Checking for Windows and driver updates (this can take several minutes)...'
    $count = 0
    Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot | ForEach-Object {
        $count++
        $state = if ($_.Result) { $_.Result } else { $_.Status }
        Write-Host ('  {0,-11} {1,-10} {2,-9} {3}' -f $state, $_.KB, $_.Size, $_.Title)
    }
    if ($count -eq 0) { Write-Host 'No Windows or driver updates are available.' }
    if (Get-WURebootStatus -Silent) { Write-Host 'WARNING: A restart is required to finish some updates. Reboot when convenient.' }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
'@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
    $job.FileName  = Join-Path $SystemDir 'WindowsPowerShell\v1.0\powershell.exe'
    $job.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded"
    $job
}

# ============================================================================================
#  4. XAML  -  dark theme, custom control templates, layout
# ============================================================================================
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Software Installer" Width="1140" Height="830" MinWidth="860" MinHeight="600"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" UseLayoutRounding="True"
        Background="#18181C">
    <Window.Resources>
        <!-- Palette -->
        <SolidColorBrush x:Key="BgBrush"      Color="#18181C"/>
        <SolidColorBrush x:Key="PanelBrush"   Color="#222228"/>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#2C2C35"/>
        <SolidColorBrush x:Key="BorderBrush"  Color="#383843"/>
        <SolidColorBrush x:Key="TextBrush"    Color="#E8E8EC"/>
        <SolidColorBrush x:Key="MutedBrush"   Color="#9797A5"/>
        <SolidColorBrush x:Key="AccentBrush"  Color="#3B82F6"/>
        <SolidColorBrush x:Key="LogBgBrush"   Color="#0F0F12"/>

        <!-- Scrollbar: thin, rounded, dark -->
        <Style x:Key="ScrollRepeat" TargetType="RepeatButton">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="IsTabStop" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="T" Background="#4A4A56" CornerRadius="4" Margin="2,0"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="#6A6A78"/></Trigger>
                            <Trigger Property="IsDragging"  Value="True"><Setter TargetName="T" Property="Background" Value="#8A8A98"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="12"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollRepeat}"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollRepeat}"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Buttons: rounded, hover/press overlay so one template serves every color variant -->
        <Style x:Key="BaseButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>
                            <Border x:Name="Overlay" Background="White" Opacity="0" CornerRadius="6" IsHitTestVisible="False"/>
                            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Overlay" Property="Opacity" Value="0.08"/></Trigger>
                            <Trigger Property="IsPressed"   Value="True"><Setter TargetName="Overlay" Property="Opacity" Value="0.16"/></Trigger>
                            <Trigger Property="IsEnabled"   Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" BasedOn="{StaticResource BaseButton}"/>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="14,11"/>
        </Style>

        <!-- Checkbox: rounded box with a drawn check mark, highlighted row on hover -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="Row" Background="Transparent" CornerRadius="6" Padding="8,7">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" VerticalAlignment="Center"
                                        Background="{StaticResource SurfaceBrush}" BorderBrush="#5A5A68" BorderThickness="1.5">
                                    <Path x:Name="Check" Data="M3,7.5 L6,10.5 L12,4.5" Stroke="White" StrokeThickness="2"
                                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                          Visibility="Collapsed"/>
                                </Border>
                                <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="#2C2C35"/></Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box"   Property="Background"  Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Box"   Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Check" Property="Visibility"  Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Progress bar: slim rounded track -->
        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="6"/>
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border x:Name="PART_Track" CornerRadius="3" Background="{TemplateBinding Background}"/>
                            <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="400" MinWidth="320"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- LEFT: app selection -->
        <Border Grid.Column="0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush}"
                BorderThickness="1" CornerRadius="10">
            <Grid Margin="16">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0" Margin="0,0,0,12">
                    <TextBlock Text="Software Installer" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
                    <TextBlock Text="Pick the apps to install with winget" FontSize="12.5" Margin="0,3,0,0" Foreground="{StaticResource MutedBrush}"/>
                </StackPanel>

                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <StackPanel x:Name="AppList" Margin="0,0,6,0"/>
                </ScrollViewer>

                <StackPanel Grid.Row="2" Margin="0,14,0,0">
                    <TextBlock x:Name="SelCount" FontSize="12" Margin="2,0,0,8" Foreground="{StaticResource MutedBrush}"/>
                    <Grid Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BtnSelectAll"   Grid.Column="0" Content="Select All"/>
                        <Button x:Name="BtnDeselectAll" Grid.Column="2" Content="Deselect All"/>
                    </Grid>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BtnInstall" Grid.Column="0" Content="Install Selected" Style="{StaticResource AccentButton}"/>
                        <Button x:Name="BtnCancel"  Grid.Column="1" Content="Cancel" Margin="8,0,0,0" Padding="16,11" Visibility="Collapsed"
                                ToolTip="Skip the remaining tasks after the current one finishes"/>
                    </Grid>

                    <Border Height="1" Background="{StaticResource BorderBrush}" Margin="0,16,0,14"/>
                    <TextBlock Text="SYSTEM UPDATES" FontSize="11.5" FontWeight="SemiBold" Margin="2,0,0,8"
                               Foreground="{StaticResource MutedBrush}"/>
                    <Grid Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Button x:Name="BtnUpdateApps" Grid.Column="0" Content="Update Apps"
                                ToolTip="winget upgrade --all: update every installed application"/>
                        <Button x:Name="BtnUpdateWin"  Grid.Column="2" Content="Windows Update"
                                ToolTip="Install Windows and driver updates (PSWindowsUpdate). Never forces a restart."/>
                    </Grid>
                    <Button x:Name="BtnUpdateAll" Content="Run All Updates"
                            ToolTip="Update apps, then Windows and drivers"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- RIGHT: embedded terminal log + progress -->
        <Border Grid.Column="2" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush}"
                BorderThickness="1" CornerRadius="10">
            <Grid Margin="16">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,10">
                    <TextBlock Text="Installation log" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"
                               Foreground="{StaticResource TextBrush}"/>
                    <Button x:Name="BtnClear" Content="Clear" HorizontalAlignment="Right" Padding="12,5" FontSize="12"/>
                </Grid>

                <Border Grid.Row="1" Background="{StaticResource LogBgBrush}" BorderBrush="{StaticResource BorderBrush}"
                        BorderThickness="1" CornerRadius="8">
                    <RichTextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                                 Foreground="#D4D4D4" FontFamily="Cascadia Mono, Consolas" FontSize="12.5" Padding="10"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
                </Border>

                <StackPanel Grid.Row="2" Margin="0,12,0,0">
                    <TextBlock x:Name="StatusText" Text="Ready" FontSize="12.5" Margin="0,0,0,7" Foreground="{StaticResource MutedBrush}"/>
                    <ProgressBar x:Name="Progress" Minimum="0" Maximum="1" Value="0"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

# ============================================================================================
#  5. UI THREAD: build window, wire events
# ============================================================================================
try {
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$Xaml)))

    $AppList      = $Window.FindName('AppList')
    $SelCount     = $Window.FindName('SelCount')
    $BtnSelectAll = $Window.FindName('BtnSelectAll')
    $BtnDeselect  = $Window.FindName('BtnDeselectAll')
    $BtnInstall   = $Window.FindName('BtnInstall')
    $BtnCancel    = $Window.FindName('BtnCancel')
    $BtnClear     = $Window.FindName('BtnClear')
    $BtnUpdateApps = $Window.FindName('BtnUpdateApps')
    $BtnUpdateWin  = $Window.FindName('BtnUpdateWin')
    $BtnUpdateAll  = $Window.FindName('BtnUpdateAll')
    $LogBox       = $Window.FindName('LogBox')
    $StatusText   = $Window.FindName('StatusText')
    $Progress     = $Window.FindName('Progress')

    $TextBrush  = $Window.FindResource('TextBrush')
    $MutedBrush = $Window.FindResource('MutedBrush')

    # Don't open taller than the screen's usable area (small laptop displays).
    $Window.Height = [Math]::Min($Window.Height, [System.Windows.SystemParameters]::WorkArea.Height - 16)

    $Window.Title = 'Software Installer' + $(if ($isAdmin) { ' (Administrator)' } elseif ($DryRun) { ' (dry run)' } else { '' })

    # Dark title bar on Windows 10 20H1+/11. Purely cosmetic, so any failure here (older Windows, or security
    # software blocking the runtime compile behind Add-Type) is ignored instead of stopping the app.
    try {
        Add-Type -Namespace Win32 -Name Dwm -ErrorAction Stop -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
        $Window.Add_SourceInitialized({
            try {
                $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
                $dark = 1
                [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
            } catch { }
        })
    } catch { }

    # ---- Log pane ------------------------------------------------------------------------
    $LogBrushes = @{}
    foreach ($entry in @{ info = '#D4D4D4'; head = '#FFFFFF'; cmd = '#6CB6FF'; ok = '#5FD38D'; warn = '#E5C07B'; err = '#F47067' }.GetEnumerator()) {
        $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($entry.Value)
        $brush.Freeze()
        $LogBrushes[$entry.Key] = $brush
    }

    $LogPara = [System.Windows.Documents.Paragraph]::new()
    $LogPara.Margin = [System.Windows.Thickness]::new(0)
    $LogBox.Document.Blocks.Clear()
    $LogBox.Document.Blocks.Add($LogPara)

    function Add-LogLine([string]$Text, [string]$Level = 'info') {
        $run = [System.Windows.Documents.Run]::new($Text)
        $run.Foreground = $LogBrushes[$Level]
        if ($Level -eq 'head') { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
        $LogPara.Inlines.Add($run)
        $LogPara.Inlines.Add([System.Windows.Documents.LineBreak]::new())
    }

    # Thread-safe hand-off: the worker enqueues, the UI thread dequeues in batches.
    $Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    # The UI thread must never fall behind a chatty program. Each tick therefore has a hard time budget, and if
    # the backlog grows past $MaxBacklog the oldest waiting lines are dropped (with a note in the log).
    $MaxBacklog  = 3000
    $TickBudgetMs = 30

    function Sync-LogQueue {
        # Only auto-scroll if the user hasn't scrolled up to read something.
        $atBottom = ($LogBox.VerticalOffset + $LogBox.ViewportHeight) -ge ($LogBox.ExtentHeight - 24)
        $item = $null; $added = $false

        if ($Queue.Count -gt $MaxBacklog) {
            $dropped = 0
            $excess  = $Queue.Count - 1000
            for ($i = 0; $i -lt $excess; $i++) { if ($Queue.TryDequeue([ref]$item)) { $dropped++ } }
            Add-LogLine "[log] $dropped lines skipped to keep the window responsive." 'warn'
            $added = $true
        }

        $budget = [System.Diagnostics.Stopwatch]::StartNew()
        while ($budget.ElapsedMilliseconds -lt $TickBudgetMs -and $Queue.TryDequeue([ref]$item)) {
            Add-LogLine $item.Text $item.Level
            $added = $true
        }

        if ($added) {
            # Cap the document so very long sessions stay fast (inlines come in Run + LineBreak pairs).
            while ($LogPara.Inlines.Count -gt 8000) {
                1..1000 | ForEach-Object { [void]$LogPara.Inlines.Remove($LogPara.Inlines.FirstInline) }
            }
            if ($atBottom) { $LogBox.ScrollToEnd() }
        }
    }

    # ---- App list ------------------------------------------------------------------------
    $Checkboxes = New-Object 'System.Collections.Generic.List[System.Windows.Controls.CheckBox]'
    $Running    = $false

    function Update-SelectionCount {
        $n = @($Checkboxes | Where-Object { $_.IsChecked }).Count
        $SelCount.Text = "$n of $($Checkboxes.Count) selected"
        $BtnInstall.IsEnabled = ($n -gt 0) -and (-not $Running)
    }

    # Group by Category, keeping the order in which categories first appear in $Apps.
    $firstGroup = $true
    foreach ($group in ($Apps | Group-Object -Property { $_.Category })) {
        $header = [System.Windows.Controls.TextBlock]::new()
        $header.Text       = $group.Name.ToUpper()
        $header.FontSize   = 11.5
        $header.FontWeight = [System.Windows.FontWeights]::SemiBold
        $header.Foreground = $MutedBrush
        $header.Margin     = [System.Windows.Thickness]::new(8, $(if ($firstGroup) { 0 } else { 16 }), 0, 4)
        [void]$AppList.Children.Add($header)
        $firstGroup = $false

        foreach ($app in $group.Group) {
            # Label = name (auto width) + winget id (takes the remaining width, ellipsized when it doesn't fit).
            $label = [System.Windows.Controls.Grid]::new()
            $colName = [System.Windows.Controls.ColumnDefinition]::new()
            $colName.Width = [System.Windows.GridLength]::Auto
            $colId = [System.Windows.Controls.ColumnDefinition]::new()
            $colId.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $label.ColumnDefinitions.Add($colName)
            $label.ColumnDefinitions.Add($colId)

            $name = [System.Windows.Controls.TextBlock]::new()
            $name.Text = $app.Name
            $name.FontSize = 13.5
            $name.Foreground = $TextBrush
            [void]$label.Children.Add($name)

            $id = [System.Windows.Controls.TextBlock]::new()
            $id.Text = $app.WingetId
            $id.FontSize = 11
            $id.Foreground = $MutedBrush
            $id.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $id.Margin = [System.Windows.Thickness]::new(8, 2, 0, 0)
            $id.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($id, 1)
            [void]$label.Children.Add($id)

            $cb = [System.Windows.Controls.CheckBox]::new()
            $cb.ToolTip   = $app.WingetId
            $cb.Content   = $label
            $cb.IsChecked = [bool]$app.PreChecked
            $cb.Tag       = [pscustomobject]@{ Name = $app.Name; Id = $app.WingetId }
            $cb.Add_Checked({ Update-SelectionCount })
            $cb.Add_Unchecked({ Update-SelectionCount })
            $Checkboxes.Add($cb)
            [void]$AppList.Children.Add($cb)
        }
    }
    Update-SelectionCount

    # ---- Run state -----------------------------------------------------------------------
    $State = $null; $Rs = $null; $Ps = $null; $Async = $null

    function Set-UiRunning([bool]$IsRunning) {
        $script:Running = $IsRunning
        $AppList.IsEnabled      = -not $IsRunning
        $BtnSelectAll.IsEnabled = -not $IsRunning
        $BtnDeselect.IsEnabled  = -not $IsRunning
        foreach ($b in $BtnUpdateApps, $BtnUpdateWin, $BtnUpdateAll) { $b.IsEnabled = -not $IsRunning }
        $BtnCancel.Visibility   = if ($IsRunning) { 'Visible' } else { 'Collapsed' }
        $BtnCancel.IsEnabled    = $true
        $BtnCancel.Content      = 'Cancel'
        $BtnCancel.ToolTip      = 'Skip the remaining tasks after the current one finishes'
        Update-SelectionCount
    }

    # Kills the running program and everything it spawned (/T). Uses the system taskkill by full path.
    function Stop-InstallerProcess {
        $p = $State.Process
        if ($p) {
            try {
                Start-Process -FilePath (Join-Path $SystemDir 'taskkill.exe') -ArgumentList "/PID $($p.Id) /T /F" -WindowStyle Hidden -Wait
            } catch { }
        }
    }

    # Runs a list of jobs (see section 3b) on the background runspace, one after another.
    function Start-JobQueue($Jobs) {
        $Jobs = @($Jobs)
        if ($Jobs.Count -eq 0) { return }

        if (-not $DryRun -and @($Jobs | Where-Object { $_.NeedsWinget }).Count -gt 0 -and -not (Get-WingetPath)) {
            Add-LogLine 'winget was not found. Install "App Installer" from the Microsoft Store and try again.' 'err'
            return
        }

        $script:State = [hashtable]::Synchronized(@{
            Cancel = $false; Total = $Jobs.Count; Completed = 0
            Succeeded = 0; Failed = 0; Skipped = 0
            Current = 'Starting...'; Summary = ''; Process = $null
        })

        # A dedicated runspace = a separate thread. The UI thread only starts it and polls it.
        try {
            $script:Rs = [runspacefactory]::CreateRunspace()
            $script:Rs.ApartmentState = 'MTA'
            $script:Rs.ThreadOptions  = 'ReuseThread'
            $script:Rs.Open()

            $script:Ps = [powershell]::Create()
            $script:Ps.Runspace = $script:Rs
            [void]$script:Ps.AddScript($Worker.ToString()).
                AddArgument($Jobs).AddArgument($script:State).AddArgument($Queue)

            $Progress.Maximum = $Jobs.Count
            $Progress.Value   = 0
            Set-UiRunning $true
            $Timer.Start()
            $script:Async = $script:Ps.BeginInvoke()      # returns immediately; the window stays responsive
        }
        catch {
            # Don't leak a half-built runspace if starting failed.
            $Timer.Stop()
            if ($script:Ps) { $script:Ps.Dispose() }
            if ($script:Rs) { $script:Rs.Dispose() }
            throw
        }
    }

    function Complete-Install {
        $Timer.Stop()
        try { $Ps.EndInvoke($Async) } catch { Add-LogLine "Worker error: $($_.Exception.Message)" 'err' }
        foreach ($err in $Ps.Streams.Error) { Add-LogLine "Worker error: $err" 'err' }
        $Ps.Dispose(); $Rs.Close(); $Rs.Dispose()
        $Progress.Value = $State.Total
        $StatusText.Text = $State.Summary
        Set-UiRunning $false
    }

    # Polls ~10x/second on the UI thread: flush log lines, update the progress bar, detect completion.
    $Timer = [System.Windows.Threading.DispatcherTimer]::new()
    $Timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $Timer.Add_Tick({
        # An error in one tick must not leave the UI stuck in the "running" state.
        try {
            $finished = $Async.IsCompleted          # read BEFORE draining so no trailing lines are lost
            Sync-LogQueue
            $Progress.Value  = $State.Completed
            $StatusText.Text = $State.Current
            if ($finished) { Complete-Install }
        }
        catch {
            Add-LogLine "Internal error while updating the log: $($_.Exception.Message)" 'err'
            if ($Async -and $Async.IsCompleted) { $Timer.Stop(); Set-UiRunning $false }
        }
    })

    # ---- Buttons -------------------------------------------------------------------------
    $BtnSelectAll.Add_Click({ foreach ($c in $Checkboxes) { $c.IsChecked = $true } })
    $BtnDeselect.Add_Click({  foreach ($c in $Checkboxes) { $c.IsChecked = $false } })
    $BtnClear.Add_Click({     $LogPara.Inlines.Clear() })
    $BtnInstall.Add_Click({
        try {
            Start-JobQueue @($Checkboxes | Where-Object { $_.IsChecked } | ForEach-Object { New-InstallJob $_.Tag })
        }
        catch { Add-LogLine "Could not start: $($_.Exception.Message)" 'err'; Set-UiRunning $false }
    })

    # Windows Update changes the whole system, so ask first (skipped in -DryRun).
    function Confirm-WindowsUpdate {
        if ($DryRun) { return $true }
        $answer = [System.Windows.MessageBox]::Show($Window,
            "This installs all available Windows and driver updates. It uses the PSWindowsUpdate module: if it is not installed under Program Files, it is downloaded for all users from the PowerShell Gallery, and its digital signature is verified before anything is loaded. A restart is never forced.`n`nContinue?",
            'Windows Update', 'YesNo', 'Question')
        $answer -eq 'Yes'
    }

    $BtnUpdateApps.Add_Click({
        try { Start-JobQueue @(New-WingetUpgradeJob) }
        catch { Add-LogLine "Could not start: $($_.Exception.Message)" 'err'; Set-UiRunning $false }
    })
    $BtnUpdateWin.Add_Click({
        try { if (Confirm-WindowsUpdate) { Start-JobQueue @(New-WindowsUpdateJob) } }
        catch { Add-LogLine "Could not start: $($_.Exception.Message)" 'err'; Set-UiRunning $false }
    })
    $BtnUpdateAll.Add_Click({
        try { if (Confirm-WindowsUpdate) { Start-JobQueue @((New-WingetUpgradeJob), (New-WindowsUpdateJob)) } }
        catch { Add-LogLine "Could not start: $($_.Exception.Message)" 'err'; Set-UiRunning $false }
    })

    # Two-step cancel: the first click skips the remaining tasks (the current one finishes normally); the button
    # then becomes "Stop now", which force-stops a hung installer after a confirmation.
    $BtnCancel.Add_Click({
        if (-not $State.Cancel) {
            $State.Cancel = $true
            $BtnCancel.Content = 'Stop now'
            $BtnCancel.ToolTip = 'Force-stop the running installer (may leave software partly installed)'
            Add-LogLine 'Cancel requested. The current task will finish; remaining tasks are skipped. Use "Stop now" to force-stop a hung installer.' 'warn'
            return
        }
        $answer = [System.Windows.MessageBox]::Show($Window,
            "Force-stop the running installer now?`n`nStopping an installer part-way can leave software partly installed.",
            'Stop now', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') {
            Add-LogLine 'Force-stopping the running installer...' 'warn'
            Stop-InstallerProcess
        }
    })

    $Window.Add_Closing({
        param($sender, $e)
        if ($Running) {
            $answer = [System.Windows.MessageBox]::Show($Window,
                "An installation is still running. Closing now will stop the installer that is currently running.`n`nExit anyway?",
                'Installation in progress', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
            $State.Cancel = $true
            Stop-InstallerProcess
        }
        $Timer.Stop()
    })

    # ---- Go ------------------------------------------------------------------------------
    $mode = if ($DryRun) { 'DRY RUN - winget is simulated, nothing will be installed.' }
            else         { 'Running elevated. Select apps and click "Install Selected".' }
    Add-LogLine $mode 'info'
    if (-not $DryRun -and -not (Get-WingetPath)) {
        Add-LogLine 'Warning: winget.exe was not found on this system.' 'warn'
    }

    [void]$Window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Unexpected error:`n`n$($_ | Out-String)", 'Software Installer', 'OK', 'Error')
    exit 1
}
