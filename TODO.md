# TODO

## Att göra

- [ ] **ICMP-svepet tappar levande värdar vid hög samtidighet (falska "ARP-only")**

  **Grundorsak (uppmätt):** `System.Net.NetworkInformation.Ping` är opålitlig
  när många asynkrona pings går parallellt mot olika adresser — svar från
  levande värdar tappas. Med scriptets default `-Throttle 32` missas ~50–75 % av
  ICMP-svaren; värdarna syns då bara via ARP. Mätning mot .1–.60:

  | Throttle | ICMP-träff (av 4 körn.) |
  |----------|-------------------------|
  | 1        | 4/4                     |
  | 8        | 2/4                     |
  | 16       | 1/4                     |
  | 32       | 1–2/4                   |

  192.168.99.12 och .20 svarade 30/30 på sekventiella pings men fick `ARP` i 7/8
  scriptkörningar med default throttle; med `-Throttle 4` gav de `ICMP+ARP` i
  3/3. Det är alltså inte strömsparläge på enheterna utan svepets parallellitet.

  **Förslag (två delar):**
  1. **Separat, lägre default-throttle för ICMP-svepet** (t.ex. 8), oberoende av
     `-Throttle` som styr TCP-scanet. Alternativt sänk gemensamma defaulten och
     dokumentera avvägningen tid vs. tillförlitlighet.
  2. **Retries per värd:** ny parameter `-IcmpRetries` (alias `-Count`, default
     2). Gör bara om-försök för adresser som ännu inte svarat, så kostnaden
     stannar på tysta värdar. Räkna som `ICMP` vid första lyckade svaret.

  **Test:** kör mot subnätet upprepat — .12/.20 ska konsekvent få `ICMP` i
  Method även med rimlig hastighet, inte bara vid `-Throttle 1`.

- [ ] **Visa resultatet som en tabell i slutet**

  **Nuläge:** scriptet skickar `[pscustomobject]` med 7 egenskaper till
  pipelinen (rad ~548 + `$sorted` rad ~567). Eftersom objekten har fler än 4
  egenskaper renderar PowerShell dem som lista (`Format-List`), inte tabell.

  **Förslag (behåller pipeline-kontraktet):** ge utdataobjekten ett eget
  typnamn, t.ex. `NetScan.Host` (via `PSTypeName` i `[pscustomobject]`), och
  registrera en standard-tabellvy med `Update-FormatData` /
  `Get-FormatData`-stil så att de *visas* som tabell men fortfarande är riktiga
  objekt (så `-CsvPath` och vidare pipelinehantering fungerar oförändrat).
  Kolumner: `IPAddress`, `MACAddress`, `HostName`, `Vendor`, `OpenPorts`,
  `Method`, `ResponseTimeMs`. Definiera kolumnbredder så att långa `HostName`/
  `Vendor` inte spränger bredden.

  **Enklare alternativ:** avsluta med `$sorted | Format-Table -AutoSize`. Nackdel:
  bryter "objects go to the pipeline" — `$x = .\Invoke-NetScan.ps1` fångar då
  formatobjekt, inte data. Går att mildra med en `-AsTable`-switch som bara då
  kör `Format-Table`.

  **Rekommendation:** typnamn + formatvy (första förslaget) — tabell på skärmen
  utan att förstöra dataflödet.

## Klart

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
