# KLART

Levererade punkter (flyttade hit från TODO.md så att TODO förblir kort).

- [x] **Copy-ToSharePoint: krasch "Get-GraphAccessToken is not recognized"** _(2026-10-16)_

  Uppstod när tenantens remote redan fanns och biblioteket inte låg i cachen, och
  scriptet startades som `.\Copy-ToSharePoint.ps1`. Token-scriptblocket skapades
  med `.GetNewClosure()`, som binder det till en ny dynamisk modul som inte ser
  scriptets egna funktioner. Under `pwsh -File`, som alla tidigare end-to-end-tester
  använde, syns de ändå, så buggen doldes. Fix: vanliga scriptblock. Verifierat i
  både pwsh 7 och Windows PowerShell 5.1, anropat som `.\script`: vägen når nu
  Microsoft Graph. 401-meddelandet pekar också på `-SignIn`.

- [x] **Copy-ToSharePoint: skiftlägesokänsliga filter + standardexkludering av skräpfiler** _(2026-10-16)_

  Bugg: rclones `--exclude` var skiftlägeskänsligt, så `-ExcludeFile thumbs.db`
  missade `Thumbs.db`. Nu skickas alltid `--ignore-case` (som robocopy/Windows).
  Nytt: `Thumbs.db`, `ehthumbs.db`, `desktop.ini`, `.DS_Store`, `~$*` samt mapparna
  `$RECYCLE.BIN` och `System Volume Information` hoppas över som standard och
  visas på headerns `Defaults`-rad; `-NoDefaultExcludes` tar med dem. Beslut:
  `*.tmp` hålls utanför standardlistan (kan vara riktig data); städning av redan
  uppladdat skräp (`--delete-excluded`) skjuts upp. Verifierat i motorn: av tio
  filer kopierades bara de tre väntade (`THUMBS.DB` i versaler, `Thumbs.db` i
  undermapp och `Node_Modules` via `node_modules` stoppades), och båda
  systemmapparna hoppades över utan fel.

- [x] **Copy-ToSharePoint.ps1 — rclone-wrapper: nätverksenhet → SharePoint** _(2026-10-15)_

  Nytt script. Målet anges som en enda `-Url` kopierad från webbläsarens
  adressfält (library-vy med `?id=`, rak mapp-URL, `RootFolder=` eller
  `/:f:/r/`-länk; `/:f:/s/`-delningslänkar avvisas med förklaring). Remote-namn =
  tenanten (delen före `.sharepoint.com`). **Designval:** en remote per tenant
  (OAuth-token gäller hela tenanten) och biblioteket väljs per körning med
  `--onedrive-drive-id` — slås upp via Graph genom att matcha drive-`webUrl` mot
  URL:en (URL-sökväg, inte lokaliserat visningsnamn; klarar subsiter) och cachas i
  `drives.json`. rclone laddas ned pinnad (v1.75.2) med SHA-256-kontroll mot
  SHA256SUMS; `-UpdateRclone` för senaste. Kopierar med `rclone copy` (`-Mirror` →
  `sync`, bekräftelse eller `-Force`), robocopy-flaggor (/XF /XD /R /W /MT /L /LOG
  /NFL /IPG), PowerShell-progressbar + fil-rader + summeringstabell byggda på
  rclones JSON-logg, eller `-NativeProgress`. För dokumentbibliotek jämförs på
  modtime (`--ignore-size --ignore-checksum`, SharePoint skriver om Office-filer);
  `-StrictCompare` stänger av. `-SourceCredential` via WNetAddConnection2 (inget
  lösenord på kommandoraden), `-SignIn` förnyar utgången inloggning, `-ClientId`/
  `-ClientSecret` för tenanter som blockerar rclone-appen, `-DriveId` som nödutgång,
  `-PassThru`. Exit-kod = rclones.

  **Verifierat:** URL-parsning (12 fall), argument-quoting genom rclones egen
  parser (token-JSON med `\"` och `\\` bevaras exakt), nedladdning + checksumma,
  token-hjälpare (Go-nanosekunder, base64-inslagen output), Graph-cache utan
  anrop, och motorn lokal→lokal i sex scenarion (ny, oförändrad, ändrad,
  torrkörning, mirror med borttagning, låst fil → 1 FAILED trots retries, exit 1).
  End-to-end mot fejkad tenant-remote: header, felorsak + åtgärdstips, loggfil,
  `-WhatIf`, `-Mirror` utan `-Force` i icke-interaktiv session ger tydligt fel.
  **Ej verifierat (kräver riktig tenant):** själva webbläsarinloggningen,
  Graph-uppslaget mot ett riktigt bibliotek och uppladdning till SharePoint.

  **Fixat på vägen:** rclone loggar dödliga fel som `level: critical`, som först
  filtrerades bort (användaren såg bara "exit 1"); nu visas de. Och en `#Requires`
  direkt ovanför hjälpblocket gjorde att `Get-Help` ignorerade all hjälp — rättat
  här och i `Invoke-NetScan.ps1` (separat commit).

- [x] **Set-ComputerText: icke-blockerande start + live-uppdatering + stop** _(2026-09-17)_

  Omskriven till launcher + worker. Intern `-Overlay` kör WPF-fönstret (blockerar
  i egen process); default-läget skriver texten till en per-användar-state-fil
  (`%LOCALAPPDATA%\ComputerText\state.txt`), startar workern frikopplat och hidden,
  gör en kort liveness-koll och returnerar **exit 0 vid start / non-zero vid fel**.
  Workern håller en session-lokal mutex (en overlay i taget) och pollar state-filen
  var 500 ms: ny `-Text` **uppdaterar texten live utan omstart**, `-Stop` (alias
  `-Clear`) skriver en stopp-token så workern stänger sig rent. Körs som inloggad
  användare (SYSTEM→session-relansering medvetet inte byggd nu). STA-guard,
  kommentarbaserad hjälp och README-rad tillagda; scriptet incheckat.
  Verifierat: start exit 0 + 1 process; uppdatering exit 0 utan ny process (state
  bytte HELLO-1→UPDATED-2); stop → 0 processer kvar.

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
