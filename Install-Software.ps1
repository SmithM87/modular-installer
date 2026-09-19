<#
.SYNOPSIS
    Modular, dark-themed WPF software installer built on winget.

.DESCRIPTION
    Single-file script. On launch it:
      1. Restarts itself elevated (UAC prompt) and in STA mode if it is not already.
      2. Builds a categorized checkbox list from the $Apps table below.
      3. Installs the selected apps through `winget` on a background Runspace, streaming
         winget's output line by line into an embedded log pane. The UI thread never blocks:
         the worker only enqueues text; a DispatcherTimer on the UI thread drains the queue.

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
    @{ Category = 'Utilities'; Name = '7-Zip';            WingetId = '7zip.7zip';                  PreChecked = $true  }
    @{ Category = 'Utilities'; Name = 'Notepad++';        WingetId = 'Notepad++.Notepad++';        PreChecked = $true  }
    @{ Category = 'Dev Tools'; Name = 'Git';              WingetId = 'Git.Git';                    PreChecked = $false }
    @{ Category = 'Dev Tools'; Name = 'Windows Terminal'; WingetId = 'Microsoft.WindowsTerminal';  PreChecked = $false }
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
#  3. BACKGROUND WORKER  -  runs inside its own Runspace, never touches the UI
# ============================================================================================
# Kept as a scriptblock so the parser checks it, then passed to the runspace as text.
# Communication with the UI thread is one-way through two thread-safe objects:
#   $Queue - ConcurrentQueue of { Text, Level } log entries the UI drains
#   $State - synchronized hashtable with progress counters and the Cancel flag
$Worker = {
    param($Apps, $State, $Queue, $DryRun)

    function Send-Log([string]$Text, [string]$Level = 'info') {
        $Queue.Enqueue([pscustomobject]@{ Text = $Text; Level = $Level })
    }
    function Get-Stamp { (Get-Date).ToString('HH:mm:ss') }

    # winget draws spinners ("- \ | /") and block progress bars with carriage returns. When read
    # line by line that becomes hundreds of junk lines, so drop them.
    # (Block characters are built from code points to keep this file pure ASCII, which Windows PowerShell 5.1 needs.)
    $blocks = -join ([char[]](0x2588, 0x2593, 0x2592, 0x2591))
    $noise  = [regex]('^\s*$|^\s*[-\\|/]\s*$|[' + $blocks + ']|^\s*\d+(\.\d+)?\s*[KMG]?i?B\s*/\s*\d+(\.\d+)?\s*[KMG]?i?B\s*$')

    $total = @($Apps).Count
    $index = 0

    try {
        foreach ($app in $Apps) {
            $index++

            if ($State.Cancel) {
                Send-Log ("[{0}] Skipped {1} (cancelled)" -f (Get-Stamp), $app.Name) 'warn'
                $State.Skipped++
                continue
            }

            $State.Current = "Installing $($app.Name) ($index of $total)"
            Send-Log '' 'info'
            Send-Log ("[{0}] ({1}/{2}) Installing {3}" -f (Get-Stamp), $index, $total, $app.Name) 'head'

            # The id ends up on a command line, so accept only characters valid in winget ids.
            if ($app.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') {
                Send-Log "Invalid winget id '$($app.Id)'. Skipping." 'err'
                $State.Failed++; $State.Completed++
                continue
            }

            $wingetArgs = "install --exact --id $($app.Id) --silent --accept-package-agreements --accept-source-agreements"
            Send-Log "> winget $wingetArgs" 'cmd'

            if ($DryRun) {
                # Fake winget: a few lines with a spinner and delays. Ids ending in ".Fail" simulate an error.
                $inner = "echo Found $($app.Name) [$($app.Id)] Version 1.0.0 & ping -n 2 127.0.0.1 >nul" +
                         " & echo Downloading https://example.invalid/$($app.Id) & echo   - & ping -n 2 127.0.0.1 >nul & echo   \" +
                         " & echo Successfully verified installer hash & echo Starting package install... & ping -n 2 127.0.0.1 >nul"
                if ($app.Id -like '*.Fail') { $inner += ' & echo Simulated failure & exit /b 1' }
                else                        { $inner += ' & echo Successfully installed' }
            }
            else {
                $inner = "winget $wingetArgs"
            }

            $exit = $null
            try {
                # cmd.exe merges winget's stderr into stdout ("2>&1") so both streams arrive in order
                # on a single pipe that we can read line by line.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName               = $env:ComSpec
                $psi.Arguments              = "/d /c $inner 2>&1"
                $psi.UseShellExecute        = $false
                $psi.CreateNoWindow         = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardInput  = $true      # closed right away so winget can never wait on a prompt
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                [void]$proc.Start()
                $State.Process = $proc                   # lets the UI kill it if the window is closed mid-install
                $proc.StandardInput.Close()

                $last = $null
                while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
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
                $State.Process = $null
                $proc.Dispose()
            }
            catch {
                Send-Log "Could not run installer: $($_.Exception.Message)" 'err'
            }

            # winget exit codes: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
            $stamp = Get-Stamp
            switch ($exit) {
                0            { Send-Log "[$stamp] OK: $($app.Name) installed."                              'ok';   $State.Succeeded++ }
                -1978335135  { Send-Log "[$stamp] OK: $($app.Name) is already installed."                    'ok';   $State.Succeeded++ }
                -1978335189  { Send-Log "[$stamp] OK: $($app.Name) is already up to date."                   'ok';   $State.Succeeded++ }
                3010         { Send-Log "[$stamp] OK: $($app.Name) installed. A restart is required."        'warn'; $State.Succeeded++ }
                default      { Send-Log "[$stamp] FAILED: $($app.Name) (exit code $exit)."                    'err';  $State.Failed++ }
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
#  4. XAML  -  dark theme, custom control templates, layout
# ============================================================================================
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Software Installer" Width="1100" Height="700" MinWidth="820" MinHeight="520"
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
                            <StackPanel Orientation="Horizontal">
                                <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" VerticalAlignment="Center"
                                        Background="{StaticResource SurfaceBrush}" BorderBrush="#5A5A68" BorderThickness="1.5">
                                    <Path x:Name="Check" Data="M3,7.5 L6,10.5 L12,4.5" Stroke="White" StrokeThickness="2"
                                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                          Visibility="Collapsed"/>
                                </Border>
                                <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
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
            <ColumnDefinition Width="360" MinWidth="300"/>
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
                                ToolTip="Skip the remaining apps after the current install finishes"/>
                    </Grid>
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
    $LogBox       = $Window.FindName('LogBox')
    $StatusText   = $Window.FindName('StatusText')
    $Progress     = $Window.FindName('Progress')

    $TextBrush  = $Window.FindResource('TextBrush')
    $MutedBrush = $Window.FindResource('MutedBrush')

    $Window.Title = 'Software Installer' + $(if ($isAdmin) { ' (Administrator)' } elseif ($DryRun) { ' (dry run)' } else { '' })

    # Dark title bar on Windows 10 20H1+/11 (silently ignored where unsupported).
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
    $Window.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
            $dark = 1
            [void][Win32.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
        } catch { }
    })

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

    function Sync-LogQueue {
        # Only auto-scroll if the user hasn't scrolled up to read something.
        $atBottom = ($LogBox.VerticalOffset + $LogBox.ViewportHeight) -ge ($LogBox.ExtentHeight - 24)
        $item = $null; $added = $false
        while ($Queue.TryDequeue([ref]$item)) {
            Add-LogLine $item.Text $item.Level
            $added = $true
        }
        if ($added) {
            # Cap the document so very long sessions stay fast (inlines come in Run + LineBreak pairs).
            if ($LogPara.Inlines.Count -gt 8000) {
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
            $label = [System.Windows.Controls.StackPanel]::new()
            $label.Orientation = 'Horizontal'

            $name = [System.Windows.Controls.TextBlock]::new()
            $name.Text = $app.Name
            $name.FontSize = 13.5
            $name.Foreground = $TextBrush
            [void]$label.Children.Add($name)

            $id = [System.Windows.Controls.TextBlock]::new()
            $id.Text = $app.WingetId
            $id.FontSize = 11
            $id.Foreground = $MutedBrush
            $id.Margin = [System.Windows.Thickness]::new(8, 2, 0, 0)
            $id.VerticalAlignment = 'Center'
            [void]$label.Children.Add($id)

            $cb = [System.Windows.Controls.CheckBox]::new()
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
        $BtnCancel.Visibility   = if ($IsRunning) { 'Visible' } else { 'Collapsed' }
        $BtnCancel.IsEnabled    = $true
        Update-SelectionCount
    }

    function Stop-InstallerProcess {
        $p = $State.Process
        if ($p) {
            # /T also kills winget and any installer it spawned.
            try { Start-Process taskkill.exe -ArgumentList "/PID $($p.Id) /T /F" -WindowStyle Hidden -Wait } catch { }
        }
    }

    function Start-Install {
        $selected = @($Checkboxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($selected.Count -eq 0) { return }

        if (-not $DryRun -and -not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            Add-LogLine 'winget was not found. Install "App Installer" from the Microsoft Store and try again.' 'err'
            return
        }

        $script:State = [hashtable]::Synchronized(@{
            Cancel = $false; Total = $selected.Count; Completed = 0
            Succeeded = 0; Failed = 0; Skipped = 0
            Current = 'Starting...'; Summary = ''; Process = $null
        })

        # A dedicated runspace = a separate thread. The UI thread only starts it and polls it.
        $script:Rs = [runspacefactory]::CreateRunspace()
        $script:Rs.ApartmentState = 'MTA'
        $script:Rs.ThreadOptions  = 'ReuseThread'
        $script:Rs.Open()

        $script:Ps = [powershell]::Create()
        $script:Ps.Runspace = $script:Rs
        [void]$script:Ps.AddScript($Worker.ToString()).
            AddArgument($selected).AddArgument($script:State).AddArgument($Queue).AddArgument([bool]$DryRun)

        $Progress.Maximum = $selected.Count
        $Progress.Value   = 0
        Set-UiRunning $true
        $Timer.Start()
        $script:Async = $script:Ps.BeginInvoke()      # returns immediately; the window stays responsive
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
        $finished = $Async.IsCompleted          # read BEFORE draining so no trailing lines are lost
        Sync-LogQueue
        $Progress.Value  = $State.Completed
        $StatusText.Text = $State.Current
        if ($finished) { Complete-Install }
    })

    # ---- Buttons -------------------------------------------------------------------------
    $BtnSelectAll.Add_Click({ foreach ($c in $Checkboxes) { $c.IsChecked = $true } })
    $BtnDeselect.Add_Click({  foreach ($c in $Checkboxes) { $c.IsChecked = $false } })
    $BtnClear.Add_Click({     $LogPara.Inlines.Clear() })
    $BtnInstall.Add_Click({
        try { Start-Install } catch { Add-LogLine "Could not start: $($_.Exception.Message)" 'err'; Set-UiRunning $false }
    })
    $BtnCancel.Add_Click({
        $State.Cancel = $true
        $BtnCancel.IsEnabled = $false
        Add-LogLine 'Cancel requested. The current install will finish; remaining apps are skipped.' 'warn'
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
    if (-not $DryRun -and -not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Add-LogLine 'Warning: winget.exe was not found on this system.' 'warn'
    }

    [void]$Window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Unexpected error:`n`n$($_ | Out-String)", 'Software Installer', 'OK', 'Error')
    exit 1
}
