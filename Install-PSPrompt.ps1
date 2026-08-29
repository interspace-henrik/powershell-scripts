<#
.SYNOPSIS
    Installs a shared two-line prompt for Windows PowerShell 5.1 and PowerShell 7+.

.DESCRIPTION
    Writes the prompt implementation to a shared location and injects a small
    marker-delimited stub into the relevant profile.ps1 files. The stub only
    dot-sources the shared file, so the prompt can be updated later without
    touching any profile again.

    Scope resolution:
      AllUsers    - requires elevation; if the current session is not elevated
                    the script relaunches itself and requests it via UAC.
                    Targets $PSHOME\profile.ps1 for every detected host
                    (Windows PowerShell x64, x86, and each installed
                    PowerShell 7+ major version).
      CurrentUser - no elevation required. Targets the per-user AllHosts
                    profile for both engines, resolved via the shell's
                    Documents known folder so OneDrive redirection is honored.
      Auto        - AllUsers when elevated, otherwise CurrentUser.

.PARAMETER Scope
    Installation scope. Defaults to Auto.

.PARAMETER AsciiOnly
    Force the ASCII glyph set instead of auto-detecting console encoding.

.PARAMETER ForceUtf8Console
    Let the prompt set [Console]::OutputEncoding to UTF-8 on Windows PowerShell
    5.1. This makes the Unicode glyphs render in legacy consoles, but it also
    changes how native command output is decoded. Off by default.

.PARAMETER SlowCommandThresholdSeconds
    Only show elapsed time for commands at or above this duration.

.PARAMETER Uninstall
    Remove the stub from every target profile and delete the shared file.

.EXAMPLE
    .\Install-PSPrompt.ps1 -WhatIf

.EXAMPLE
    .\Install-PSPrompt.ps1 -Scope AllUsers -ForceUtf8Console

.EXAMPLE
    .\Install-PSPrompt.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Auto', 'AllUsers', 'CurrentUser')]
    [string] $Scope = 'Auto',

    [switch] $AsciiOnly,

    [switch] $ForceUtf8Console,

    [ValidateRange(0, 3600)]
    [double] $SlowCommandThresholdSeconds = 2,

    [switch] $Uninstall,

    # Internal: set by the self-elevated relaunch so the new console stays open
    # long enough to read the result.
    [Parameter(DontShow)]
    [switch] $PauseOnExit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:StubVersion = '1'
$script:BeginMarker = "# BEGIN PSPrompt v$script:StubVersion"
$script:EndMarker   = "# END PSPrompt v$script:StubVersion"

trap {
    # In a self-elevated window an uncaught error would close the console
    # before anyone can read it.
    if ($PauseOnExit) {
        Write-Host $_ -ForegroundColor Red
        [void](Read-Host 'Press Enter to close')
        exit 1
    }
    break
}

#region Helpers

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Is64BitProcess {
    [Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem
}

function Invoke-ElevatedRestart {
    # Relaunch this script elevated (and in a 64-bit host) with the same
    # effective arguments, then surface the elevated run's outcome here.
    if (-not $PSCommandPath) {
        throw 'AllUsers scope requires elevation, but the script path could not be determined for self-elevation. Run from a saved .ps1 file, or start PowerShell as administrator.'
    }

    $hostExe = if ($PSVersionTable.PSVersion.Major -ge 6 -and (Test-Is64BitProcess)) {
        (Get-Process -Id $PID).Path
    }
    elseif (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        # From a 32-bit process System32 is redirected; Sysnative reaches the
        # real 64-bit host.
        Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    else {
        Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
        '-Scope', 'AllUsers', '-PauseOnExit'
        '-SlowCommandThresholdSeconds', ([string]$SlowCommandThresholdSeconds)
    )
    if ($AsciiOnly)        { $argList += '-AsciiOnly' }
    if ($ForceUtf8Console) { $argList += '-ForceUtf8Console' }
    if ($Uninstall)        { $argList += '-Uninstall' }
    if ($WhatIfPreference) { $argList += '-WhatIf' }

    Write-Host 'AllUsers scope requires administrator rights - requesting elevation (UAC)...'
    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Elevation was declined or failed: $($_.Exception.Message) Run as administrator, or use -Scope CurrentUser."
    }

    if ($proc.ExitCode -ne 0) {
        throw "The elevated run exited with code $($proc.ExitCode). See the elevated window for details."
    }
    Write-Host 'Elevated run finished. Open a new shell to confirm.'
}

function Write-Utf8BomFile {
    # Windows PowerShell 5.1 decodes BOM-less .ps1 files as ANSI, which mangles
    # every non-ASCII glyph. UTF-8 *with* BOM is the only encoding both engines
    # read correctly.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-ProfileTargets {
    param([Parameter(Mandatory)] [ValidateSet('AllUsers', 'CurrentUser')] [string] $Scope)

    $targets = New-Object System.Collections.Generic.List[psobject]

    if ($Scope -eq 'AllUsers') {
        # Explicit paths rather than $PSHOME: this script may run under either
        # engine, and we want to reach hosts we are not currently running in.
        $winPsRoot = Join-Path $env:windir 'System32'
        $winPsPath = Join-Path (Join-Path $winPsRoot 'WindowsPowerShell') 'v1.0\profile.ps1'
        if (Test-Path -LiteralPath (Split-Path -Parent $winPsPath)) {
            $targets.Add([pscustomobject]@{ Host = 'Windows PowerShell (x64)'; Path = $winPsPath })
        }

        $wowRoot = Join-Path $env:windir 'SysWOW64'
        $wowPath = Join-Path (Join-Path $wowRoot 'WindowsPowerShell') 'v1.0\profile.ps1'
        if (Test-Path -LiteralPath (Split-Path -Parent $wowPath)) {
            $targets.Add([pscustomobject]@{ Host = 'Windows PowerShell (x86)'; Path = $wowPath })
        }

        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $base) { continue }
            $psRoot = Join-Path $base 'PowerShell'
            if (-not (Test-Path -LiteralPath $psRoot)) { continue }

            foreach ($dir in Get-ChildItem -LiteralPath $psRoot -Directory -ErrorAction SilentlyContinue) {
                if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'pwsh.exe'))) { continue }
                $targets.Add([pscustomobject]@{
                    Host = "PowerShell $($dir.Name) ($base)"
                    Path = Join-Path $dir.FullName 'profile.ps1'
                })
            }
        }

        # MSI installs register InstallLocation here and may live outside
        # Program Files (custom install directory).
        foreach ($hive in @(
            'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShellCore\InstalledVersions'
        )) {
            foreach ($key in @(Get-ChildItem -Path $hive -ErrorAction SilentlyContinue)) {
                $location = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).InstallLocation
                if (-not $location) { continue }
                $location = $location.TrimEnd('\')
                if (-not (Test-Path -LiteralPath (Join-Path $location 'pwsh.exe'))) { continue }
                $targets.Add([pscustomobject]@{
                    Host = "PowerShell (registry: $location)"
                    Path = Join-Path $location 'profile.ps1'
                })
            }
        }
    }
    else {
        # GetFolderPath resolves OneDrive Known Folder Move; $HOME\Documents does not.
        $documents = [Environment]::GetFolderPath('MyDocuments')
        if (-not $documents) { throw 'Unable to resolve the Documents folder for the current user.' }

        $targets.Add([pscustomobject]@{
            Host = 'Windows PowerShell (current user)'
            Path = Join-Path (Join-Path $documents 'WindowsPowerShell') 'profile.ps1'
        })
        $targets.Add([pscustomobject]@{
            Host = 'PowerShell 7+ (current user)'
            Path = Join-Path (Join-Path $documents 'PowerShell') 'profile.ps1'
        })
    }

    # Program Files scan and registry entries usually overlap; keep the first.
    $seen = @{}
    foreach ($target in $targets) {
        $key = $target.Path.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $target
        }
    }
}

function Set-SharedDirectoryAcl {
    # Every user executes this file on shell start, so a non-admin must not be
    # able to write to it. Well-known SIDs keep this working on localized Windows.
    param([Parameter(Mandatory)] [string] $Path)

    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $users  = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none    = [Security.AccessControl.PropagationFlags]::None

    foreach ($entry in @(
        @{ Sid = $system; Rights = 'FullControl' },
        @{ Sid = $admins; Rights = 'FullControl' },
        @{ Sid = $users;  Rights = 'ReadAndExecute' }
    )) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $entry.Sid, $entry.Rights, $inherit, $none, 'Allow')))
    }

    $acl.SetOwner($admins)
    Set-Acl -Path $Path -AclObject $acl
}

function Update-ProfileStub {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $ProfilePath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $StubText,
        [switch] $Remove
    )

    $existing = ''
    if (Test-Path -LiteralPath $ProfilePath) {
        $existing = [System.IO.File]::ReadAllText($ProfilePath)
    }

    $pattern = '(?ms)\r?\n?' + [regex]::Escape($script:BeginMarker) + '.*?' +
               [regex]::Escape($script:EndMarker) + '\r?\n?'
    $stripped = [regex]::Replace($existing, $pattern, [Environment]::NewLine)
    $hadStub  = $stripped -ne $existing

    if ($Remove) {
        if (-not $hadStub) { return 'NotPresent' }
        $updated = $stripped
        $action  = 'Removed'
    }
    else {
        $updated = $stripped.TrimEnd()
        if ($updated) { $updated += [Environment]::NewLine + [Environment]::NewLine }
        $updated += $StubText + [Environment]::NewLine
        $action  = if ($hadStub) { 'Updated' } else { 'Added' }
    }

    if ($updated -eq $existing) { return 'Unchanged' }

    if ($PSCmdlet.ShouldProcess($ProfilePath, "$action PSPrompt stub")) {
        $parent = Split-Path -Parent $ProfilePath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (-not $updated.Trim()) {
            Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction SilentlyContinue
            return 'Removed (profile emptied)'
        }
        Write-Utf8BomFile -Path $ProfilePath -Content $updated
    }
    return $action
}

#endregion

#region Prompt payload

# Single-quoted here-string: nothing below is expanded here. Placeholders in
# {{BRACES}} are substituted before the file is written.
$promptTemplate = @'
# PSPrompt - shared prompt for Windows PowerShell 5.1 and PowerShell 7+.
# Generated by Install-PSPrompt.ps1. Local edits are lost on reinstall.

$script:PSPromptAscii     = {{ASCII_ONLY}}
$script:PSPromptForceUtf8 = {{FORCE_UTF8}}
$script:PSPromptSlowAfter = {{SLOW_AFTER}}

# 5.1 has no `e escape and no `u{} sequence.
$script:PSPromptEsc = [char]27

# ISE renders no ANSI at all; degrade to a plain prompt there.
$script:PSPromptAnsi = $Host.Name -ne 'Windows PowerShell ISE Host'

if ($script:PSPromptForceUtf8 -and $PSVersionTable.PSVersion.Major -lt 6) {
    # Tradeoff: makes the glyphs render in legacy consoles, but also changes
    # how native command output is decoded on the way back in.
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

if (-not $script:PSPromptAscii) {
    # The host writes the prompt via WriteConsoleW, so glyph rendering depends
    # on the terminal and font, not on [Console]::OutputEncoding. PS7 implies a
    # modern enough stack; on 5.1, trust known-modern terminals or an explicit
    # UTF-8 codepage, and let plain conhost (possibly raster-font) degrade.
    $modernTerminal = $PSVersionTable.PSVersion.Major -ge 6 -or
                      $env:WT_SESSION -or
                      $env:TERM_PROGRAM -eq 'vscode' -or
                      [Console]::OutputEncoding.CodePage -eq 65001
    $script:PSPromptAscii = -not $script:PSPromptAnsi -or -not $modernTerminal
}

$script:PSPromptGlyph = if ($script:PSPromptAscii) {
    @{ Top = '- '; Bottom = '> '; Sigil = '>'; Sep = ' | '
       Dirty = '*'; Ahead = '^'; Behind = 'v'; Fail = 'x'; Admin = 'adm'; Ellipsis = '...' }
} else {
    @{ Top = [char]0x256D + ' '; Bottom = [char]0x2570 + ' '; Sigil = [char]0x276F
       Sep = ' ' + [char]0x00B7 + ' '
       Dirty = [char]0x25CF; Ahead = [char]0x2191; Behind = [char]0x2193
       Fail = [char]0x2717; Admin = [char]0x26A1; Ellipsis = [char]0x2026 }
}

# Resolved once at load, not per keystroke.
$script:PSPromptIsAdmin = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $script:PSPromptIsAdmin = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# Probed once: a missing git would otherwise error on every prompt inside a repo.
$script:PSPromptHasGit = [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)

function script:Write-PSPromptColor {
    param([string] $Text, [string] $Color)
    if (-not $script:PSPromptAnsi) { return $Text }
    "$($script:PSPromptEsc)[38;5;${Color}m$Text$($script:PSPromptEsc)[0m"
}

function script:Get-PSPromptPath {
    param([int] $Keep = 3)

    if ($PWD.Provider.Name -ne 'FileSystem') { return $PWD.Path }

    $path = $PWD.Path
    if ($path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        $path = '~' + $path.Substring($HOME.Length)
    }

    $sep = [IO.Path]::DirectorySeparatorChar
    # .NET Framework lacks the Split(char, StringSplitOptions) overload.
    $parts = $path.Split([char[]]$sep, [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -le $Keep) { return $path }

    $tail = $parts[($parts.Count - $Keep)..($parts.Count - 1)]
    "$($script:PSPromptGlyph.Ellipsis)$sep" + ($tail -join $sep)
}

function script:Get-PSPromptGit {
    if (-not $script:PSPromptHasGit) { return $null }

    # Probe the filesystem first so we never spawn git outside a repository.
    $dir = $PWD.ProviderPath
    while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        $dir = Split-Path -Parent $dir
    }
    if (-not $dir) { return $null }

    # A session-level $ErrorActionPreference = 'Stop' makes redirected stderr a
    # terminating error on 5.1; the child scope keeps the probe quiet.
    $status = & {
        $ErrorActionPreference = 'Continue'
        git --no-optional-locks status --porcelain=v2 --branch 2>$null
    }
    if ($LASTEXITCODE -ne 0 -or -not $status) { return $null }

    $branch = '?'; $ahead = 0; $behind = 0; $dirty = 0
    foreach ($line in $status) {
        if ($line.StartsWith('# branch.head ')) {
            $branch = $line.Substring(14)
        }
        elseif ($line.StartsWith('# branch.ab ')) {
            $ab = $line.Substring(12).Split(' ')
            $ahead = [int]$ab[0]; $behind = [int]$ab[1]
        }
        elseif (-not $line.StartsWith('#')) {
            $dirty++
        }
    }

    $text = $branch
    if ($dirty)  { $text += " $($script:PSPromptGlyph.Dirty)$dirty" }
    if ($ahead)  { $text += " $($script:PSPromptGlyph.Ahead)$ahead" }
    if ($behind) { $text += " $($script:PSPromptGlyph.Behind)$behind" }

    $color = if ($dirty) { '221' } else { '108' }
    script:Write-PSPromptColor -Text $text -Color $color
}

function global:prompt {
    # $? must be read by the first statement executed; anything else clobbers it.
    $ok = $?
    # Unset until the first native command runs, which trips Set-StrictMode.
    $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }

    $segments = New-Object System.Collections.Generic.List[string]

    if ($script:PSPromptIsAdmin) {
        $segments.Add((script:Write-PSPromptColor -Text $script:PSPromptGlyph.Admin -Color '203'))
    }
    $segments.Add((script:Write-PSPromptColor -Text $env:COMPUTERNAME -Color '245'))
    $segments.Add((script:Write-PSPromptColor -Text (script:Get-PSPromptPath) -Color '110'))

    $git = script:Get-PSPromptGit
    if ($git) { $segments.Add($git) }

    $last = Get-History -Count 1 -ErrorAction SilentlyContinue
    if ($last -and $last.EndExecutionTime -gt $last.StartExecutionTime) {
        # HistoryInfo.Duration only exists on PowerShell 7+.
        $elapsed = ($last.EndExecutionTime - $last.StartExecutionTime).TotalSeconds
        if ($elapsed -ge $script:PSPromptSlowAfter) {
            $segments.Add((script:Write-PSPromptColor -Text ("{0:0.#}s" -f $elapsed) -Color '245'))
        }
    }

    # $LASTEXITCODE persists from the last native command, so this is a
    # heuristic: a failed cmdlet after a failed exe reports the exe's code.
    if (-not $ok) {
        $code = if ($exitCode) { $exitCode } else { 1 }
        $segments.Add((script:Write-PSPromptColor -Text "$($script:PSPromptGlyph.Fail) $code" -Color '203'))
    }

    $sigilColor = if ($ok) { '114' } else { '203' }
    $rule = script:Write-PSPromptColor -Text $script:PSPromptGlyph.Top -Color '238'
    $tail = script:Write-PSPromptColor -Text $script:PSPromptGlyph.Bottom -Color '238'
    $sigil = script:Write-PSPromptColor -Text $script:PSPromptGlyph.Sigil -Color $sigilColor

    $sep = script:Write-PSPromptColor -Text $script:PSPromptGlyph.Sep -Color '238'
    [Environment]::NewLine + $rule + ($segments -join $sep) + [Environment]::NewLine + $tail + $sigil + ' '
}

# PSReadLine is optional and its parameters vary by version, so probe first.
$psrl = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($psrl) {
    $indent = if ($script:PSPromptAscii) { '  . ' } else { '  ' + [char]0x2219 + ' ' }
    try { Set-PSReadLineOption -ContinuationPrompt $indent } catch { }

    # Deliberately disable PSReadLine's parse-error prompt repaint. It rewrites
    # the prompt's trailing cells with its own width math, which disagrees with
    # the terminal for ambiguous-width glyphs like the sigil and paints the red
    # sigil one cell off, corrupting the input position. The prompt already
    # colors the sigil by the last command's result.
    if ($psrl.Parameters.ContainsKey('PromptText')) {
        try { Set-PSReadLineOption -PromptText '' } catch { }
    }
}
'@

#endregion

#region Main

if ($Scope -eq 'Auto') {
    $Scope = if (Test-IsElevated) { 'AllUsers' } else { 'CurrentUser' }
    Write-Verbose "Scope resolved to $Scope."
}

if ($Scope -eq 'AllUsers') {
    if (-not (Test-IsElevated) -or -not (Test-Is64BitProcess)) {
        # Not elevated, or a 32-bit process with System32 redirected: relaunch
        # in an elevated 64-bit host instead of failing.
        Invoke-ElevatedRestart
        return
    }
    $installRoot = Join-Path $env:ProgramData 'PSPrompt'
}
else {
    $installRoot = Join-Path $env:LOCALAPPDATA 'PSPrompt'
}

$promptPath = Join-Path $installRoot 'prompt.ps1'
$targets = Get-ProfileTargets -Scope $Scope

if (-not $targets) { throw 'No PowerShell hosts were detected for the selected scope.' }

Write-Verbose "Shared prompt: $promptPath"

if ($Uninstall) {
    foreach ($target in $targets) {
        $result = Update-ProfileStub -ProfilePath $target.Path -StubText '' -Remove
        Write-Host ("{0,-38} {1}" -f $target.Host, $result)
    }

    if (Test-Path -LiteralPath $installRoot) {
        if ($PSCmdlet.ShouldProcess($installRoot, 'Delete shared prompt directory')) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force
        }
        Write-Host ("{0,-38} {1}" -f 'Shared files', 'Removed')
    }

    Write-Host ''
    Write-Host 'Uninstalled. Open a new shell to confirm.'
    if ($PauseOnExit) { [void](Read-Host 'Press Enter to close') }
    return
}

# 1. Shared prompt file.
if (-not (Test-Path -LiteralPath $installRoot)) {
    if ($PSCmdlet.ShouldProcess($installRoot, 'Create directory')) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }
}

if ($Scope -eq 'AllUsers' -and (Test-Path -LiteralPath $installRoot)) {
    if ($PSCmdlet.ShouldProcess($installRoot, 'Restrict ACL to Administrators write, Users read')) {
        Set-SharedDirectoryAcl -Path $installRoot
    }
}

$promptContent = $promptTemplate.
    Replace('{{ASCII_ONLY}}',  $(if ($AsciiOnly) { '$true' } else { '$false' })).
    Replace('{{FORCE_UTF8}}',  $(if ($ForceUtf8Console) { '$true' } else { '$false' })).
    Replace('{{SLOW_AFTER}}',  ([string]$SlowCommandThresholdSeconds))

if ($PSCmdlet.ShouldProcess($promptPath, 'Write prompt implementation')) {
    Write-Utf8BomFile -Path $promptPath -Content $promptContent
}

# 2. Profile stubs.
$stub = @"
$script:BeginMarker
`$__PSPromptFile = '$promptPath'
if (Test-Path -LiteralPath `$__PSPromptFile) { . `$__PSPromptFile }
Remove-Variable -Name __PSPromptFile -ErrorAction SilentlyContinue
$script:EndMarker
"@

foreach ($target in $targets) {
    try {
        $result = Update-ProfileStub -ProfilePath $target.Path -StubText $stub
    }
    catch {
        $result = "Failed: $($_.Exception.Message)"
    }
    Write-Host ("{0,-38} {1}" -f $target.Host, $result)
}

# 3. Post-install checks worth surfacing.
Write-Host ''

$policy = Get-ExecutionPolicy
if ($policy -in @('Restricted', 'AllSigned')) {
    Write-Warning "ExecutionPolicy is $policy. Profiles will not load until that changes or the files are signed."
}

if (-not $AsciiOnly -and -not $ForceUtf8Console -and
    -not $env:WT_SESSION -and $env:TERM_PROGRAM -ne 'vscode' -and
    [Console]::OutputEncoding.CodePage -ne 65001) {
    Write-Warning 'Legacy console without UTF-8 detected. Windows PowerShell 5.1 in plain conhost falls back to ASCII glyphs (PowerShell 7+ is unaffected). Use -ForceUtf8Console to override for 5.1.'
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning 'git was not found on PATH. The git segment stays hidden until it is.'
}

if ($Scope -eq 'AllUsers') {
    # A Store/MSIX or portable pwsh keeps $PSHOME read-only, so no machine-wide
    # profile can ever reach it; surface that instead of failing silently.
    $targetDirs = @($targets | ForEach-Object { (Split-Path -Parent $_.Path).TrimEnd('\') })
    foreach ($pwshCmd in @(Get-Command pwsh -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $pwshDir = (Split-Path -Parent $pwshCmd.Source).TrimEnd('\')
        if ($targetDirs -notcontains $pwshDir) {
            Write-Warning ("pwsh at '{0}' has no AllUsers profile target (Store/MSIX and portable installs cannot take machine-wide profiles). Run -Scope CurrentUser on this machine to cover it." -f $pwshCmd.Source)
        }
    }
}

Write-Host "Installed ($Scope). Open a new shell to confirm."
if ($PauseOnExit) { [void](Read-Host 'Press Enter to close') }

#endregion
