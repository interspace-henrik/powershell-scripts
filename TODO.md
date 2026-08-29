# TODO

## Att göra

- [ ] **Fixa `-Subnet` med CIDR (t.ex. /24) — kastar "Cannot convert value \"-256\" to type System.UInt32"**

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
