<#
.SYNOPSIS
    Shows a faint, click-through overlay with a line of text (default: the
    computer name) in the bottom-right corner of the primary screen.

.DESCRIPTION
    Runs non-blocking. The visible overlay lives in its own detached background
    process, so the caller returns immediately - exit 0 when the overlay is up,
    non-zero on failure. That makes it safe to run from an RMM such as NinjaOne,
    where a blocking script would hang the job until timeout.

    Run it again with a new -Text to update the text of the already-running
    overlay in place - no restart, no second window. Use -Stop (alias -Clear) to
    remove it.

    The overlay must run in the interactive user's session; a GUI cannot render
    from SYSTEM / session 0. From Ninja, set the script to run as the current
    logged-on user.

    Coordination uses a small per-user state file (%LOCALAPPDATA%\ComputerText\
    state.txt) that the overlay polls, and a session-local mutex to keep a single
    overlay and to detect whether one is already running.

.PARAMETER Text
    The text to display. Defaults to the computer name.

.PARAMETER Stop
    Remove the overlay. Alias: -Clear.

.PARAMETER Overlay
    Internal use only: hosts the actual window. Set by the self-launch; do not
    pass it yourself.

.EXAMPLE
    .\Set-ComputerText.ps1
    Shows the computer name and returns immediately.

.EXAMPLE
    .\Set-ComputerText.ps1 -Text "Underhall pagar"
    Starts the overlay, or updates the running one in place.

.EXAMPLE
    .\Set-ComputerText.ps1 -Stop
    Removes the overlay (same as -Clear).
#>
[CmdletBinding()]
param(
    [string] $Text = $env:COMPUTERNAME,

    [Alias('Clear')]
    [switch] $Stop,

    # Internal: run the actual window. Set by the detached self-launch.
    [Parameter(DontShow)]
    [switch] $Overlay
)

$ErrorActionPreference = 'Stop'

# Shared coordination state. Launcher and overlay run as the same user in the
# same session, so a per-user path and a session-local mutex line up.
$script:StateBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
$script:StateDir  = Join-Path $script:StateBase 'ComputerText'
$script:StatePath = Join-Path $script:StateDir 'state.txt'
$script:StopToken = '__STOP__'
$script:MutexName = 'Local\Set-ComputerText.Overlay'

function Test-OverlayRunning {
    $existing = $null
    if ([System.Threading.Mutex]::TryOpenExisting($script:MutexName, [ref]$existing)) {
        $existing.Dispose()
        return $true
    }
    return $false
}

function Write-State {
    param([string] $Value)
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $script:StatePath -Value $Value -Encoding UTF8
}

function Read-State {
    try {
        if (Test-Path -LiteralPath $script:StatePath) {
            return (Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop).TrimEnd()
        }
    }
    catch { }
    return $null
}

# ===================================================================== Overlay
if ($Overlay) {
    # Single overlay at a time: hold the mutex for this process's lifetime.
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        # WPF requires STA. Both default hosts (Windows PowerShell console, pwsh)
        # are STA, so this is only a safety net.
        [Console]::Error.WriteLine('Overlay requires an STA host.')
        exit 3
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    public const int GWL_EXSTYLE       = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW  = 0x00000080;
    public const int WS_EX_NOACTIVATE  = 0x08000000;
}
"@

    $window = New-Object System.Windows.Window
    $window.WindowStyle        = 'None'
    $window.ResizeMode         = 'NoResize'
    $window.SizeToContent      = 'WidthAndHeight'
    $window.ShowInTaskbar      = $false
    $window.Topmost            = $true
    $window.AllowsTransparency = $true
    $window.Background         = [System.Windows.Media.Brushes]::Transparent
    $window.Focusable          = $false

    $label = New-Object System.Windows.Controls.TextBlock
    $label.FontFamily = 'Segoe UI'
    $label.FontSize   = 16
    $label.FontWeight = 'Bold'
    $label.Foreground = [System.Windows.Media.Brushes]::Silver
    $label.Opacity    = 0.5

    # A tiny shadow keeps it readable on light backgrounds.
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius  = 0.2
    $shadow.ShadowDepth = 1
    $shadow.Opacity     = 0
    $label.Effect = $shadow

    $window.Content = $label

    $script:RightMargin  = 18
    $script:BottomMargin = 27
    $reposition = {
        $window.UpdateLayout()
        # WPF clamps the *first* SizeToContent pass to the OS minimum window
        # size (SystemParameters.MinimumWindowWidth/Height, 136x39 by default),
        # so the window stays far wider and taller than the text and the corner
        # maths puts the first line up and to the left of every later one.
        # Toggling SizeToContent forces a fresh pass, which is not clamped.
        $window.SizeToContent = 'Manual'
        $window.SizeToContent = 'WidthAndHeight'
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $window.Left = $wa.Right  - $window.ActualWidth  - $script:RightMargin
        $window.Top  = $wa.Bottom - $window.ActualHeight - $script:BottomMargin
    }

    # Initial text: whatever the launcher wrote, else the computer name.
    $initial = Read-State
    $label.Text = if ([string]::IsNullOrWhiteSpace($initial) -or $initial -eq $script:StopToken) {
        $env:COMPUTERNAME
    } else { $initial }

    $window.Add_SourceInitialized({
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $style = [Win32]::GetWindowLong($hwnd, [Win32]::GWL_EXSTYLE)
        $style = $style -bor [Win32]::WS_EX_TRANSPARENT `
                        -bor [Win32]::WS_EX_TOOLWINDOW `
                        -bor [Win32]::WS_EX_NOACTIVATE
        [Win32]::SetWindowLong($hwnd, [Win32]::GWL_EXSTYLE, $style) | Out-Null
    })
    $window.Add_ContentRendered({ & $reposition })

    # Poll the state file: pick up live text changes, and close on the stop token.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        $s = Read-State
        if ($s -eq $script:StopToken) { $window.Close(); return }
        $new = if ([string]::IsNullOrWhiteSpace($s)) { $env:COMPUTERNAME } else { $s }
        if ($new -ne $label.Text) {
            $label.Text = $new
            & $reposition
        }
    })
    $timer.Start()

    try   { $window.ShowDialog() | Out-Null }
    finally {
        $timer.Stop()
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    return
}

# ==================================================================== Launcher
if ($Stop) {
    if (Test-OverlayRunning) {
        Write-State $script:StopToken   # the overlay closes itself on its next tick
    }
    elseif (Test-Path -LiteralPath $script:StatePath) {
        Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# Set / update the text.
Write-State $Text

if (Test-OverlayRunning) {
    # A running overlay picks up the new text within its poll interval.
    exit 0
}

# Start a detached, hidden overlay in this (interactive user) session.
$hostExe = (Get-Process -Id $PID).Path
try {
    $proc = Start-Process -FilePath $hostExe `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", '-Overlay' `
        -WindowStyle Hidden -PassThru
}
catch {
    Write-Error "Failed to launch the overlay process: $($_.Exception.Message)"
    exit 1
}

# Give it a moment to fail fast (bad host, no GUI stack, non-STA).
Start-Sleep -Milliseconds 700
if ($proc.HasExited -and $proc.ExitCode -ne 0) {
    Write-Error "Overlay process exited immediately (code $($proc.ExitCode)). A GUI needs the interactive user's session - not SYSTEM/session 0."
    exit 1
}
exit 0
