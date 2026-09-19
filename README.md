# modular-installer

A single-file PowerShell script with a dark-themed WPF GUI that installs software through
[winget](https://learn.microsoft.com/windows/package-manager/winget/) and keeps the system up to date.
Pick apps from a categorized checklist, click **Install Selected**, and watch winget's output stream live
into an embedded log pane. A **System updates** section updates your apps and Windows in one click.

## Requirements

- Windows 10/11 with `winget` (the "App Installer" package)
- Windows PowerShell 5.1 or PowerShell 7 on Windows
- Administrator rights (the script asks for them itself)

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Software.ps1
```

If the script isn't running as administrator (or isn't in STA mode, which WPF needs), it restarts itself
with a UAC prompt. Run it from a saved `.ps1` file, not pasted into a console, so it can do that.

## System updates

| Button             | What it runs                                                                                  |
| ------------------ | --------------------------------------------------------------------------------------------- |
| **Update Apps**    | `winget upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements` |
| **Windows Update** | Windows and driver updates through the [PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) module: `Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot` |
| **Run All Updates**| Update Apps, then Windows Update                                                              |

- Windows Update asks for confirmation first. If PSWindowsUpdate isn't installed, it is downloaded from the
  PowerShell Gallery (current user scope) on first use.
- A restart is never forced. If updates need one, the log says so; reboot when convenient.
- These use the same background pipeline as installs, so the log streams live and the window stays responsive.
- **Cancel** stops after the current task, so during a single long Windows Update it has no effect until that
  task ends.

### Dry run

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Software.ps1 -DryRun
```

Skips the elevation requirement and simulates winget and Windows Update with fake output, so you can try the
GUI without installing anything. Any app whose id ends in `.Fail` simulates a failed install.

## Adding apps

Edit the `$Apps` table near the top of `Install-Software.ps1`:

```powershell
$Apps = @(
    @{ Category = 'Utilities'; Name = '7-Zip'; WingetId = '7zip.7zip'; PreChecked = $true }
    # ...
)
```

| Field        | Meaning                                                         |
| ------------ | --------------------------------------------------------------- |
| `Category`   | Heading the app is grouped under (order of first appearance)    |
| `Name`       | Label shown in the list                                         |
| `WingetId`   | Exact winget package id (find it with `winget search <name>`)   |
| `PreChecked` | `$true` to have the box ticked when the window opens            |

Ids may only contain letters, digits, `.`, `_`, `+` and `-`; anything else is rejected before it can reach a
command line.

## How it works

- Every action (install, app upgrade, Windows Update) is a small *job* object; the worker runs a list of jobs
  on a separate **Runspace** so the window stays responsive.
- The worker runs each job's command, e.g. `winget install --exact --id <Id> --silent --accept-package-agreements --accept-source-agreements`,
  through `cmd /c ... 2>&1`, merging stdout and stderr, and reads it line by line.
- Lines go onto a thread-safe queue. A `DispatcherTimer` on the UI thread drains the queue into the log,
  so the worker never touches the UI directly.
- Spinner characters and block progress bars are filtered out of the log.
- winget's "already installed" and "already up to date" exit codes count as success.
- **Cancel** skips the remaining apps after the current one finishes; it never kills an installer
  mid-way. Closing the window during an install asks first, then stops the running installer.

## Test apps

The catalog ships with four harmless examples: 7-Zip, Notepad++, Git and Windows Terminal.
