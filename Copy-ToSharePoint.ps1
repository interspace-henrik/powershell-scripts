#Requires -Version 5.1

<#
.SYNOPSIS
    Copies a folder from a network drive into a SharePoint Online document
    library folder, using rclone under the hood with a robocopy-style console:
    live progress bar, one line per copied file and a summary table.

.DESCRIPTION
    Paste the destination folder's URL straight from the browser's address bar
    into -Url; the tenant, site, document library and folder are all read from
    it. The script takes care of the rest:

      1. rclone is downloaded on first use (pinned version, SHA-256 verified)
         into %LOCALAPPDATA%\Copy-ToSharePoint\bin. -UpdateRclone fetches the
         latest release instead.
      2. One rclone remote per tenant, named after the tenant - the part of the
         host name before .sharepoint.com. The first run against a tenant opens
         the browser for a Microsoft 365 sign-in (OAuth, MFA works); the token
         is cached and reused for every site and library in that tenant.
      3. The document library is looked up through Microsoft Graph (and the
         answer cached), then the copy runs as rclone copy - or rclone sync with
         -Mirror.

    Robocopy habits map onto the parameters like this:

      robocopy      Copy-ToSharePoint
      --------      -----------------
      src dst       -Source -Url    (also positional, in that order)
      /E            always: recursive, empty folders included
      /MIR          -Mirror         (deletes destination files missing in source)
      /XF  /XD      -ExcludeFile / -ExcludeDir
      /R:n /W:n     -Retries / -RetryWaitSeconds
      /MT:n         -Transfers (and -Checkers)
      /L            -WhatIf         (rclone --dry-run: nothing is changed)
      /LOG  /LOG+   -LogFile / -AppendLog
      /NFL          -NoFileList
      /IPG          -BandwidthLimit

    SharePoint rewrites Office files after upload (it stamps metadata into
    them), so their size and checksum never match the source again. For
    document libraries the script therefore compares on modification time only
    (--ignore-size --ignore-checksum); -StrictCompare switches that off.

    Some tenants block users from consenting to third-party apps, which the
    first sign-in then reports as "admin approval required". Either have an
    admin consent to rclone, or register an app of your own and pass
    -ClientId/-ClientSecret.

    The exit code is rclone's: 0 on success, non-zero when anything failed.

.PARAMETER Source
    Folder (or single file) to copy: a UNC path, a mapped drive or any local
    path. As with robocopy, the folder's contents land in the destination
    folder, not a copy of the folder itself.

.PARAMETER Url
    Destination folder in SharePoint, copied from the browser's address bar
    while viewing that folder. Library views (...AllItems.aspx?id=...), plain
    folder URLs and "people with existing access" links (/:f:/r/...) all work.
    Sharing links of the /:f:/s/... kind carry no path - open the folder and
    copy the address bar instead.

.PARAMETER RemoteName
    rclone remote to use. Defaults to the tenant name taken from -Url.

.PARAMETER ConfigPath
    rclone config file that holds the per-tenant remotes and tokens. Defaults
    to %LOCALAPPDATA%\Copy-ToSharePoint\rclone.conf, apart from any personal
    rclone setup. The library lookup cache (drives.json) lives next to it.

.PARAMETER SignIn
    Sign in to the tenant again in the browser, replacing the saved token.
    Needed when the saved sign-in has expired (after about 90 days unused) or
    to switch account.

.PARAMETER Mirror
    Make the destination an exact copy of the source (rclone sync, robocopy
    /MIR): files in the destination folder that are not in the source are
    DELETED. Asks for confirmation unless -Force is given; try -WhatIf first.

.PARAMETER Force
    Skip the -Mirror confirmation (needed for unattended runs).

.PARAMETER ExcludeFile
    File names or wildcards to skip at any depth, like robocopy /XF.

.PARAMETER ExcludeDir
    Folder names to skip at any depth, like robocopy /XD. A full path below
    -Source excludes just that one folder.

.PARAMETER Retries
    How many times rclone retries the whole job when files failed (robocopy /R).

.PARAMETER RetryWaitSeconds
    Pause between those retries (robocopy /W).

.PARAMETER Transfers
    Files uploaded in parallel (robocopy /MT). SharePoint throttles hard
    above a handful.

.PARAMETER Checkers
    Files compared in parallel while working out what needs copying.

.PARAMETER BandwidthLimit
    Cap the upload speed, rclone syntax: 10M = 10 MiB/s (robocopy /IPG).

.PARAMETER LogFile
    Also write the console report (header, file lines, errors, summary) to
    this file. Overwritten unless -AppendLog is set.

.PARAMETER AppendLog
    Append to -LogFile instead of overwriting it (robocopy /LOG+).

.PARAMETER NoFileList
    Do not list individual files; errors and the summary are still shown
    (robocopy /NFL).

.PARAMETER NativeProgress
    Show rclone's own live progress display instead of the PowerShell
    progress bar, file list and summary table.

.PARAMETER StrictCompare
    Compare size and checksum as well as modification time, even for
    SharePoint document libraries. Office files will then report checksum
    errors and be re-uploaded on every run.

.PARAMETER SourceCredential
    Credentials for a UNC source that the current account cannot read. The
    share is connected for the duration of the run and disconnected after.

.PARAMETER ClientId
    Client id of your own Entra ID app registration, for tenants that block
    the default rclone app. Stored in the remote at first sign-in.

.PARAMETER ClientSecret
    Client secret for -ClientId. Note that rclone keeps it in plain text in
    -ConfigPath.

.PARAMETER DriveId
    Skip the Graph lookup and use this drive (document library) id directly.
    The first path segment after the site is then taken as the library.

.PARAMETER DriveType
    Drive type for -DriveId: documentLibrary (SharePoint), business
    (OneDrive for Business) or personal.

.PARAMETER RclonePath
    Use an existing rclone.exe instead of the managed download.

.PARAMETER UpdateRclone
    Download the latest rclone release instead of keeping the installed one.

.PARAMETER PassThru
    Also return a result object (counts, bytes, elapsed time, errors).

.EXAMPLE
    .\Copy-ToSharePoint.ps1 \\fs01\Projekt\Kund "https://contoso.sharepoint.com/sites/Kund/Shared%20Documents/Forms/AllItems.aspx?id=%2Fsites%2FKund%2FShared%20Documents%2FArkiv"

    Copies the contents of \\fs01\Projekt\Kund into the Arkiv folder of the
    Documents library on the Kund site. The first run signs in to the contoso
    tenant in the browser.

.EXAMPLE
    .\Copy-ToSharePoint.ps1 -Source X:\Ekonomi -Url $url -ExcludeFile *.tmp,'~$*' -ExcludeDir node_modules -WhatIf

    Dry run: lists what would be copied without changing anything.

.EXAMPLE
    .\Copy-ToSharePoint.ps1 -Source \\fs01\Delat -Url $url -Mirror -Force -LogFile C:\Logs\delat.log -NoFileList

    Unattended mirror, with the report written to a log file.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Source,

    [Parameter(Mandatory, Position = 1)]
    [string] $Url,

    [string] $RemoteName,

    [string] $ConfigPath,

    [switch] $SignIn,

    [switch] $Mirror,

    [switch] $Force,

    [string[]] $ExcludeFile,

    [string[]] $ExcludeDir,

    [ValidateRange(1, 100)]
    [int] $Retries = 3,

    [ValidateRange(0, 3600)]
    [int] $RetryWaitSeconds = 5,

    [ValidateRange(1, 64)]
    [int] $Transfers = 4,

    [ValidateRange(1, 64)]
    [int] $Checkers = 8,

    [string] $BandwidthLimit,

    [string] $LogFile,

    [switch] $AppendLog,

    [switch] $NoFileList,

    [switch] $NativeProgress,

    [switch] $StrictCompare,

    [pscredential] $SourceCredential,

    [string] $ClientId,

    [string] $ClientSecret,

    [string] $DriveId,

    [ValidateSet('documentLibrary', 'business', 'personal')]
    [string] $DriveType = 'documentLibrary',

    [string] $RclonePath,

    [switch] $UpdateRclone,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PinnedRcloneVersion = 'v1.75.2'
$script:LogWriter           = $null
$script:SuppressFileList    = [bool]$NoFileList

#region Helpers

function Get-Field {
    # Property lookup that tolerates absent properties under Set-StrictMode;
    # rclone's JSON log lines carry different fields per event type.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Format-Size {
    param([double] $Bytes)
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return '{0} B' -f [int64]$Bytes }
    return '{0:0.##} {1}' -f $Bytes, $units[$i]
}

function Format-Duration {
    param([TimeSpan] $Span)
    '{0}:{1:mm}:{1:ss}' -f [int][Math]::Floor($Span.TotalHours), $Span
}

function Write-Report {
    # One line to the console and, when -LogFile is set, to the log. File
    # lines are suppressed by -NoFileList; errors and the summary never are.
    param([string] $Text = '', [System.ConsoleColor] $Color, [switch] $FileLine)

    if ($FileLine -and $script:SuppressFileList) { return }
    if ($PSBoundParameters.ContainsKey('Color')) { Write-Host $Text -ForegroundColor $Color }
    else { Write-Host $Text }
    if ($script:LogWriter) { $script:LogWriter.WriteLine($Text) }
}

function Format-FileLine {
    param([string] $Kind, $Size, [string] $Name)
    $sizeText = if ($null -ne $Size) { Format-Size $Size } else { '' }
    '{0,14} {1,11}  {2}' -f $Kind, $sizeText, $Name
}

function ConvertTo-ArgumentString {
    <#
        Quotes an argument list for CreateProcess the way the MS C runtime (and
        Go, which rclone is written in) splits it back up: backslashes only
        need doubling when they precede a quote. ProcessStartInfo.ArgumentList
        would do this for us, but Windows PowerShell 5.1 does not have it.
    #>
    param([string[]] $Arguments)

    $quoted = foreach ($arg in $Arguments) {
        if ($arg -eq '') { '""'; continue }
        if ($arg -notmatch '[\s"]') { $arg; continue }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\' * ($slashes * 2 + 1)).Append('"')
            }
            else {
                [void]$sb.Append('\' * $slashes).Append($ch)
            }
            $slashes = 0
        }
        [void]$sb.Append('\' * ($slashes * 2)).Append('"')
        $sb.ToString()
    }
    $quoted -join ' '
}

function Invoke-Rclone {
    <#
        Runs rclone to completion and returns its exit code and output. With
        -Interactive, stderr stays on the console (the sign-in prompt and URL
        go there) and the process shares the console, so Ctrl+C reaches it.
    #>
    param(
        [Parameter(Mandatory)] [string] $Exe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $Interactive
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = -not $Interactive
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.RedirectStandardError  = -not $Interactive
    if (-not $Interactive) { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 }

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = if (-not $Interactive) { $proc.StandardError.ReadToEndAsync() } else { $null }
    $stdout  = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = if ($errTask) { $errTask.Result } else { '' }
    }
}

function Get-HttpStatus {
    # Status code of a failed Invoke-RestMethod, on both 5.1 (WebException)
    # and 7+ (HttpResponseException); 0 when there was no HTTP response.
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        try { return [int]$response.Value.StatusCode } catch { }
    }
    return 0
}

function Test-UrlPrefix {
    # True when $Url is $Prefix itself or a path below it - on a segment
    # boundary, so ".../Shared Documents" does not match ".../Shared Docs".
    param([string] $Prefix, [string] $Url)
    $p = $Prefix.TrimEnd('/')
    $Url.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
        $Url.StartsWith($p + '/', [StringComparison]::OrdinalIgnoreCase)
}

#endregion

#region SharePoint URL

function ConvertFrom-SharePointUrl {
    <#
        Reads tenant, host and the folder's server-relative path from a URL as
        copied out of the browser. The folder path comes from, in order: the
        ?id= (or legacy ?RootFolder=) parameter of a library view, the path of
        a /:f:/r/ link, or the plain URL path with any /Forms/<view>.aspx page
        stripped off.
    #>
    param([Parameter(Mandatory)] [string] $Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "Not a valid https URL: $Url"
    }

    $hostName = $uri.Host.ToLowerInvariant()
    if ($hostName -notmatch '^([a-z0-9][a-z0-9-]*?)(-my)?\.sharepoint\.com$') {
        throw "Not a SharePoint Online URL (expected <tenant>.sharepoint.com): $($uri.Host)"
    }
    $tenant = $Matches[1]

    $query = @{}
    foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $kv  = $pair.Split('=', 2)
        $key = [Uri]::UnescapeDataString($kv[0]).ToLowerInvariant()
        $query[$key] = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1].Replace('+', '%20')) } else { '' }
    }

    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    if ($path -match '^/:[a-z]+:/r(/.*)$') {
        # "People with existing access" link: the real path follows /r.
        $path = $Matches[1]
    }
    elseif ($path -match '^/:[a-z]+:/') {
        throw 'That is a sharing link, which does not contain the folder path. Open the folder in the browser and copy the address bar URL instead.'
    }

    $serverRelative =
        if     ($query['id'])                         { $query['id'] }
        elseif ($query['rootfolder'])                 { $query['rootfolder'] }
        elseif ($path -match '(?i)^(.*?)/Forms/[^/]+\.aspx$') { $Matches[1] }
        elseif ($path -match '(?i)\.aspx$')           { throw "The URL points at a page, not a document library folder: $Url" }
        else                                          { $path }

    $serverRelative = '/' + $serverRelative.Trim('/')
    if ($serverRelative -eq '/') { throw 'The URL points at the site root, not a document library or folder.' }

    [pscustomobject]@{
        Tenant             = $tenant
        Host               = $hostName
        ServerRelativePath = $serverRelative
        FolderUrl          = "https://$hostName$serverRelative"
    }
}

function Split-LibraryPath {
    # Best guess at site / library / folder without asking Graph, used only
    # with -DriveId: /sites|teams|personal/<name> is the site, the next
    # segment the library. Subsites need the Graph lookup instead.
    param([string] $ServerRelativePath)

    $seg  = $ServerRelativePath.Trim('/').Split('/')
    $skip = if ($seg.Count -ge 3 -and $seg[0] -in 'sites', 'teams', 'personal') { 2 } else { 0 }
    if ($seg.Count -le $skip) { throw 'The URL does not include a document library.' }

    [pscustomobject]@{
        SitePath = if ($skip) { '/' + ($seg[0..($skip - 1)] -join '/') } else { '' }
        Library  = $seg[$skip]
        SubPath  = ($seg | Select-Object -Skip ($skip + 1)) -join '/'
    }
}

#endregion

#region rclone install and config

function Get-RcloneArch {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'ARM64' { 'arm64' }
        'x86'   { '386' }
        default { 'amd64' }
    }
}

function Get-RcloneVersion {
    param([Parameter(Mandatory)] [string] $Exe)
    $r = Invoke-Rclone -Exe $Exe -Arguments @('version')
    if ($r.StdOut -match 'rclone (v\d+\.\d+\.\d+\S*)') { return $Matches[1] }
    return 'unknown'
}

function Install-Rclone {
    <#
        Makes sure $BinDir\rclone.exe exists and returns its path. Downloads the
        pinned version when it is missing, or the latest release with -Update;
        an installed copy is otherwise left alone (never silently downgraded).
        Every download is checked against the release's SHA256SUMS.
    #>
    param(
        [Parameter(Mandatory)] [string] $BinDir,
        [Parameter(Mandatory)] [string] $PinnedVersion,
        [switch] $Update
    )

    $exe = Join-Path $BinDir 'rclone.exe'

    # Windows PowerShell 5.1 still defaults to TLS 1.0/1.1 on older systems.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $want = $null
    if ($Update) {
        $latest = [string](Invoke-RestMethod -Uri 'https://downloads.rclone.org/version.txt' -UseBasicParsing)
        $want = ($latest.Trim() -split '\s+')[-1]
    }
    elseif (-not (Test-Path -LiteralPath $exe)) {
        $want = $PinnedVersion
    }
    if (-not $want) { return $exe }
    if ((Test-Path -LiteralPath $exe) -and (Get-RcloneVersion -Exe $exe) -eq $want) { return $exe }

    $zipName = "rclone-$want-windows-$(Get-RcloneArch).zip"
    $baseUrl = "https://downloads.rclone.org/$want"
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('Copy-ToSharePoint-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    Write-Host "Downloading rclone $want ($zipName)..." -ForegroundColor Cyan
    $savedProgress = $ProgressPreference
    try {
        # The download progress bar slows Invoke-WebRequest to a crawl on 5.1.
        $ProgressPreference = 'SilentlyContinue'
        $zipPath = Join-Path $tempDir $zipName
        Invoke-WebRequest -Uri "$baseUrl/$zipName" -OutFile $zipPath -UseBasicParsing

        $sums = [string](Invoke-RestMethod -Uri "$baseUrl/SHA256SUMS" -UseBasicParsing)
        $line = $sums -split "`n" | Where-Object { $_ -match ('^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($zipName) + '\s*$') } | Select-Object -First 1
        if (-not $line) { throw "$zipName is not listed in the release's SHA256SUMS." }
        $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
        $actual   = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "Checksum mismatch for $zipName (expected $expected, got $actual)." }

        Expand-Archive -LiteralPath $zipPath -DestinationPath (Join-Path $tempDir 'x') -Force
        $found = Get-ChildItem -LiteralPath (Join-Path $tempDir 'x') -Recurse -Filter 'rclone.exe' | Select-Object -First 1
        if (-not $found) { throw "rclone.exe not found in $zipName." }

        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
        Copy-Item -LiteralPath $found.FullName -Destination $exe -Force
    }
    finally {
        $ProgressPreference = $savedProgress
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $exe
}

function Read-RcloneRemote {
    # The key/value pairs of one [remote] section of an rclone config file,
    # or $null when the section does not exist.
    param([string] $ConfigPath, [string] $Remote)

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $section = $null
    $values  = @{}
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($section -eq $Remote) { break }
            $section = $Matches[1]
            continue
        }
        if ($section -eq $Remote -and $line -match '^\s*([^=#;]+?)\s*=\s*(.*)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    if ($section -eq $Remote -or $values.Count) { return $values }
    return $null
}

function ConvertTo-TokenJson {
    <#
        Normalizes what rclone authorize hands back into a token JSON string
        ({"access_token":...}). Depending on the rclone version that is the
        token itself, or a base64 blob wrapping {"token":"<token json>"}.
    #>
    param([Parameter(Mandatory)] [string] $Blob)

    $text = $Blob.Trim()
    if (-not $text.StartsWith('{')) {
        $b64 = $text.Replace('-', '+').Replace('_', '/')
        $b64 = $b64.PadRight($b64.Length + (4 - $b64.Length % 4) % 4, '=')
        try { $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
        catch { throw 'Unrecognized output from rclone authorize.' }
    }

    $obj = $text | ConvertFrom-Json
    if (Get-Field $obj 'access_token') { return $text }
    $inner = Get-Field $obj 'token'
    if ($inner -is [string]) { return ConvertTo-TokenJson -Blob $inner }
    if ($inner) { return ($inner | ConvertTo-Json -Compress) }
    throw 'rclone authorize did not return a token.'
}

function Invoke-RcloneAuthorize {
    # Browser sign-in for OneDrive/SharePoint; returns the token JSON.
    param(
        [Parameter(Mandatory)] [string] $Exe,
        [string] $ClientId,
        [string] $ClientSecret
    )

    $arguments = @('authorize', 'onedrive')
    if ($ClientId) { $arguments += $ClientId, $(if ($ClientSecret) { $ClientSecret } else { '' }) }

    $r = Invoke-Rclone -Exe $Exe -Arguments $arguments -Interactive
    if ($r.ExitCode -ne 0) { throw "Sign-in failed or was cancelled (rclone authorize exit code $($r.ExitCode))." }
    if ($r.StdOut -notmatch '(?s)--->\s*(.+?)\s*<---End paste') { throw 'Could not read the token from the rclone authorize output.' }
    ConvertTo-TokenJson -Blob $Matches[1]
}

function Get-RemoteToken {
    param([string] $ConfigPath, [string] $Remote)
    $section = Read-RcloneRemote -ConfigPath $ConfigPath -Remote $Remote
    if (-not $section -or -not $section['token']) { return $null }
    try { return ($section['token'] | ConvertFrom-Json) } catch { return $null }
}

function Test-TokenFresh {
    # True when the token's access token is valid for at least five minutes.
    param($Token)

    if (-not $Token -or -not (Get-Field $Token 'access_token')) { return $false }
    $expiry = Get-Field $Token 'expiry'
    if (-not $expiry) { return $false }

    # PowerShell 7's ConvertFrom-Json already turns the timestamp into a DateTime.
    if ($expiry -is [datetime]) { return ([DateTimeOffset]$expiry) -gt [DateTimeOffset]::Now.AddMinutes(5) }

    # Go writes nanoseconds; .NET parses at most seven fractional digits.
    $text = ([string]$expiry) -replace '(\.\d{7})\d+', '$1'
    $when = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
                                         [Globalization.DateTimeStyles]::None, [ref]$when)) { return $false }
    return $when -gt [DateTimeOffset]::Now.AddMinutes(5)
}

function Get-GraphAccessToken {
    <#
        A Microsoft Graph access token for the tenant remote. rclone refreshes
        an expired access token whenever it uses the remote and writes the new
        one back to the config, so one cheap call (about) is enough; only when
        the refresh token itself has expired does the user sign in again.
    #>
    param(
        [string] $Exe, [string] $ConfigPath, [string] $Remote,
        [string] $ClientId, [string] $ClientSecret
    )

    $token = Get-RemoteToken -ConfigPath $ConfigPath -Remote $Remote
    if (Test-TokenFresh $token) { return $token.access_token }

    $null = Invoke-Rclone -Exe $Exe -Arguments @('about', "${Remote}:", '--config', $ConfigPath)
    $token = Get-RemoteToken -ConfigPath $ConfigPath -Remote $Remote
    if (Test-TokenFresh $token) { return $token.access_token }

    Write-Host "The saved sign-in for '$Remote' has expired - opening the browser to sign in again..." -ForegroundColor Cyan
    $json = Invoke-RcloneAuthorize -Exe $Exe -ClientId $ClientId -ClientSecret $ClientSecret
    $null = Invoke-Rclone -Exe $Exe -Arguments @('config', 'update', $Remote, 'token', $json, '--non-interactive', '--config', $ConfigPath)
    return ($json | ConvertFrom-Json).access_token
}

function New-RcloneRemote {
    param(
        [string] $Exe, [string] $ConfigPath, [string] $Remote, [string] $TokenJson,
        $Drive, [string] $ClientId, [string] $ClientSecret
    )

    $arguments = @('config', 'create', $Remote, 'onedrive',
                   'token', $TokenJson, 'drive_id', $Drive.Id, 'drive_type', $Drive.Type)
    if ($ClientId)     { $arguments += 'client_id', $ClientId }
    if ($ClientSecret) { $arguments += 'client_secret', $ClientSecret }
    $arguments += '--non-interactive', '--config', $ConfigPath

    # --non-interactive saves the given values, then prints the next (optional)
    # wizard question on stdout; the remote is usable once the section exists.
    $r = Invoke-Rclone -Exe $Exe -Arguments $arguments
    if (-not (Read-RcloneRemote -ConfigPath $ConfigPath -Remote $Remote)) {
        throw "rclone could not save the remote '$Remote': $($r.StdErr.Trim())"
    }
}

#endregion

#region Document library lookup

function Read-DriveCache {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $data = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
        # Piping unrolls the array; 5.1's ConvertFrom-Json would emit it whole.
        $data | ForEach-Object { $_ }
    }
    catch { }
}

function New-DriveInfo {
    param($Entry, [string] $FolderUrl)
    [pscustomobject]@{
        Id      = $Entry.id
        Type    = $Entry.type
        Name    = $Entry.name
        WebUrl  = $Entry.webUrl
        SubPath = $FolderUrl.Substring($Entry.webUrl.TrimEnd('/').Length).Trim('/')
    }
}

function Resolve-SharePointDrive {
    <#
        Finds the document library (Graph drive) that contains the target
        folder by matching each drive's webUrl against the folder URL - the
        URL path, not the display name, which is localized ("Dokument" vs
        "Shared Documents"). Candidate sites are tried shortest path first,
        which also finds libraries on subsites. Results are cached, so Graph
        is only asked once per library.
    #>
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [scriptblock] $GetToken,
        [Parameter(Mandatory)] [string] $CachePath
    )

    $folder = $Target.FolderUrl
    $cache  = @(Read-DriveCache -Path $CachePath)
    $hit = $cache |
        Where-Object { Test-UrlPrefix -Prefix $_.webUrl -Url $folder } |
        Sort-Object { $_.webUrl.Length } -Descending |
        Select-Object -First 1
    if ($hit) { return New-DriveInfo -Entry $hit -FolderUrl $folder }

    $headers = @{ Authorization = 'Bearer ' + (& $GetToken) }
    $graph   = 'https://graph.microsoft.com/v1.0'

    $seg = $Target.ServerRelativePath.Trim('/').Split('/')
    $candidates = New-Object System.Collections.Generic.List[string]
    $first = 1
    if ($seg[0] -in 'sites', 'teams', 'personal') { $first = 2 } else { $candidates.Add('') }
    for ($depth = $first; $depth -lt $seg.Count -and $candidates.Count -lt 6; $depth++) {
        $candidates.Add('/' + ($seg[0..($depth - 1)] -join '/'))
    }

    foreach ($sitePath in $candidates) {
        $siteUri = if ($sitePath) {
            $escaped = ($sitePath.Trim('/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            "$graph/sites/$($Target.Host):/$escaped"
        } else { "$graph/sites/$($Target.Host)" }

        try {
            $site = Invoke-RestMethod -Uri $siteUri -Headers $headers -UseBasicParsing
        }
        catch {
            switch (Get-HttpStatus $_) {
                { $_ -in 400, 404 } { continue }
                401 { throw 'Microsoft Graph rejected the sign-in (401). Run again to sign in anew, or delete the remote from the config file.' }
                403 { throw "Access denied (403) to site '$sitePath'. The signed-in account needs access to it - or the tenant blocks the rclone app; then use -ClientId/-ClientSecret." }
                default { throw }
            }
            continue
        }

        $drives = Invoke-RestMethod -Uri ("$graph/sites/{0}/drives?`$select=id,name,driveType,webUrl" -f $site.id) -Headers $headers -UseBasicParsing
        $best = $null
        foreach ($d in @($drives.value)) {
            $web = [Uri]::UnescapeDataString([string]$d.webUrl).TrimEnd('/')
            if ((Test-UrlPrefix -Prefix $web -Url $folder) -and (-not $best -or $web.Length -gt $best.webUrl.Length)) {
                $best = [pscustomobject]@{ webUrl = $web; id = $d.id; type = $d.driveType; name = $d.name }
            }
        }
        if ($best) {
            $updated = @($cache | Where-Object { $_.webUrl -ne $best.webUrl }) + $best
            Set-Content -LiteralPath $CachePath -Value (ConvertTo-Json -InputObject @($updated) -Depth 3) -Encoding UTF8
            return New-DriveInfo -Entry $best -FolderUrl $folder
        }
    }

    throw "No document library on $($Target.Host) matches $folder. Check the URL, or pass -DriveId."
}

#endregion

#region Source share

function Connect-SourceShare {
    <#
        Connects \\server\share with explicit credentials for the run, through
        WNetAddConnection2 rather than "net use" so the password never appears
        on a command line. Returns the share root to disconnect afterwards, or
        $null when there is nothing to undo.
    #>
    param([string] $Path, [pscredential] $Credential)

    if ($Path -notmatch '^\\\\([^\\]+)\\([^\\]+)') {
        Write-Warning '-SourceCredential only applies to UNC sources (\\server\share\...); ignored.'
        return $null
    }
    $root = "\\$($Matches[1])\$($Matches[2])"

    if (-not ('CopyToSharePoint.WNet' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CopyToSharePoint {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class NetResource {
        public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage;
        public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider;
    }
    public static class WNet {
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        public static extern int WNetAddConnection2(NetResource netResource, string password, string username, int flags);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        public static extern int WNetCancelConnection2(string name, int flags, bool force);
    }
}
'@
    }

    $resource = New-Object CopyToSharePoint.NetResource
    $resource.dwType       = 1   # RESOURCETYPE_DISK
    $resource.lpRemoteName = $root
    $net  = $Credential.GetNetworkCredential()
    $user = if ($net.Domain) { "$($net.Domain)\$($net.UserName)" } else { $net.UserName }

    $rc = [CopyToSharePoint.WNet]::WNetAddConnection2($resource, $net.Password, $user, 0)
    switch ($rc) {
        0    { return $root }
        1219 {
            Write-Warning "Already connected to $root with other credentials; using that connection."
            return $null
        }
        default {
            $reason = (New-Object System.ComponentModel.Win32Exception $rc).Message
            throw "Could not connect to $root with the given credentials: $reason ($rc)"
        }
    }
}

function Disconnect-SourceShare {
    param([string] $Root)
    [void][CopyToSharePoint.WNet]::WNetCancelConnection2($Root, 0, $true)
}

#endregion

#region Transfer

function Get-RcloneFilterArgs {
    # robocopy /XF and /XD semantics in rclone filter syntax: a bare name
    # matches at any depth, a full path below the source just that folder.
    param([string[]] $ExcludeFile, [string[]] $ExcludeDir, [string] $SourceRoot)

    foreach ($f in @($ExcludeFile)) {
        if ($f) { '--exclude'; $f.Replace('\', '/') }
    }
    foreach ($d in @($ExcludeDir)) {
        if (-not $d) { continue }
        if ([IO.Path]::IsPathRooted($d)) {
            $full = [IO.Path]::GetFullPath($d).TrimEnd('\')
            $root = $SourceRoot.TrimEnd('\')
            if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                '--exclude'; '/' + $full.Substring($root.Length + 1).Replace('\', '/') + '/**'
            }
            else { Write-Warning "-ExcludeDir '$d' is not below the source; ignored." }
        }
        else {
            '--exclude'; $d.Trim('\', '/').Replace('\', '/') + '/**'
        }
    }
}

function Invoke-RcloneTransfer {
    <#
        Runs rclone with --use-json-log and turns its event stream into a
        robocopy-style report: a Write-Progress bar fed by the 1 s stats, one
        line per copied, deleted or failed file, and per-file end states for
        the summary.

        rclone's --retries re-run the whole job, so the same file can show up
        once per attempt. The state is therefore kept per file: Copied sticks,
        Skipped (unchanged) beats an earlier Failed because the retry found the
        file intact, and Failed only counts when nothing better follows.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Exe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string]   $Activity
    )

    $state    = @{}   # file -> Copied | Skipped | Failed
    $sizes    = @{}   # file -> bytes, for copied files
    $extras   = 0
    $failures = New-Object System.Collections.Generic.List[string]

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc  = [System.Diagnostics.Process]::Start($psi)
    $null  = $proc.StandardOutput.ReadToEndAsync()   # drained only; rclone logs to stderr

    try {
        while ($null -ne ($line = $proc.StandardError.ReadLine())) {
            if (-not $line) { continue }
            if ($line[0] -ne '{') {
                # Not JSON: rclone failed before its logger started (bad flag, etc.).
                Write-Report $line -Color Red
                continue
            }
            # The DEBUG stream is mostly noise; only parse lines that matter.
            # "critical" is what rclone logs when it cannot even open the
            # destination (bad sign-in, no access) - the most important line.
            if ($line -notmatch '"stats":|"msg":"(Copied|Unchanged skipping|Deleted)|"skipped":|"level":"(critical|error|warning|notice)"') { continue }
            try { $entry = $line | ConvertFrom-Json } catch { continue }

            $stats = Get-Field $entry 'stats'
            if ($stats) {
                $bytes = [double](Get-Field $stats 'bytes')
                $total = [double](Get-Field $stats 'totalBytes')
                $eta   = Get-Field $stats 'eta'
                $pct   = if ($total -gt 0) { [int][Math]::Min(100, 100 * $bytes / $total) } else { 0 }

                $status = '{0}/{1} files | {2} of {3} | {4}/s | ETA {5}' -f
                    (Get-Field $stats 'transfers'), (Get-Field $stats 'totalTransfers'),
                    (Format-Size $bytes), (Format-Size $total),
                    (Format-Size ([double](Get-Field $stats 'speed'))),
                    $(if ($null -ne $eta) { Format-Duration ([TimeSpan]::FromSeconds([double]$eta)) } else { '-' })
                $totalChecks = [int64](Get-Field $stats 'totalChecks')
                if ($totalChecks -gt 0) { $status += ' | checked {0}/{1}' -f (Get-Field $stats 'checks'), $totalChecks }

                $progress = @{ Activity = $Activity; Status = $status; PercentComplete = $pct }
                $active = @(Get-Field $stats 'transferring')
                if ($active.Count -and $active[0]) {
                    $progress.CurrentOperation = ($active | Select-Object -First 3 |
                        ForEach-Object { '{0} ({1}%)' -f (Get-Field $_ 'name'), (Get-Field $_ 'percentage') }) -join ', '
                }
                Write-Progress @progress
                continue
            }

            $msg     = [string](Get-Field $entry 'msg')
            $file    = Get-Field $entry 'object'
            $level   = Get-Field $entry 'level'
            $size    = Get-Field $entry 'size'
            $skipped = Get-Field $entry 'skipped'

            if ($skipped) {
                # --dry-run reports what it would have done.
                if ($skipped -eq 'copy' -and $file) {
                    $state[$file] = 'Copied'; $sizes[$file] = [int64]$size
                    Write-Report (Format-FileLine '*Would copy' $size $file) -FileLine
                }
                elseif ($skipped -match 'delete' -and $file) {
                    $extras++
                    Write-Report (Format-FileLine '*Would delete' $null $file) -FileLine
                }
            }
            elseif ($msg -like 'Copied (*' -and $file) {
                $kind = if ($msg -like '*replaced*') { 'Newer' } else { 'New File' }
                $state[$file] = 'Copied'; $sizes[$file] = [int64]$size
                Write-Report (Format-FileLine $kind $size $file) -FileLine
            }
            elseif ($msg -eq 'Unchanged skipping' -and $file) {
                if ($state[$file] -ne 'Copied') { $state[$file] = 'Skipped' }
            }
            elseif ($msg -eq 'Deleted' -and $file) {
                $extras++
                Write-Report (Format-FileLine '*EXTRA File' $null $file) -FileLine
            }
            elseif ($level -in 'error', 'critical') {
                if ($file -and -not $state.ContainsKey($file)) { $state[$file] = 'Failed' }
                $text = if ($file) { '{0}: {1}' -f $file, $msg.Trim() } else { $msg.Trim() }
                $failures.Add($text)
                Write-Report ('{0,14} {1}' -f 'ERROR', $text) -Color Red
            }
            elseif ($level -in 'warning', 'notice') {
                Write-Report ('{0,14} {1}' -f $level.ToUpperInvariant(), $msg.Trim()) -Color Yellow
            }
        }
        $proc.WaitForExit()
    }
    finally {
        Write-Progress -Activity $Activity -Completed
        # Ctrl+C stops the script, not the child (it has no console of its own).
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    }
    $watch.Stop()

    $copiedBytes = [int64]0
    foreach ($key in $sizes.Keys) { if ($state[$key] -eq 'Copied') { $copiedBytes += $sizes[$key] } }

    [pscustomobject]@{
        ExitCode    = $proc.ExitCode
        Total       = $state.Count
        Copied      = @($state.Values | Where-Object { $_ -eq 'Copied' }).Count
        Skipped     = @($state.Values | Where-Object { $_ -eq 'Skipped' }).Count
        Failed      = @($state.Values | Where-Object { $_ -eq 'Failed' }).Count
        Extras      = $extras
        BytesCopied = $copiedBytes
        Elapsed     = $watch.Elapsed
        Errors      = $failures.ToArray()
    }
}

function Invoke-RcloneNative {
    # rclone with its own --progress display on the shared console.
    param([string] $Exe, [string[]] $Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $Exe
    $psi.Arguments       = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc  = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    [pscustomobject]@{ ExitCode = $proc.ExitCode; Elapsed = $watch.Elapsed }
}

function Write-Summary {
    param($Result, [switch] $DryRun)

    $rule = '-' * 79
    Write-Report $rule
    Write-Report ''
    Write-Report ('{0,12}{1,10}{2,10}{3,10}{4,10}{5,10}' -f '', 'Total', 'Copied', 'Skipped', 'FAILED', 'Extras')
    $filesLine = '{0,12}{1,10}{2,10}{3,10}{4,10}{5,10}' -f 'Files :', $Result.Total, $Result.Copied, $Result.Skipped, $Result.Failed, $Result.Extras
    if ($Result.Failed) { Write-Report $filesLine -Color Red } else { Write-Report $filesLine }
    Write-Report ('{0,12}{1,10}{2,10}' -f 'Bytes :', '', (Format-Size $Result.BytesCopied))
    Write-Report ('{0,12}  {1}' -f 'Times :', (Format-Duration $Result.Elapsed))
    $seconds = [Math]::Max(0.001, $Result.Elapsed.TotalSeconds)
    Write-Report ('{0,12}  {1}/s' -f 'Speed :', (Format-Size ($Result.BytesCopied / $seconds)))
    Write-Report ('{0,12}  {1}' -f 'Ended :', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($DryRun) { Write-Report ('{0,12}  {1}' -f 'Note :', 'dry run - "Copied" and "Extras" are what WOULD happen') -Color Yellow }
    if ($Result.ExitCode -ne 0) {
        Write-Report ('{0,12}  rclone exit code {1}' -f 'Result :', $Result.ExitCode) -Color Red
    }
    Write-Report ''
    Write-Report $rule
}

#endregion

#region Main

# -WhatIf means "rclone --dry-run". Capture it and clear it, or every file
# operation the script needs for itself (installing rclone, writing its
# config) would silently turn into a no-op as well.
$dryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false

$appDir = Join-Path $env:LOCALAPPDATA 'Copy-ToSharePoint'
$ConfigPath = if ($ConfigPath) { $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ConfigPath) }
              else { Join-Path $appDir 'rclone.conf' }
$configDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$cachePath = Join-Path $configDir 'drives.json'

# Parse the URL first: it is cheap and catches a bad paste before any download.
$target = ConvertFrom-SharePointUrl -Url $Url
$remote = if ($RemoteName) { $RemoteName } else { $target.Tenant }
if ($remote -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.+@-]*$') { throw "Invalid remote name '$remote'." }

$shareRoot = $null
$exitCode  = 0
try {
    if ($SourceCredential) { $shareRoot = Connect-SourceShare -Path $Source -Credential $SourceCredential }
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found or not accessible: $Source" }
    $sourceFull = (Resolve-Path -LiteralPath $Source).ProviderPath

    $rclone = if ($RclonePath) { (Resolve-Path -LiteralPath $RclonePath).ProviderPath }
              else { Install-Rclone -BinDir (Join-Path $appDir 'bin') -PinnedVersion $script:PinnedRcloneVersion -Update:$UpdateRclone }
    $rcloneVersion = Get-RcloneVersion -Exe $rclone

    # One sign-in per tenant. A new tenant gets its token first, because the
    # library lookup needs it before the remote can be saved.
    $section   = Read-RcloneRemote -ConfigPath $ConfigPath -Remote $remote
    $tokenJson = $null
    if ($section -and $SignIn) {
        Write-Host "Signing in to tenant '$($target.Tenant)' again (-SignIn) - opening the browser..." -ForegroundColor Cyan
        $fresh = Invoke-RcloneAuthorize -Exe $rclone -ClientId $ClientId -ClientSecret $ClientSecret
        $null  = Invoke-Rclone -Exe $rclone -Arguments @('config', 'update', $remote, 'token', $fresh, '--non-interactive', '--config', $ConfigPath)
    }
    if ($section) {
        $getToken = {
            Get-GraphAccessToken -Exe $rclone -ConfigPath $ConfigPath -Remote $remote -ClientId $ClientId -ClientSecret $ClientSecret
        }.GetNewClosure()
    }
    else {
        Write-Host "No saved sign-in for tenant '$($target.Tenant)' - opening the browser for a Microsoft 365 sign-in..." -ForegroundColor Cyan
        $tokenJson   = Invoke-RcloneAuthorize -Exe $rclone -ClientId $ClientId -ClientSecret $ClientSecret
        $accessToken = ($tokenJson | ConvertFrom-Json).access_token
        $getToken    = { $accessToken }.GetNewClosure()
    }

    $drive = if ($DriveId) {
        $split = Split-LibraryPath -ServerRelativePath $target.ServerRelativePath
        [pscustomobject]@{
            Id = $DriveId; Type = $DriveType; Name = $split.Library
            WebUrl = "https://$($target.Host)$($split.SitePath)/$($split.Library)"; SubPath = $split.SubPath
        }
    }
    else { Resolve-SharePointDrive -Target $target -GetToken $getToken -CachePath $cachePath }

    if (-not $section) {
        New-RcloneRemote -Exe $rclone -ConfigPath $ConfigPath -Remote $remote -TokenJson $tokenJson `
                         -Drive $drive -ClientId $ClientId -ClientSecret $ClientSecret
    }

    $dest = "${remote}:$($drive.SubPath)"
    $verb = if ($Mirror) { 'sync' } else { 'copy' }

    $rcArgs = New-Object System.Collections.Generic.List[string]
    $rcArgs.AddRange([string[]]@(
        $verb, $sourceFull, $dest,
        '--config', $ConfigPath,
        # The tenant remote holds the sign-in; the library is chosen per run.
        '--onedrive-drive-id', $drive.Id,
        '--onedrive-drive-type', $drive.Type,
        '--retries', [string]$Retries,
        '--retries-sleep', "$($RetryWaitSeconds)s",
        '--transfers', [string]$Transfers,
        '--checkers', [string]$Checkers,
        '--create-empty-src-dirs',
        # Microsoft throttles SharePoint traffic that identifies itself less hard.
        '--user-agent', "ISV|rclone.org|rclone/$rcloneVersion"))
    $compare = 'size, modtime, checksum'
    if ($drive.Type -eq 'documentLibrary' -and -not $StrictCompare) {
        $rcArgs.AddRange([string[]]@('--ignore-size', '--ignore-checksum'))
        $compare = 'modtime (SharePoint rewrites Office files; -StrictCompare to change)'
    }
    if ($BandwidthLimit) { $rcArgs.AddRange([string[]]@('--bwlimit', $BandwidthLimit)) }
    $rcArgs.AddRange([string[]]@(Get-RcloneFilterArgs -ExcludeFile $ExcludeFile -ExcludeDir $ExcludeDir -SourceRoot $sourceFull))
    if ($dryRun) { $rcArgs.Add('--dry-run') }

    $logPath = if ($LogFile) { $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LogFile) } else { $null }
    if ($NativeProgress) {
        $rcArgs.Add('--progress')
        if (-not $NoFileList) { $rcArgs.Add('-v') }
        if ($logPath) { $rcArgs.AddRange([string[]]@('--log-file', $logPath)) }
    }
    else {
        $rcArgs.AddRange([string[]]@('--use-json-log', '--log-level', 'DEBUG', '--stats', '1s'))
        if ($logPath) {
            $logDir = Split-Path -Parent $logPath
            if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $script:LogWriter = New-Object System.IO.StreamWriter($logPath, [bool]$AppendLog, (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    $proceed = $true
    if ($Mirror -and -not $dryRun -and -not $Force) {
        try {
            $proceed = $PSCmdlet.ShouldContinue(
                "Mirror DELETES files in '$($target.FolderUrl)' that do not exist in '$sourceFull'. Continue? (Use -WhatIf to preview, -Force to skip this question.)",
                'Confirm mirror')
        }
        catch {
            # No console to ask on (RMM, scheduled task, -NonInteractive).
            throw '-Mirror asks for confirmation before deleting anything. Add -Force to run it unattended.'
        }
        if (-not $proceed) { Write-Warning 'Mirror cancelled.'; $exitCode = 1 }
    }

    if ($proceed) {
        $rule = '-' * 79
        $excluded = @(@($ExcludeFile) + @($ExcludeDir | ForEach-Object { if ($_) { "$_\" } }) | Where-Object { $_ })
        Write-Report $rule
        Write-Report "   Copy-ToSharePoint  ::  rclone $rcloneVersion  ::  $verb"
        Write-Report $rule
        Write-Report ''
        Write-Report ('{0,10} : {1}' -f 'Started', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Write-Report ('{0,10} : {1}' -f 'Source', $sourceFull)
        Write-Report ('{0,10} : {1}' -f 'Dest', $target.FolderUrl)
        Write-Report ('{0,10} : {1}   (library "{2}", {3})' -f 'Remote', $dest, $drive.Name, $drive.Type)
        Write-Report ('{0,10} : retries {1} (wait {2}s), transfers {3}, checkers {4}' -f 'Options', $Retries, $RetryWaitSeconds, $Transfers, $Checkers)
        Write-Report ('{0,10} : {1}' -f 'Compare', $compare)
        if ($excluded.Count) { Write-Report ('{0,10} : {1}' -f 'Exclude', ($excluded -join ', ')) }
        if ($BandwidthLimit) { Write-Report ('{0,10} : {1}/s' -f 'Bandwidth', $BandwidthLimit) }
        if ($dryRun) { Write-Report ('{0,10} : {1}' -f 'Mode', 'DRY RUN (-WhatIf) - nothing is changed') -Color Yellow }
        if ($Mirror) { Write-Report ('{0,10} : {1}' -f 'Mirror', 'files missing in the source are deleted in the destination') -Color Yellow }
        Write-Report ''
        Write-Report $rule
        Write-Report ''

        Write-Verbose ("rclone " + (ConvertTo-ArgumentString $rcArgs.ToArray()))
        $activity = "Copy-ToSharePoint: $sourceFull -> $dest"

        if ($NativeProgress) {
            $native = Invoke-RcloneNative -Exe $rclone -Arguments $rcArgs.ToArray()
            $exitCode = $native.ExitCode
            Write-Host ''
            Write-Host ('{0,12}  {1}' -f 'Times :', (Format-Duration $native.Elapsed))
            if ($exitCode -ne 0) { Write-Host ('{0,12}  rclone exit code {1}' -f 'Result :', $exitCode) -ForegroundColor Red }
            $result = $native
        }
        else {
            $result = Invoke-RcloneTransfer -Exe $rclone -Arguments $rcArgs.ToArray() -Activity $activity
            $exitCode = $result.ExitCode
            Write-Report ''
            Write-Summary -Result $result -DryRun:$dryRun

            # Graph's own wording for these is not much help; say what to do.
            if ($result.Errors -match 'InvalidAuthenticationToken|unauthenticated|invalid_grant|\b401\b') {
                Write-Report "Hint: the saved sign-in for '$remote' is no longer valid (it expires after about 90 days unused). Run again with -SignIn." -Color Yellow
            }
            elseif ($result.Errors -match 'accessDenied|\b403\b') {
                Write-Report "Hint: the signed-in account has no write access to this library, or the tenant blocks the rclone app (then use -ClientId/-ClientSecret)." -Color Yellow
            }
        }

        if ($PassThru) {
            $result | Add-Member -NotePropertyName Source      -NotePropertyValue $sourceFull -PassThru |
                      Add-Member -NotePropertyName Destination -NotePropertyValue $target.FolderUrl -PassThru |
                      Add-Member -NotePropertyName Remote      -NotePropertyValue $dest -PassThru |
                      Add-Member -NotePropertyName DryRun      -NotePropertyValue $dryRun -PassThru
        }
    }
}
finally {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
    if ($shareRoot) { Disconnect-SourceShare -Root $shareRoot }
}

exit $exitCode

#endregion
