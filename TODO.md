# TODO

## Att göra

- [ ] **ICMP-svepet: flera försök per värd (minska falska "ARP-only")**

  **Problem:** `Invoke-PingSweep` skickar exakt ETT eko per värd (rad ~328). En
  värd som tappar det paketet (t.ex. Wi-Fi-enhet i strömsparläge, randomiserad
  MAC) registreras som ICMP-miss och syns bara via ARP, trots att den lever och
  besvarar `ping.exe` (som default skickar 4 paket). Bekräftat i test:
  192.168.99.12 pendlar mellan `ARP` och `ICMP+ARP` mellan körningar.

  **Förslag:** ny parameter `-IcmpRetries` (alias `-Count`, default 2). För varje
  värd, försök upp till N gånger och räkna som `ICMP` vid första lyckade svaret;
  spara första lyckade RTT. Behåll batch/throttle-strukturen — enklast att göra
  om-försöken bara för adresser som ännu inte svarat efter batchens första varv,
  så att kostnaden stannar på faktiskt tysta/tappande värdar och inte fördubblar
  svepet för alla. `-Slow` kan sätta ett något högre default (t.ex. 3).

  **Test:** kör mot subnät med en känd Wi-Fi-enhet upprepade gånger — den ska nu
  konsekvent få `ICMP` i Method i stället för att pendla.

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
