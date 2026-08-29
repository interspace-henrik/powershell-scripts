# TODO

## Att göra

## Klart

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

- [x] **Varna när målsubnätet routas via en tunnel (t.ex. Tailscale) i stället för on-link** _(2026-08-29)_

  Ny hjälpfunktion `Get-OffLinkRouteWarning`: hittar det on-link-interface som
  äger målsubnätet och jämför mot den route Windows faktiskt väljer
  (`Find-NetRoute`). Går den valda routen via ett annat interface skrivs en
  `Write-Warning` med interface-namn och metrics samt åtgärdstips
  (`tailscale set --accept-routes=false` / sänk metric). Verifierat mot
  .99.0/24 med Tailscale-routen aktiv → varning med "Tailscale (metric 5) instead
  of ... Ethernet (metric 25)".

  **-SourceAddress: utvärderat och bortvalt.** `.NET Ping` kan inte käll-bindas,
  så en `-SourceAddress` skulle bara påverka TCP-sonderna medan ICMP (den primära
  upptäckten) ändå gick via tunneln — halv lösning som vilseleder. Varningen +
  routnings-åtgärden är rätt väg. Kan tas upp igen om käll-bunden ICMP behövs
  (kräver `ping.exe -S` eller rå socket/admin).

- [x] **ICMP-svepet tappar levande värdar vid hög samtidighet (falska "ARP-only")** _(2026-08-29)_

  Ny `-IcmpThrottle` (default 8, separat från `-Throttle` som styr TCP) och
  `-IcmpRetries`/`-Count` (default 2). `Invoke-PingSweep` gör om-försök men bara
  för adresser som ännu inte svarat, så levande värdar kostar en sond. `-Slow`
  sätter `-IcmpThrottle 1 -IcmpRetries 3`. Verifierat: .12/.20 gick från `ARP` i
  7/8 körningar till `ICMP+ARP` i 7/8 (och syns alltid minst via ARP).

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

  Bytte `[int64]0xFFFFFFFF` → `0xFFFFFFFFL` på tre ställen i `Invoke-NetScan.ps1`
  (`Expand-TargetRange` rad 183 + 186, `Test-LocalSubnet` rad 457). Verifierat:
  /24 → .1–.254, /30 → 2 hosts, /16 → 65534, /32 → 1.

---

<details><summary>Ursprunglig analys</summary>

- **Fixa `-Subnet` med CIDR (t.ex. /24) — kastar "Cannot convert value \"-256\" to type System.UInt32"**

  **Orsak:** PowerShell tolkar hex-literalen `0xFFFFFFFF` som `Int32` = `-1`
  (bitmönstret, inte värdet 4294967295). Detta gäller både i PS 5.1 och 7.x.
  I `Invoke-NetScan.ps1` används `[int64]0xFFFFFFFF` för att bygga nätmasken:
  `[int64](-1)` blir `-1` (alla ettor), så `-band [int64]0xFFFFFFFF` maskar inte
  bort de höga bitarna. Vid `-shl` blir mellanresultatet negativt (t.ex. `-256`
  för /24) och `[uint32](-256)` kastar felet. All CIDR-skanning är trasig, inte
  bara /24.

  **Förslag:** Byt hex-literalen mot en `long`-literal `0xFFFFFFFFL`
  (= 4294967295), som tolkas korrekt. Berör tre rader:
  - `Expand-TargetRange`: masken (rad ~183) och host-bitarna via `-bnot`
    (rad ~186).
  - `Test-LocalSubnet`: masken (rad ~457).

  Alla `[int64]0xFFFFFFFF` → `0xFFFFFFFFL`. Verifierat: `mask /24` blir då
  `4294967040` och `[uint32]`-castet lyckas.

  **Test efter fix:** `.\Invoke-NetScan.ps1 -Subnet 192.168.10.0/24 -ArpOnly`
  ska inte kasta, och `-StartIP/-EndIP`-läget ska fungera oförändrat.

</details>
