# powershell-scripts

Diverse PowerShell-script för Windows. Varje script är fristående och har fullständig hjälp inbyggd — kör `Get-Help .\<script>.ps1 -Full` för detaljer.

## Script

| Script | Beskrivning |
| --- | --- |
| [Install-PSPrompt.ps1](Install-PSPrompt.ps1) | Installerar en delad tvåradsprompt för Windows PowerShell 5.1 och PowerShell 7+, med git-status, admin-indikator, trunkerad sökväg och tid för långsamma kommandon. Skriver prompten till en delad fil och injicerar en markör-avgränsad stub i berörda profiler. Stöder `-Scope AllUsers` (begär själv admin via UAC), `CurrentUser` och `Auto`, samt `-Uninstall` och `-WhatIf`. |
| [Invoke-NetScan.ps1](Invoke-NetScan.ps1) | Upptäcker värdar på ett subnät (`-Subnet` CIDR) eller IP-intervall (`-StartIP`/`-EndIP`) via ICMP-svep, ARP-/grann-cache, valfri TCP-portscan, reverse-DNS och IEEE OUI-vendoruppslag. Emitterar ett objekt per värd (visas som tabell) och kan skriva CSV med `-CsvPath`. ICMP-svepet gör om-försök och använder en separat, lägre samtidighet (`-IcmpThrottle`/`-IcmpRetries`) för att inte tappa levande värdar. För lokala nät görs ett käll-bundet ARP-svep (`SendARP`) som hämtar MAC direkt över L2 och kringgår en ev. tunnel-route som annars stjäl trafiken (`-SourceAddress`/`-SkipArpSweep`). `-Slow` för IDS-vänlig takt, `-ArpOnly` för passiv avläsning av grann-cachen. |
