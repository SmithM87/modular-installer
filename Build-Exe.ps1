<#
.SYNOPSIS
    Builds a double-clickable ModularInstaller.exe that embeds Install-Software.ps1.

.DESCRIPTION
    Uses only what ships with Windows: the .NET Framework C# compiler (csc.exe) and the Windows PowerShell
    engine assembly. Nothing is downloaded or installed. The exe asks for Administrator rights through its
    manifest, hosts the embedded script in-process on an STA thread, and shows no console window.

    The script is embedded at build time, so re-run this after editing Install-Software.ps1
    (for example after changing the $Apps catalog).

.PARAMETER OutFile
    Where to write the exe. Default: dist\ModularInstaller.exe next to this script.

.PARAMETER NoElevate
    Build a variant that does not request Administrator rights. Only useful for testing with -DryRun.

.EXAMPLE
    .\Build-Exe.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

# ($PSScriptRoot is not reliably available inside param() defaults on Windows PowerShell 5.1.)
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'dist\ModularInstaller.exe' }

$scriptFile   = Join-Path $PSScriptRoot 'Install-Software.ps1'
$launcherFile = Join-Path $PSScriptRoot 'build\Launcher.cs'
$manifestFile = Join-Path $PSScriptRoot 'build\app.manifest'

foreach ($f in $scriptFile, $launcherFile, $manifestFile) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f" }
}

# --- Refuse to embed a broken script: an exe with a syntax error only fails after it has been shipped -------
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $detail = ($parseErrors | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
    throw "Install-Software.ps1 has $($parseErrors.Count) syntax error(s); nothing was built.`n$detail"
}
# Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so any non-ASCII character would corrupt the plain-script path.
$nonAscii = [regex]::Matches([System.IO.File]::ReadAllText($scriptFile), '[^\x00-\x7F]')
if ($nonAscii.Count -gt 0) { throw "Install-Software.ps1 contains $($nonAscii.Count) non-ASCII character(s); keep it pure ASCII (use [char] code points)." }

# --- Locate the compiler and the PowerShell engine assembly ----------------------------------
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4.x compiler) was not found on this system.' }

$sma = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') `
           -Recurse -Filter System.Management.Automation.dll -ErrorAction SilentlyContinue |
       Select-Object -First 1 -ExpandProperty FullName
if (-not $sma) { throw 'Windows PowerShell 5.1 (System.Management.Automation.dll) was not found in the GAC.' }

# --- Work area: generated icon and (optionally) a non-elevating manifest ---------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ('modinst-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # Draw a simple app icon (blue rounded square with a download arrow) and wrap it as a PNG-in-ICO file.
    Add-Type -AssemblyName System.Drawing
    $size = 256
    $bmp  = New-Object System.Drawing.Bitmap $size, $size
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $m = 8; $w = $size - 2 * $m; $d = 96          # margin, square width, corner diameter
    $shape = New-Object System.Drawing.Drawing2D.GraphicsPath
    $shape.AddArc($m,            $m,            $d, $d, 180, 90)
    $shape.AddArc($m + $w - $d,  $m,            $d, $d, 270, 90)
    $shape.AddArc($m + $w - $d,  $m + $w - $d,  $d, $d,   0, 90)
    $shape.AddArc($m,            $m + $w - $d,  $d, $d,  90, 90)
    $shape.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#3B82F6'))), $shape)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 22
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $g.DrawLine($pen, 128, 52, 128, 146)                                         # arrow shaft
    $g.DrawLines($pen, [System.Drawing.Point[]]@(
        [System.Drawing.Point]::new(86, 106), [System.Drawing.Point]::new(128, 148), [System.Drawing.Point]::new(170, 106)))  # head
    $g.DrawLine($pen, 78, 196, 178, 196)                                         # tray
    $g.Dispose()

    $png = New-Object System.IO.MemoryStream
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngBytes = $png.ToArray()

    $iconFile = Join-Path $work 'app.ico'
    $fs = [System.IO.File]::Create($iconFile)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)             # ICONDIR: 1 image
    $bw.Write([byte]0);   $bw.Write([byte]0);   $bw.Write([byte]0); $bw.Write([byte]0)   # 256x256 (0 = 256), no palette
    $bw.Write([uint16]1); $bw.Write([uint16]32)                                  # planes, bits per pixel
    $bw.Write([uint32]$pngBytes.Length); $bw.Write([uint32]22)                   # image size, offset
    $bw.Write($pngBytes)
    $bw.Close(); $fs.Close()

    $manifest = Join-Path $work 'app.manifest'
    $manifestText = Get-Content -LiteralPath $manifestFile -Raw
    if ($NoElevate) { $manifestText = $manifestText.Replace('requireAdministrator', 'asInvoker') }
    [System.IO.File]::WriteAllText($manifest, $manifestText, (New-Object System.Text.UTF8Encoding $false))

    # --- Compile ----------------------------------------------------------------------------
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $cscArgs = @(
        '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/warnaserror+',
        "/out:$OutFile",
        "/reference:$sma",
        "/win32manifest:$manifest",
        "/win32icon:$iconFile",
        "/resource:$scriptFile,Install-Software.ps1",
        $launcherFile
    )
    $output = & $csc @cscArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed:`n$($output | Out-String)" }

    $item = Get-Item -LiteralPath $OutFile
    Write-Host ("Built {0} ({1:N0} KB){2}" -f $item.FullName, ($item.Length / 1KB), $(if ($NoElevate) { ' [no-elevate test build]' } else { '' }))

    # Publish a SHA-256 next to the exe so a copy can be checked later (Get-FileHash <exe> -Algorithm SHA256).
    $hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText("$OutFile.sha256", "$hash  $($item.Name)`n", (New-Object System.Text.UTF8Encoding $false))
    Write-Host "SHA-256: $hash"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
