# TODO

## Att göra

- [ ] **NetScan: robustare OUI-nedladdning (418 från WAF) + tydlig offline-väg**

  **Symtom:** på en maskin (DESKTOP-0D3FBQ0) ger `Invoke-WebRequest` mot
  `https://standards-oui.ieee.org/oui/oui.csv` HTTP **418** ("I'm a teapot"),
  medan webbläsaren hämtar filen fint. 418 kommer från en Cloudflare-liknande WAF
  som utmanar/blockar icke-webbläsar-klienter (User-Agent eller egress-IP).
  Kunde *inte* reproduceras från denna maskin (200 OK med både default- och
  browser-UA), så det är miljöspecifikt — men förbättringar går att göra:

  1. **Sätt en webbläsar-User-Agent** (och `Accept: text/csv,*/*`) på nedladdningen.
     Löser de WAF:ar som blockar enbart på UA. Billigt, gör alltid.
  2. **Tydlig offline-väg i felmeddelandet.** Scriptet cachar redan filen och
     laddar bara ner när den saknas (`-OuiPath`, default
     `%LOCALAPPDATA%\NetScan\oui.csv`). Låt varningen skriva ut *exakt* sökväg och
     säga: "ladda ner oui.csv i webbläsaren och lägg den här, eller ange -OuiPath".
     Det är den garanterade lösningen när WAF:en inte släpper igenom scriptet.
  3. **Ev. retry/alternativ spegel** (t.ex. maclookup/wireshark-manuf) som fallback.

  **Test:** svårt att verifiera 418-fixen härifrån (går ej att reproducera);
  verifiera minst att UA sätts och att offline-vägen (förnedladdad fil på
  cache-sökvägen) används utan nätåtkomst.

- [ ] **NetScan: skanna on-link-nät över lokala kortet (inte tunneln) via källbunden SendARP**

  **Bakgrund:** när ett subnät ligger på ett lokalt nätverkskort *men* en
  lägre-metric-route (Tailscale) annonserar samma nät, routar Windows scan-trafik
  genom tunneln. `.NET Ping` och `SendARP` (utan källa) följer routningstabellen
  och hamnar fel → MAC saknas och ICMP blir ojämnt. Din poäng stämmer: ligger
  nätet på ett kort *ska* det skannas lokalt.

  **Lösning (verifierad):** `SendARP` **med explicit källadress** (kortets IP) gör
  ARP direkt på det fysiska interfacet, oberoende av routningen. Uppmätt mot
  `.99.0/24` med källa `192.168.99.70`:
  - `.118` → `5A:7A:9B:CE:C4:42` (riktig MAC, som annars saknades)
  - `.31`  → `BC:24:11:B5:D0:FE`
  - `.201` (död) → `rc=67` (korrekt: ingen ARP)

  Ett anrop ger alltså både liveness och MAC, över L2, utan admin.

  **Design:**
  1. Hjälpfunktion som hittar det on-link-interface + käll-IP som äger målsubnätet
     (återanvänd logiken i `Get-OffLinkRouteWarning`/`Test-LocalSubnet`, men
     returnera käll-IP:t). Ny `-SourceAddress` för att övervrida.
  2. P/Invoke `SendARP` (`iphlpapi.dll`). Ny `Invoke-ArpSweep` som kör SendARP
     källbundet mot varje target och returnerar address→MAC. OBS: SendARP är
     synkron och tar ~1–3 s per *död* värd (ARP-retries), så parallellisera med en
     runspace-pool (t.ex. 16–32 trådar), inte sekventiellt.
  3. **Är målnätet on-link:** använd ARP-svepet som primär upptäckt (liveness+MAC
     över L2), i stället för att lita på ICMP-genom-tunneln. ICMP kan köras
     best-effort för RTT.
  4. **Är målnätet inte on-link:** som idag (ICMP/TCP), och **behåll varningen** —
     den är rätt just för genuint routade nät (VPN/router). Alltså: varna bara när
     subnätet *inte* finns på något lokalt kort; on-link-fallet löses av ARP-svepet
     i stället för en varning.

  **Test:** mot `.99.0/24` med Tailscale-routen aktiv ska `.118` m.fl. nu få MAC
  och stabil upptäckt utan att man rör Tailscale; ett äkta fjärrnät ska fortfarande
  ge varningen.

## Klart

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
