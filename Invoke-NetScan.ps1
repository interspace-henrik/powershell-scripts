#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers hosts on a subnet or IP range using ICMP, the ARP/neighbor cache,
    optional TCP probing, reverse DNS and IEEE OUI vendor lookup.

.DESCRIPTION
    Produces one object per discovered host with IPAddress, MACAddress, HostName,
    Vendor, Method and ResponseTimeMs. By default it renders these as a table and
    prints a summary line (total hosts, how many with a MAC). Use -PassThru to
    emit the objects to the pipeline instead (for capture/piping); -CsvPath writes
    a CSV file regardless.

    Discovery order:
      1. ICMP sweep (parallel, throttled)
      2. Read the ARP/neighbor cache afterwards - a host that blocks ICMP but is
         L2-adjacent still shows up here, because the ping forced an ARP request.
      3. On-link subnets: a source-bound ARP sweep (SendARP) resolves each host's
         MAC directly over L2, so hosts stay discoverable with their MAC even when
         a lower-metric tunnel route (e.g. Tailscale) would send the ICMP astray.
         See -SourceAddress / -SkipArpSweep.
      4. Optional TCP connect scan (-Port / -PortSet).
      5. Names + vendor lookup for everything found: reverse DNS first, then a
         NetBIOS (UDP 137) and mDNS (UDP 5353) fallback for hosts with no PTR
         record. See -SkipNameProbe.

.PARAMETER Slow
    Rate-limits the scan so it does not look like a burst sweep to IDS/autoblock
    systems, and maximizes reliability. Equivalent to -Throttle 1 -IcmpThrottle 1
    -IcmpRetries 3 -DelayMs 250 -TimeoutMs 1000 -NeighborSettleMs 500
    -PortTimeoutMs 1500.

.PARAMETER PortScope
    Discovered (default) = probe ports only on hosts already found via ICMP/ARP.
    All = probe every address in the range, which also discovers hosts that are
    silent on both ICMP and ARP. Considerably noisier.

.EXAMPLE
    .\Invoke-NetScan.ps1 -Subnet 192.168.10.0/24 -Slow

.EXAMPLE
    .\Invoke-NetScan.ps1 -Subnet 192.168.10.0/24 -PortSet Common -CsvPath .\scan.csv

.EXAMPLE
    .\Invoke-NetScan.ps1 -StartIP 10.0.0.1 -EndIP 10.0.0.99 -Port 22,80,443,3389 -PortScope All

.EXAMPLE
    .\Invoke-NetScan.ps1 -ArpOnly
    Passive: reads the local neighbor cache only, sends nothing.
#>
[CmdletBinding(DefaultParameterSetName = 'Subnet')]
param(
    # CIDR notation, e.g. 192.168.1.0/24
    [Parameter(Mandatory, ParameterSetName = 'Subnet', Position = 0)]
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$')]
    [string]$Subnet,

    [Parameter(Mandatory, ParameterSetName = 'Range')]
    [ipaddress]$StartIP,

    [Parameter(Mandatory, ParameterSetName = 'Range')]
    [ipaddress]$EndIP,

    # Passive mode: no packets are sent, the local neighbor cache is dumped as-is.
    [Parameter(Mandatory, ParameterSetName = 'ArpOnly')]
    [switch]$ArpOnly,

    # Number of concurrent probes per batch. Governs the TCP scan; the ICMP sweep
    # uses -IcmpThrottle instead.
    [ValidateRange(1, 512)]
    [int]$Throttle = 32,

    # Concurrency for the ICMP sweep. The .NET async ping drops replies from live
    # hosts under high concurrency, so this defaults much lower than -Throttle.
    # Raise it for speed at the cost of missed hosts; lower it (or use -Slow) for
    # reliability. 3 was the most reliable default in testing.
    [ValidateRange(1, 512)]
    [int]$IcmpThrottle = 3,

    # ICMP attempts per host, like ping -n. A host counts as alive on its first
    # reply and only non-responders are retried, so live hosts still cost a single
    # probe. Compensates for replies lost to async-ping concurrency. With the low
    # default -IcmpThrottle a single pass already resolves reliably; raise it if
    # hosts intermittently show ARP-only.
    [ValidateRange(1, 10)]
    [Alias('Count')]
    [int]$IcmpRetries = 1,

    # Pause between batches, in milliseconds.
    [ValidateRange(0, 60000)]
    [int]$DelayMs = 0,

    [ValidateRange(50, 20000)]
    [int]$TimeoutMs = 500,

    # Pause before re-reading the neighbor cache, letting ARP resolutions that
    # were still Incomplete at the first read settle so their MAC is captured.
    # 0 disables the second read.
    [ValidateRange(0, 10000)]
    [int]$NeighborSettleMs = 300,

    [switch]$Slow,

    # Randomize probe order - sequential sweeps are easier for an IDS to fingerprint.
    [switch]$Shuffle,

    # Local source IP to bind ARP resolution to. Auto-detected from the target
    # subnet when omitted. Forces the ARP request out the physical interface even
    # when a lower-metric route (e.g. a Tailscale/VPN subnet router advertising the
    # same prefix) would otherwise capture the traffic and hide the MAC.
    [ipaddress]$SourceAddress,

    # Skip the source-bound ARP sweep that resolves MACs directly over L2 for
    # on-link subnets. The sweep adds time on large ranges (a silent host costs the
    # full ARP retry), so this trades MAC coverage for speed.
    [switch]$SkipArpSweep,

    # TCP ports to test. Combined with any ports from -PortSet.
    [Alias('TcpPort')]
    [int[]]$Port,

    # Named port collections, see $PortSetTable below.
    [ValidateSet('Common', 'Web', 'Windows', 'Remote', 'Printer', 'IoT')]
    [string[]]$PortSet,

    [ValidateSet('Discovered', 'All')]
    [string]$PortScope = 'Discovered',

    # TCP connect timeout. A filtered port consumes the full timeout, so this
    # dominates the runtime of a port scan.
    [ValidateRange(50, 20000)]
    [int]$PortTimeoutMs = 800,

    [switch]$SkipDns,

    [ValidateRange(50, 10000)]
    [int]$DnsTimeoutMs = 800,

    # When reverse DNS returns no name, fall back to a NetBIOS node-status query
    # (UDP 137, catches Windows/SMB/NAS) and an mDNS reverse-PTR query (UDP 5353,
    # catches Apple/IoT/printers/avahi). Disable with -SkipNameProbe.
    [switch]$SkipNameProbe,

    [ValidateRange(50, 5000)]
    [int]$NameProbeTimeoutMs = 500,

    [switch]$NoVendorLookup,

    # Force a re-download of the IEEE OUI database.
    [switch]$UpdateOuiDatabase,

    [string]$OuiPath,

    [string]$CsvPath,

    # Use ';' for Swedish Excel locales.
    [string]$CsvDelimiter = ',',

    # Emit the result objects to the pipeline (for capture/piping) instead of the
    # default human display - a rendered table followed by a summary line.
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SendARP (iphlpapi) resolves an IP to a MAC with a real ARP request on the local
# link. Bound to a source IP it leaves the physical interface regardless of the
# routing table, which is how on-link hosts stay discoverable (with their MAC)
# when a lower-metric tunnel route would otherwise capture the traffic.
$script:CanArp = ($env:OS -eq 'Windows_NT')
if ($script:CanArp -and -not ('NetScanArp' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NetScanArp {
    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    public static extern int SendARP(uint DestIP, uint SrcIP, byte[] pMacAddr, ref int PhyAddrLen);
}
'@
    }
    catch { $script:CanArp = $false }
}

# --- Preset ------------------------------------------------------------------

if ($Slow) {
    if (-not $PSBoundParameters.ContainsKey('Throttle'))         { $Throttle         = 1 }
    if (-not $PSBoundParameters.ContainsKey('IcmpThrottle'))     { $IcmpThrottle     = 1 }
    if (-not $PSBoundParameters.ContainsKey('IcmpRetries'))      { $IcmpRetries      = 3 }
    if (-not $PSBoundParameters.ContainsKey('DelayMs'))          { $DelayMs          = 250 }
    if (-not $PSBoundParameters.ContainsKey('TimeoutMs'))        { $TimeoutMs        = 1000 }
    if (-not $PSBoundParameters.ContainsKey('NeighborSettleMs')) { $NeighborSettleMs = 500 }
    if (-not $PSBoundParameters.ContainsKey('PortTimeoutMs'))    { $PortTimeoutMs    = 1500 }
}

$PortSetTable = @{
    Common  = @(21, 22, 23, 25, 53, 80, 110, 139, 143, 443, 445, 515, 631, 993, 995,
                1723, 3306, 3389, 5900, 8080, 8443, 9100)
    Web     = @(80, 443, 8000, 8008, 8080, 8443, 8888)
    Windows = @(135, 139, 445, 3389, 5985, 5986)
    Remote  = @(22, 23, 3389, 5900, 5985)
    Printer = @(515, 631, 9100)
    IoT     = @(80, 443, 554, 1883, 8080, 8883, 8888, 9999)
}

$ServiceLabel = @{
    21 = 'ftp'; 22 = 'ssh'; 23 = 'telnet'; 25 = 'smtp'; 53 = 'dns'; 80 = 'http'
    110 = 'pop3'; 135 = 'msrpc'; 139 = 'netbios'; 143 = 'imap'; 443 = 'https'
    445 = 'smb'; 515 = 'lpd'; 554 = 'rtsp'; 631 = 'ipp'; 993 = 'imaps'; 995 = 'pop3s'
    1723 = 'pptp'; 1883 = 'mqtt'; 3306 = 'mysql'; 3389 = 'rdp'; 5900 = 'vnc'
    5985 = 'winrm'; 5986 = 'winrm-tls'; 8080 = 'http-alt'; 8443 = 'https-alt'
    8883 = 'mqtts'; 9100 = 'jetdirect'
}

# Table view for the NetScan.Host output type. Registered below so the 7-column
# result renders as a table; PowerShell otherwise falls back to a list for any
# object with more than four properties. The objects themselves are unchanged.
$NetScanFormatXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Configuration>
  <ViewDefinitions>
    <View>
      <Name>NetScan.Host</Name>
      <ViewSelectedBy><TypeName>NetScan.Host</TypeName></ViewSelectedBy>
      <TableControl>
        <TableHeaders>
          <TableColumnHeader><Label>IPAddress</Label><Width>15</Width></TableColumnHeader>
          <TableColumnHeader><Label>MACAddress</Label><Width>17</Width></TableColumnHeader>
          <TableColumnHeader><Label>HostName</Label></TableColumnHeader>
          <TableColumnHeader><Label>Vendor</Label></TableColumnHeader>
          <TableColumnHeader><Label>OpenPorts</Label></TableColumnHeader>
          <TableColumnHeader><Label>Method</Label><Width>12</Width></TableColumnHeader>
          <TableColumnHeader><Label>ms</Label><Width>5</Width><Alignment>Right</Alignment></TableColumnHeader>
        </TableHeaders>
        <TableRowEntries>
          <TableRowEntry>
            <TableColumnItems>
              <TableColumnItem><PropertyName>IPAddress</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>MACAddress</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>HostName</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>Vendor</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>OpenPorts</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>Method</PropertyName></TableColumnItem>
              <TableColumnItem><PropertyName>ResponseTimeMs</PropertyName></TableColumnItem>
            </TableColumnItems>
          </TableRowEntry>
        </TableRowEntries>
      </TableControl>
    </View>
  </ViewDefinitions>
</Configuration>
'@

if ($PortSet) {
    foreach ($name in $PortSet) { $Port = @($Port) + $PortSetTable[$name] }
}
$Port = @($Port | Where-Object { $_ } | Sort-Object -Unique)

if (-not $OuiPath) {
    $cacheRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
    $OuiPath = Join-Path (Join-Path $cacheRoot 'NetScan') 'oui.csv'
}

# --- Helpers -----------------------------------------------------------------

function ConvertTo-UInt32Address {
    param([ipaddress]$Address)
    $bytes = $Address.GetAddressBytes()
    [Array]::Reverse($bytes)
    [System.BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-UInt32Address {
    param([uint32]$Value)
    $bytes = [System.BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    ([System.Net.IPAddress]::new($bytes)).IPAddressToString
}

function Expand-TargetRange {
    <#
        Returns the list of host addresses to probe. Network and broadcast
        addresses are excluded for prefixes shorter than /31.
    #>
    param(
        [string]$Cidr,
        [ipaddress]$From,
        [ipaddress]$To
    )

    if ($Cidr) {
        $parts  = $Cidr.Split('/')
        $prefix = [int]$parts[1]
        if ($prefix -lt 0 -or $prefix -gt 32) { throw "Invalid prefix length: /$prefix" }

        $addr = ConvertTo-UInt32Address ([ipaddress]$parts[0])
        $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32](( 0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL) }

        $first = [uint32]($addr -band $mask)
        $last  = [uint32]($first -bor ([uint32](( -bnot [int64]$mask) -band 0xFFFFFFFFL)))

        if ($prefix -le 30) { $first++; $last-- }
    }
    else {
        $first = ConvertTo-UInt32Address $From
        $last  = ConvertTo-UInt32Address $To
        if ($first -gt $last) { throw 'StartIP must be lower than or equal to EndIP.' }
    }

    $count = $last - $first + 1
    if ($count -gt 65536) { throw "Range too large ($count addresses). Narrow the scope." }

    for ($v = $first; $v -le $last; $v++) {
        ConvertFrom-UInt32Address $v
        if ($v -eq [uint32]::MaxValue) { break }   # guard against wrap-around
    }
}

function Get-NeighborCache {
    <#
        Returns a hashtable of IPv4 -> normalized MAC from the OS neighbor cache.
        Uses Get-NetNeighbor where available, otherwise parses arp -a.
    #>
    $map = @{}

    if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
        Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -and
                $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and
                $_.State -notin @('Incomplete', 'Unreachable', 'Permanent')
            } |
            ForEach-Object { $map[$_.IPAddress] = Format-MacAddress $_.LinkLayerAddress }
    }
    else {
        $arpOutput = & arp -a 2>$null
        foreach ($line in $arpOutput) {
            if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9A-Fa-f]{2}([-:])[0-9A-Fa-f]{2}(\3[0-9A-Fa-f]{2}){4})') {
                $mac = Format-MacAddress $matches[2]
                if ($mac -ne 'FF:FF:FF:FF:FF:FF') { $map[$matches[1]] = $mac }
            }
        }
    }

    return $map
}

function Merge-NeighborCache {
    <#
        Re-reads the neighbor cache and adds any entries not already present in
        the target hashtable. Used to pick up ARP resolutions that completed
        after the first read (e.g. entries that were still Incomplete then, or
        that a later TCP probe provoked).
    #>
    param([hashtable]$Into)
    foreach ($entry in (Get-NeighborCache).GetEnumerator()) {
        if (-not $Into.ContainsKey($entry.Key)) { $Into[$entry.Key] = $entry.Value }
    }
}

function Format-MacAddress {
    param([string]$Mac)
    if (-not $Mac) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($hex.Length -ne 12) { return $Mac.ToUpper() }
    ($hex -split '(..)' | Where-Object { $_ }) -join ':'
}

function Get-OuiTable {
    <#
        Loads the IEEE MA-L registry into a hashtable keyed on the 24-bit prefix.
        Downloads and caches the file on first use.
    #>
    param([string]$Path, [switch]$Force)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($Force -or -not (Test-Path $Path)) {
        Write-Verbose "Downloading IEEE OUI database to $Path"
        try {
            $progressPreference = 'SilentlyContinue'
            # A browser-like User-Agent gets past WAFs that answer non-browser
            # clients with a challenge (the IEEE site returns HTTP 418 to some).
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            Invoke-WebRequest -Uri 'https://standards-oui.ieee.org/oui/oui.csv' `
                              -OutFile $Path -UseBasicParsing -TimeoutSec 60 `
                              -UserAgent $ua -Headers @{ Accept = 'text/csv,text/plain,*/*' }
        }
        catch {
            Write-Warning ("OUI database could not be downloaded: $($_.Exception.Message) " +
                "Vendor lookup disabled. If a firewall/WAF is blocking the download (e.g. HTTP 418), " +
                "open https://standards-oui.ieee.org/oui/oui.csv in a browser, save it to '$Path', " +
                "and re-run (or pass -OuiPath to point at it).")
            return $null
        }
    }

    $table = @{}
    try {
        foreach ($row in (Import-Csv -Path $Path)) {
            $table[$row.Assignment.ToUpper()] = $row.'Organization Name'
        }
    }
    catch {
        Write-Warning "OUI database at $Path is unreadable: $($_.Exception.Message)"
        return $null
    }

    Write-Verbose "Loaded $($table.Count) OUI entries."
    return $table
}

function Resolve-Vendor {
    param([string]$Mac, [hashtable]$Table)

    if (-not $Mac) { return $null }
    $hex = $Mac -replace '[^0-9A-Fa-f]', ''
    if ($hex.Length -lt 6) { return $null }

    # Bit 1 of the first octet = locally administered (randomized MAC on phones etc.)
    if ((([convert]::ToInt32($hex.Substring(0, 2), 16)) -band 0x02) -ne 0) {
        return 'Locally administered (randomized MAC)'
    }

    if ($Table -and $Table.ContainsKey($hex.Substring(0, 6).ToUpper())) {
        return $Table[$hex.Substring(0, 6).ToUpper()]
    }
    return $null
}

function Resolve-HostName {
    param([string]$Address, [int]$TimeoutMs)
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($Address)
        if ($task.Wait($TimeoutMs)) { return $task.Result.HostName }
    }
    catch { }
    return $null
}

function Read-DnsName {
    <#
        Decodes a DNS name at $Offset in $Buffer, following 0xC0 compression
        pointers, and returns it dotted. $null on a malformed name.
    #>
    param([byte[]]$Buffer, [int]$Offset)

    $labels = New-Object System.Collections.Generic.List[string]
    $i = $Offset
    $guard = 0
    while ($i -lt $Buffer.Length -and $Buffer[$i] -ne 0) {
        if ($guard++ -gt 128) { break }   # cycle guard
        if (($Buffer[$i] -band 0xC0) -eq 0xC0) {
            if ($i + 1 -ge $Buffer.Length) { break }
            $i = (($Buffer[$i] -band 0x3F) -shl 8) -bor $Buffer[$i + 1]
            continue
        }
        $len = $Buffer[$i]
        if ($i + 1 + $len -gt $Buffer.Length) { break }
        $labels.Add([System.Text.Encoding]::UTF8.GetString($Buffer, $i + 1, $len))
        $i += 1 + $len
    }
    if ($labels.Count -eq 0) { return $null }
    return ($labels -join '.')
}

function Resolve-NetbiosName {
    <#
        Sends a NetBIOS node-status (NBSTAT) query to UDP 137 and returns the
        host's registered unique computer name (<00>/<20>). Catches Windows, SMB
        and NAS devices that have no reverse-DNS record. $null on no answer.
    #>
    param([string]$Address, [int]$TimeoutMs = 500)

    # Question name: the wildcard "*" (0x2A + 15 nulls), first-level encoded as
    # two nibble-bytes each, length-prefixed and null-terminated.
    $q = New-Object System.Collections.Generic.List[byte]
    $q.AddRange([byte[]](0x00,0x00, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00))
    $q.Add(0x20)
    $raw = New-Object byte[] 16
    $raw[0] = 0x2A
    foreach ($b in $raw) {
        $q.Add([byte](0x41 + ($b -shr 4)))
        $q.Add([byte](0x41 + ($b -band 0x0F)))
    }
    $q.Add(0x00)
    $q.AddRange([byte[]](0x00,0x21, 0x00,0x01))   # QTYPE NBSTAT, QCLASS IN

    $resp = $null
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        [void]$udp.Send($q.ToArray(), $q.Count, $Address, 137)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)
    }
    catch { return $null }
    finally { $udp.Close() }

    if (-not $resp -or $resp.Length -lt 12) { return $null }

    # Step past the answer RR: name (pointer or echoed name), then the 10-byte
    # type/class/ttl/rdlength header, landing on NUM_NAMES.
    $i = 12
    if (($resp[$i] -band 0xC0) -eq 0xC0) { $i += 2 }
    else { while ($i -lt $resp.Length -and $resp[$i] -ne 0) { $i += 1 + $resp[$i] }; $i++ }
    $i += 10
    if ($i -ge $resp.Length) { return $null }

    $numNames = $resp[$i]; $i++
    for ($n = 0; $n -lt $numNames; $n++) {
        if ($i + 18 -gt $resp.Length) { break }
        $name    = [System.Text.Encoding]::ASCII.GetString($resp, $i, 15).Trim()
        $suffix  = $resp[$i + 15]
        $isGroup = ($resp[$i + 16] -band 0x80) -ne 0
        if (-not $isGroup -and ($suffix -eq 0x00 -or $suffix -eq 0x20) -and
            $name -and $name -ne '__MSBROWSE__') {
            return $name
        }
        $i += 18
    }
    return $null
}

function Resolve-MdnsName {
    <#
        Sends an mDNS reverse-PTR query (unicast, UDP 5353) and returns the host's
        advertised name with any trailing .local stripped. Catches Apple, IoT,
        printers and avahi/Bonjour hosts. $null on no answer.
    #>
    param([string]$Address, [int]$TimeoutMs = 500)

    $o = $Address.Split('.')
    if ($o.Count -ne 4) { return $null }
    $labels = @($o[3], $o[2], $o[1], $o[0], 'in-addr', 'arpa')

    $q = New-Object System.Collections.Generic.List[byte]
    $q.AddRange([byte[]](0x00,0x00, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00))
    foreach ($l in $labels) {
        $b = [System.Text.Encoding]::ASCII.GetBytes($l)
        $q.Add([byte]$b.Length); $q.AddRange($b)
    }
    $q.Add(0x00)
    $q.AddRange([byte[]](0x00,0x0C, 0x00,0x01))   # QTYPE PTR, QCLASS IN

    $resp = $null
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        [void]$udp.Send($q.ToArray(), $q.Count, $Address, 5353)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)
    }
    catch { return $null }
    finally { $udp.Close() }

    if (-not $resp -or $resp.Length -lt 12) { return $null }
    $qd = ($resp[4] -shl 8) -bor $resp[5]
    $an = ($resp[6] -shl 8) -bor $resp[7]
    if ($an -lt 1) { return $null }

    # Skip the question section (our own QNAME is uncompressed).
    $i = 12
    for ($x = 0; $x -lt $qd; $x++) {
        while ($i -lt $resp.Length -and $resp[$i] -ne 0) { $i += 1 + $resp[$i] }
        $i += 5   # null terminator + qtype + qclass
    }

    # Walk answers, return the first PTR target name.
    for ($a = 0; $a -lt $an; $a++) {
        if ($i + 1 -ge $resp.Length) { break }
        if (($resp[$i] -band 0xC0) -eq 0xC0) { $i += 2 }
        else { while ($i -lt $resp.Length -and $resp[$i] -ne 0) { $i += 1 + $resp[$i] }; $i++ }
        if ($i + 10 -gt $resp.Length) { break }
        $type  = ($resp[$i] -shl 8) -bor $resp[$i + 1]
        $rdlen = ($resp[$i + 8] -shl 8) -bor $resp[$i + 9]
        $i += 10
        if ($type -eq 12) {
            $name = Read-DnsName -Buffer $resp -Offset $i
            if ($name) { return ($name -replace '\.local\.?$', '') }
        }
        $i += $rdlen
    }
    return $null
}

function Resolve-DeviceName {
    <#
        Reverse DNS first; when that is empty and -Probe is set, fall back to
        NetBIOS then mDNS. Returns the first name found, or $null.
    #>
    param([string]$Address, [int]$DnsTimeoutMs, [switch]$Probe, [int]$ProbeTimeoutMs)

    $name = Resolve-HostName -Address $Address -TimeoutMs $DnsTimeoutMs
    if ($name) { return $name }
    if ($Probe) {
        $name = Resolve-NetbiosName -Address $Address -TimeoutMs $ProbeTimeoutMs
        if ($name) { return $name }
        $name = Resolve-MdnsName -Address $Address -TimeoutMs $ProbeTimeoutMs
    }
    return $name
}

function Invoke-PingSweep {
    <#
        Parallel ICMP sweep in batches of $Throttle. Returns a hashtable of
        responding address -> round-trip time in ms.

        The .NET async ping loses replies from live hosts under high concurrency,
        so each address gets up to $Retries attempts; only addresses that have
        not answered yet are carried into the next pass, keeping the cost of a
        live host at a single probe.
    #>
    param([string[]]$Addresses, [int]$Throttle, [int]$TimeoutMs, [int]$DelayMs, [int]$Retries = 1)

    $alive   = @{}
    $pending = New-Object System.Collections.Generic.List[string]
    $pending.AddRange([string[]]$Addresses)

    for ($attempt = 1; $attempt -le $Retries -and $pending.Count -gt 0; $attempt++) {
        $current = @($pending)
        $pending.Clear()
        $done = 0

        for ($i = 0; $i -lt $current.Count; $i += $Throttle) {
            $end   = [Math]::Min($i + $Throttle - 1, $current.Count - 1)
            $batch = @($current[$i..$end])

            $pingers = New-Object System.Collections.ArrayList
            $tasks   = New-Object System.Collections.ArrayList

            foreach ($address in $batch) {
                $ping = [System.Net.NetworkInformation.Ping]::new()
                [void]$pingers.Add($ping)
                [void]$tasks.Add($ping.SendPingAsync($address, $TimeoutMs))
            }

            try   { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $TimeoutMs + 2000) | Out-Null }
            catch { }   # individual faults are inspected below

            for ($j = 0; $j -lt $batch.Count; $j++) {
                $task = $tasks[$j]
                if ($task.Status -eq 'RanToCompletion' -and $task.Result.Status -eq 'Success') {
                    $alive[$batch[$j]] = [int]$task.Result.RoundtripTime
                }
                else {
                    [void]$pending.Add($batch[$j])   # retry on the next pass
                }
            }

            foreach ($ping in $pingers) { $ping.Dispose() }

            $done += $batch.Count
            Write-Progress -Activity 'ICMP sweep' `
                           -Status "pass $attempt/$Retries - $done/$($current.Count) - $($alive.Count) responding" `
                           -PercentComplete ([int](100 * $done / $current.Count))

            if ($DelayMs -gt 0 -and $end -lt $current.Count - 1) { Start-Sleep -Milliseconds $DelayMs }
        }
    }

    Write-Progress -Activity 'ICMP sweep' -Completed
    return $alive
}

function Invoke-TcpProbe {
    <#
        TCP connect scan across the cartesian product of $Addresses and $Ports.

        Returns:
          Open    - address -> sorted list of ports that completed a handshake
          Refused - address -> $true when at least one port answered with RST.
                    A refusal still proves the host exists, which is useful when
                    it stayed silent on ICMP and ARP.

        A filtered/dropped port yields neither and costs the full timeout.
    #>
    param(
        [string[]]$Addresses,
        [int[]]$Ports,
        [int]$Throttle,
        [int]$TimeoutMs,
        [int]$DelayMs,
        [switch]$Shuffle
    )

    $open    = @{}
    $refused = @{}

    $work = @(foreach ($address in $Addresses) {
        foreach ($port in $Ports) {
            [pscustomobject]@{ Address = $address; Port = $port }
        }
    })
    if (-not $work) { return @{ Open = $open; Refused = $refused } }

    # Interleaving targets makes the scan look less like a sequential sweep, and
    # spreads the load so a single slow host does not stall a whole batch.
    if ($Shuffle) { $work = @($work | Sort-Object { Get-Random }) }

    $done = 0

    for ($i = 0; $i -lt $work.Count; $i += $Throttle) {
        $end   = [Math]::Min($i + $Throttle - 1, $work.Count - 1)
        $batch = @($work[$i..$end])

        $clients = New-Object System.Collections.ArrayList
        $tasks   = New-Object System.Collections.ArrayList

        foreach ($item in $batch) {
            $client = [System.Net.Sockets.TcpClient]::new()
            [void]$clients.Add($client)
            [void]$tasks.Add($client.ConnectAsync($item.Address, $item.Port))
        }

        try   { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $TimeoutMs) | Out-Null }
        catch { }

        for ($j = 0; $j -lt $batch.Count; $j++) {
            $task = $tasks[$j]
            $item = $batch[$j]

            if ($task.Status -eq 'RanToCompletion' -and $clients[$j].Connected) {
                if (-not $open.ContainsKey($item.Address)) {
                    $open[$item.Address] = New-Object System.Collections.ArrayList
                }
                [void]$open[$item.Address].Add($item.Port)
            }
            elseif ($task.IsFaulted) {
                # Reading .Exception also observes it, so the faulted task is not
                # re-raised by the finalizer later on.
                $socketError = $task.Exception.InnerExceptions |
                    Where-Object { $_ -is [System.Net.Sockets.SocketException] } |
                    Select-Object -First 1
                if ($socketError -and
                    $socketError.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
                    $refused[$item.Address] = $true
                }
            }
        }

        foreach ($client in $clients) { $client.Close() }

        $done += $batch.Count
        Write-Progress -Activity 'TCP scan' `
                       -Status "$done/$($work.Count) probes - $($open.Count) hosts with open ports" `
                       -PercentComplete ([int](100 * $done / $work.Count))

        if ($DelayMs -gt 0 -and $end -lt $work.Count - 1) { Start-Sleep -Milliseconds $DelayMs }
    }

    Write-Progress -Activity 'TCP scan' -Completed
    return @{ Open = $open; Refused = $refused }
}

function Test-LocalSubnet {
    <#
        True if at least one address in the target range is on a directly
        connected interface. ARP/MAC data is only available when it is.
    #>
    param([string]$SampleAddress)

    if (-not (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) { return $true }

    $target = ConvertTo-UInt32Address ([ipaddress]$SampleAddress)
    foreach ($local in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
        if ($local.PrefixLength -eq 0 -or $local.PrefixLength -gt 32) { continue }
        $mask = [uint32](( 0xFFFFFFFFL -shl (32 - $local.PrefixLength)) -band 0xFFFFFFFFL)
        $localNet = (ConvertTo-UInt32Address ([ipaddress]$local.IPAddress)) -band $mask
        if (($target -band $mask) -eq $localNet) { return $true }
    }
    return $false
}

function Get-OnLinkSource {
    <#
        Returns the local IPv4 address whose own subnet contains $SampleAddress -
        the source IP to bind ARP to for that target. $null when the target is not
        on any directly connected interface (genuinely routed via a gateway/VPN),
        or when the required cmdlet is unavailable.
    #>
    param([string]$SampleAddress)

    if (-not (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) { return $null }

    $target = ConvertTo-UInt32Address ([ipaddress]$SampleAddress)
    foreach ($local in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
        if ($local.PrefixLength -eq 0 -or $local.PrefixLength -gt 32) { continue }
        $mask = [uint32](( 0xFFFFFFFFL -shl (32 - $local.PrefixLength)) -band 0xFFFFFFFFL)
        if (((ConvertTo-UInt32Address ([ipaddress]$local.IPAddress)) -band $mask) -eq ($target -band $mask)) {
            return $local.IPAddress
        }
    }
    return $null
}

function Invoke-ArpSweep {
    <#
        Resolves each target's MAC with SendARP, source-bound to $SourceAddress so
        the ARP request leaves the physical interface regardless of the routing
        table (a lower-metric tunnel route would otherwise capture it, and no ARP -
        hence no MAC - would ever happen). Returns a hashtable of address ->
        normalized MAC for hosts that answered ARP; that answer also proves the
        host is alive on L2.

        SendARP is synchronous and a silent host costs the full ARP retry time, so
        the calls run on a runspace pool. The P/Invoke type is loaded into the
        process AppDomain, so pool runspaces resolve [NetScanArp] without re-adding.
    #>
    param([string[]]$Addresses, [string]$SourceAddress, [int]$Throttle = 32)

    $srcUint = [System.BitConverter]::ToUInt32(([ipaddress]$SourceAddress).GetAddressBytes(), 0)

    $worker = {
        param($Ip, $SrcUint)
        $mac = New-Object byte[] 6
        $len = 6
        $destUint = [System.BitConverter]::ToUInt32(([ipaddress]$Ip).GetAddressBytes(), 0)
        $rc = [NetScanArp]::SendARP($destUint, $SrcUint, $mac, [ref]$len)
        if ($rc -eq 0 -and $len -ge 6) {
            $hex = ($mac[0..5] | ForEach-Object { $_.ToString('X2') }) -join ':'
            if ($hex -ne '00:00:00:00:00:00' -and $hex -ne 'FF:FF:FF:FF:FF:FF') {
                [pscustomobject]@{ Address = $Ip; Mac = $hex }
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Throttle))
    $pool.Open()
    $jobs = New-Object System.Collections.ArrayList
    try {
        foreach ($ip in $Addresses) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($ip).AddArgument($srcUint)
            [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }

        $map = @{}
        $done = 0
        foreach ($job in $jobs) {
            try {
                foreach ($r in $job.PS.EndInvoke($job.Handle)) {
                    if ($r) { $map[$r.Address] = $r.Mac }
                }
            }
            catch { }
            finally { $job.PS.Dispose() }

            $done++
            Write-Progress -Activity 'ARP sweep' `
                           -Status "$done/$($jobs.Count) - $($map.Count) with MAC" `
                           -PercentComplete ([int](100 * $done / [Math]::Max(1, $jobs.Count)))
        }
    }
    finally {
        $pool.Close(); $pool.Dispose()
        Write-Progress -Activity 'ARP sweep' -Completed
    }

    return $map
}

# --- Main --------------------------------------------------------------------

$results = New-Object System.Collections.ArrayList

if ($ArpOnly) {
    $neighbors = Get-NeighborCache
    $targets   = @($neighbors.Keys)
    $alive     = @{}
    Write-Verbose "Neighbor cache contains $($targets.Count) entries."
}
else {
    switch ($PSCmdlet.ParameterSetName) {
        'Subnet' { $targets = @(Expand-TargetRange -Cidr $Subnet) }
        'Range'  { $targets = @(Expand-TargetRange -From $StartIP -To $EndIP) }
    }

    if (-not $targets) { throw 'The specified range contains no host addresses.' }

    # Source IP for L2/ARP: an explicit override, else the local interface that
    # owns the target subnet. $null means the target is not on any local interface.
    $arpSource = if ($SourceAddress) { $SourceAddress.IPAddressToString } else { Get-OnLinkSource -SampleAddress $targets[0] }

    if (-not $arpSource -and -not (Test-LocalSubnet -SampleAddress $targets[0])) {
        Write-Warning 'Target range is not on a directly connected interface - MAC addresses and vendor data will be unavailable (ARP is link-local).'
    }

    $probeOrder = if ($Shuffle) { $targets | Sort-Object { Get-Random } } else { $targets }

    Write-Verbose "Scanning $($targets.Count) addresses, icmpThrottle=$IcmpThrottle, retries=$IcmpRetries, delay=${DelayMs}ms, timeout=${TimeoutMs}ms."
    $alive = Invoke-PingSweep -Addresses $probeOrder -Throttle $IcmpThrottle -TimeoutMs $TimeoutMs -DelayMs $DelayMs -Retries $IcmpRetries

    # Read the cache after the sweep: hosts that dropped the ICMP echo still had
    # to answer the ARP request that preceded it.
    $neighbors = Get-NeighborCache

    # Some of those ARP resolutions may still be Incomplete at this instant, so
    # they carry no MAC yet. Give them a moment and merge in whatever resolved.
    if ($NeighborSettleMs -gt 0) {
        Start-Sleep -Milliseconds $NeighborSettleMs
        Merge-NeighborCache -Into $neighbors
    }

    # On-link: resolve MACs directly over L2 with source-bound ARP. This forces
    # the request out the physical interface, bypassing any lower-metric tunnel
    # route (e.g. a Tailscale/VPN subnet router) that would otherwise capture the
    # traffic - so on-link hosts stay discoverable and keep their MAC even when the
    # ICMP echo went through the tunnel. The ARP answer itself proves liveness.
    if ($script:CanArp -and $arpSource -and -not $SkipArpSweep) {
        Write-Verbose "ARP sweep source-bound to $arpSource ($($targets.Count) targets)."
        try {
            $arpMap = Invoke-ArpSweep -Addresses $targets -SourceAddress $arpSource -Throttle $Throttle
            foreach ($entry in $arpMap.GetEnumerator()) { $neighbors[$entry.Key] = $entry.Value }
            Write-Verbose "ARP sweep resolved $($arpMap.Count) MACs."
        }
        catch { Write-Warning "ARP sweep failed: $($_.Exception.Message)" }
    }
}

$portResults = @{ Open = @{}; Refused = @{} }

if ($Port) {
    if ($PortScope -eq 'All' -and -not $ArpOnly) {
        $portTargets = $targets
    }
    else {
        $portTargets = @($targets | Where-Object { $alive.ContainsKey($_) -or $neighbors.ContainsKey($_) })
    }

    if ($portTargets) {
        Write-Verbose "TCP scan: $($portTargets.Count) hosts x $($Port.Count) ports (scope=$PortScope)."
        $portResults = Invoke-TcpProbe -Addresses $portTargets -Ports $Port `
                                       -Throttle $Throttle -TimeoutMs $PortTimeoutMs `
                                       -DelayMs $DelayMs -Shuffle:$Shuffle

        # The TCP probes populate the neighbor cache for hosts that were silent
        # on ICMP, so merge in anything that appeared since the first read.
        if (-not $ArpOnly) { Merge-NeighborCache -Into $neighbors }
    }
}

$ouiTable = $null
if (-not $NoVendorLookup) {
    $ouiTable = Get-OuiTable -Path $OuiPath -Force:$UpdateOuiDatabase
}

$discovered = @($targets | Where-Object {
    $alive.ContainsKey($_) -or $neighbors.ContainsKey($_) -or
    $portResults.Open.ContainsKey($_) -or $portResults.Refused.ContainsKey($_)
})

foreach ($address in $discovered) {
    $methods = New-Object System.Collections.ArrayList
    if ($alive.ContainsKey($address))                 { [void]$methods.Add('ICMP') }
    if ($neighbors.ContainsKey($address))             { [void]$methods.Add('ARP') }
    if ($portResults.Open.ContainsKey($address))      { [void]$methods.Add('TCP') }
    elseif ($portResults.Refused.ContainsKey($address)) { [void]$methods.Add('TCP-RST') }

    $mac = if ($neighbors.ContainsKey($address)) { $neighbors[$address] } else { $null }

    $openPorts = $null
    if ($portResults.Open.ContainsKey($address)) {
        $openPorts = (($portResults.Open[$address] | Sort-Object) | ForEach-Object {
            if ($ServiceLabel.ContainsKey($_)) { "$_/$($ServiceLabel[$_])" } else { "$_" }
        }) -join ' '
    }

    [void]$results.Add([pscustomobject]@{
        PSTypeName     = 'NetScan.Host'
        IPAddress      = $address
        MACAddress     = $mac
        HostName       = if ($SkipDns) { $null } else { Resolve-DeviceName -Address $address -DnsTimeoutMs $DnsTimeoutMs -Probe:(-not $SkipNameProbe) -ProbeTimeoutMs $NameProbeTimeoutMs }
        Vendor         = Resolve-Vendor -Mac $mac -Table $ouiTable
        OpenPorts      = $openPorts
        Method         = $methods -join '+'
        ResponseTimeMs = if ($alive.ContainsKey($address)) { $alive[$address] } else { $null }
    })
}

# @() so an empty scan yields a real (count 0) array, not $null - otherwise
# $sorted.Count below throws under Set-StrictMode.
$sorted = @($results | Sort-Object { ConvertTo-UInt32Address ([ipaddress]$_.IPAddress) })

# Register the table view so the result prints as a table. Update-FormatData
# needs a file on disk; keep it beside the OUI cache. Failure here only costs
# the pretty formatting, so never let it abort the scan.
try {
    $fmtDir = Split-Path -Parent $OuiPath
    if (-not (Test-Path $fmtDir)) { New-Item -ItemType Directory -Path $fmtDir -Force | Out-Null }
    $fmtPath = Join-Path $fmtDir 'NetScan.Format.ps1xml'
    Set-Content -Path $fmtPath -Value $NetScanFormatXml -Encoding UTF8
    Update-FormatData -PrependPath $fmtPath
}
catch {
    Write-Verbose "Table formatting unavailable: $($_.Exception.Message)"
}

if ($CsvPath) {
    $sorted | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter $CsvDelimiter
    Write-Verbose "Wrote $($sorted.Count) rows to $CsvPath"
}

Write-Verbose "$($sorted.Count) hosts discovered."

$withMac = @($sorted | Where-Object MACAddress).Count

if ($PassThru) {
    # Machine-readable: objects on the pipeline, no display chrome.
    $sorted
}
else {
    # Human-readable: render the table, then a summary line. A plain Write-Host
    # summary would print *before* the table, because object formatting is
    # deferred to the end of the pipeline - Out-Host forces the table out first.
    if ($sorted.Count) { $sorted | Out-Host }
    $summary = "$($sorted.Count) host(s) found"
    if ($sorted.Count) { $summary += " ($withMac with a MAC address)" }
    Write-Host $summary -ForegroundColor Cyan
}
