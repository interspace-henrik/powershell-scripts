# KLART

Levererade punkter (flyttade hit från TODO.md så att TODO förblir kort).

- [x] **NetScan: namnuppslag utan reverse-DNS (NetBIOS + mDNS-fallback)** _(2026-08-29)_

  När reverse-DNS är tomt (och `-SkipDns` inte satt) provar `Resolve-DeviceName`
  nu i tur och ordning: **NetBIOS node-status** (rå UDP 137, parsar `<00>/<20>`
  UNIQUE-namn) och **mDNS reverse-PTR** (UDP 5353, parsar PTR-svaret via
  `Read-DnsName` som följer 0xC0-komprimeringspekare, strippar `.local`). Ny
  `-SkipNameProbe` och `-NameProbeTimeoutMs` (default 500). Kör inline bara för
  PTR-lösa värdar (bounded till upptäckta hosts), inte parallelliserat —
  tillräckligt då sonderna svarar snabbt och tysta värdar är få. HostName
  återanvänds (ingen extra kolumn). Verifierat: parsern ger `NAS-1` (NetBIOS) och
  `nas-1` (mDNS, `.local` strippat) för `.20`; Proxmox-VM:ar förblir namnlösa
  (förväntat — de annonserar inget). Windows egen mDNS-resolver fångar dessutom
  ofta `.local` redan i reverse-DNS-steget.

- [x] **NetScan: robustare OUI-nedladdning (418 från WAF) + tydlig offline-väg** _(2026-08-29)_

  `Get-OuiTable` sätter nu en webbläsar-User-Agent + `Accept: text/csv,*/*` på
  nedladdningen (klarar WAF:ar som blockar enbart på UA). Felmeddelandet skriver ut
  exakt cache-sökväg och instruerar att ladda ner `oui.csv` i webbläsaren och lägga
  den där (eller ange `-OuiPath`) — den garanterade offline-vägen. 418:an gick inte
  att reproducera härifrån (200 OK), så UA-fixen är best-effort; offline-vägen är
  den säkra. (Alternativ spegel hoppades över tills det behövs.)

- [x] **NetScan: skanna on-link-nät över lokala kortet (inte tunneln) via källbunden SendARP** _(2026-08-29)_

  P/Invoke `NetScanArp.SendARP` (Windows-skyddad, laddas en gång). Ny
  `Get-OnLinkSource` (käll-IP för målsubnätet) och `Invoke-ArpSweep` (källbunden
  SendARP på en runspace-pool, address→MAC). När målnätet är on-link körs ARP-svepet
  och skriver MAC:ar direkt över L2 — kringgår en ev. tunnel-route. Nya
  `-SourceAddress` (övervrida käll-IP) och `-SkipArpSweep` (fart). Varningen behålls
  bara för genuint routade fjärrnät; on-link-fallet löses nu i stället för att varna
  (det ersätter förra punktens tunnel-varning, `Get-OffLinkRouteWarning` togs bort).
  Verifierat mot `.99.0/24` med Tailscale-routen aktiv: **9/9 värdar fick MAC**,
  `.118` (som saknade MAC) hittas nu via ARP. Fixade även en latent bugg där
  noll-träff kraschade på `$sorted.Count` under strict mode.

- [x] **PSPrompt: tomrad före prompten + slimmad admin-indikator** _(2026-08-29)_

  Tre ändringar i prompt-mallen i `Install-PSPrompt.ps1`: (1) `global:prompt`
  returnerar nu med en inledande `[Environment]::NewLine` → blankrad över varje
  prompt; (2) UTF8-admin-glyfen är bara `[char]0x26A1` (⚡, utan "admin"); (3)
  ASCII-admin är `adm` (tidigare `!admin`). Verifierat via rendering i båda lägen.
  Slår igenom efter ny körning av `Install-PSPrompt.ps1`.

- [x] **PSPrompt: `ll`-hjälpare (Get-ChildItem)** _(2026-08-29)_

  `# --- User helpers ---`-sektion överst i `$promptTemplate` med
  `function global:ll { Get-ChildItem @args }`. Verifierat att den genereras,
  hamnar globalt och fungerar. Slår igenom efter ny installer-körning.

- [x] **NetScan: justera ICMP-defaults, summeringsrad och -PassThru** _(2026-08-29)_

  Default `-IcmpThrottle 3` och `-IcmpRetries 1` (mest tillförlitligt i test).
  Standardutdata renderar nu tabell + summeringsrad (antal hittade, hur många med
  MAC); `-PassThru` ger objekten på pipelinen i stället (annars hamnar en
  Write-Host-summering före den buffrade tabellen). `-CsvPath` skriver oavsett.

- [x] **Varna när målsubnätet routas via en tunnel (t.ex. Tailscale)** _(2026-08-29, ersatt)_

  Ursprungligen `Get-OffLinkRouteWarning` (jämför vald route mot on-link via
  `Find-NetRoute`, varnar med interface/metric). Ersattes senare av det källbundna
  ARP-svepet: on-link-fallet löses nu i stället för att bara varna, och funktionen
  togs bort. Varning kvarstår bara för genuint routade fjärrnät.

- [x] **ICMP-svepet tappar levande värdar vid hög samtidighet (falska "ARP-only")** _(2026-08-29)_

  Ny `-IcmpThrottle` (separat från `-Throttle` som styr TCP) och
  `-IcmpRetries`/`-Count`. `Invoke-PingSweep` gör om-försök men bara för adresser
  som ännu inte svarat, så levande värdar kostar en sond. `-Slow` sätter
  `-IcmpThrottle 1 -IcmpRetries 3`. Verifierat: .12/.20 gick från `ARP` i 7/8
  körningar till `ICMP+ARP` i 7/8. (Defaults sedan justerade till 3/1 — se ovan.)

- [x] **Läs om grann-cachen med kort fördröjning (fånga MAC som ännu var Incomplete)** _(2026-08-29)_

  Ny `-NeighborSettleMs` (default 300; `-Slow` → 500). Efter första
  `Get-NeighborCache` sover scriptet kort och mergar in poster som hunnit
  resolva, via ny hjälpfunktion `Merge-NeighborCache` (återanvänds även i
  TCP-mergen).

- [x] **Visa resultatet som en tabell i slutet** _(2026-08-29)_

  Utdataobjekten fick `PSTypeName = 'NetScan.Host'` och en tabell-formatvy
  registreras via `Update-FormatData` (ps1xml skrivs bredvid OUI-cachen).
  Resultatet skrivs som tabell men förblir riktiga objekt — `-CsvPath` och
  pipeline oförändrade (verifierat: 7 egenskaper kvar, CSV-export OK).

- [x] **Fixa `-Subnet` med CIDR (t.ex. /24) — kastar "Cannot convert value \"-256\" to type System.UInt32"** _(2026-08-29)_

  Bytte `[int64]0xFFFFFFFF` → `0xFFFFFFFFL` i `Expand-TargetRange` (masken +
  host-bitarna via `-bnot`) och `Test-LocalSubnet` (masken). Orsak: PowerShell
  tolkar hex-literalen `0xFFFFFFFF` som `Int32` = `-1`, så maskeringen blev fel och
  `[uint32]` kastade på negativa mellanresultat. Verifierat: /24 → .1–.254, /30 →
  2 hosts, /16 → 65534, /32 → 1.
