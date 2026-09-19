<img width="1108" height="772" alt="image" src="https://github.com/user-attachments/assets/bdde6a5b-4227-4180-9071-be4fa7ce8ac6" />
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

## Double-click .exe

Build a standalone `ModularInstaller.exe` that you can double-click, pin to the taskbar or copy anywhere:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1
```

The result is `dist\ModularInstaller.exe` (about 50 KB). Nothing is downloaded or installed to build it: the
script uses the C# compiler (`csc.exe`) that ships with Windows.

- **One file:** the script is embedded inside the exe, so it runs without the `.ps1` next to it.
- **Admin:** the exe's manifest requests Administrator rights, so Windows shows the UAC prompt on launch.
- **No console window:** only the installer window appears.
- **Rebuild after edits:** the script is embedded at build time, so run the build again after changing
  `Install-Software.ps1` (for example the `$Apps` catalog).
- **Dry run:** `ModularInstaller.exe -DryRun` simulates winget, like the script's switch. Build with
  `-NoElevate` if you want a test exe that doesn't prompt for admin (`.\Build-Exe.ps1 -NoElevate -OutFile test.exe`).
- **SmartScreen:** the exe is unsigned, so Windows may show "unknown publisher" on the first run. Some antivirus
  products are also wary of unsigned custom executables; building it yourself from this source is the safeguard.
- The exe needs Windows PowerShell 5.1 (built into Windows 10/11).

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
