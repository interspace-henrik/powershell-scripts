# powershell-scripts

Diverse PowerShell-script för Windows. Varje script är fristående och har fullständig hjälp inbyggd — kör `Get-Help .\<script>.ps1 -Full` för detaljer.

## Script

| Script | Beskrivning |
| --- | --- |
| [Install-PSPrompt.ps1](Install-PSPrompt.ps1) | Installerar en delad tvåradsprompt för Windows PowerShell 5.1 och PowerShell 7+, med git-status, admin-indikator, trunkerad sökväg och tid för långsamma kommandon. Skriver prompten till en delad fil och injicerar en markör-avgränsad stub i berörda profiler. Stöder `-Scope AllUsers` (begär själv admin via UAC), `CurrentUser` och `Auto`, samt `-Uninstall` och `-WhatIf`. |
