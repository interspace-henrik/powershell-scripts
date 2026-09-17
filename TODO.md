# TODO

## Att göra

- [ ] **Set-ComputerText: icke-blockerande start + körbar från Ninja (SYSTEM/session 0)**

  **Problem:**
  1. `ShowDialog()` blockerar → anropande skalet fryser tills fönstret stängs,
     och overlayn är click-through/ostängbar → hänger tills timeout. Ett
     Ninja-jobb skulle fastna.
  2. GUI från **SYSTEM/session 0** (Ninjas default) når inte användarens
     skrivbord → overlayn syns inte.

  **Förslag – dela i launcher + worker:**
  1. Intern `-Overlay`-switch:
     - **Worker** (`-Overlay`): nuvarande WPF/ShowDialog-kod (blockerar, men i
       egen process — det är meningen).
     - **Launcher** (default): starta workern frikopplat
       (`Start-Process pwsh -WindowStyle Hidden -File $PSCommandPath -Overlay -Text …`),
       kort liveness-koll, **exit 0 vid lyckad start / non-zero annars**. Verifierat:
       launchern returnerar på ~1,7 s och overlayn lever vidare.
  2. **Sessionshantering:**
     - Interaktiv användare → frikoppla direkt (som ovan).
     - SYSTEM/session 0 → GUI kan inte ritas där. Två vägar:
       - a. **Enklast:** sätt Ninjas *Run As* = *Current Logged-on User*; då räcker
         den icke-blockerande launchern. Rekommenderas.
       - b. **Måste köra som SYSTEM:** relansera workern i aktiv konsol-session via
         en temporär schemalagd uppgift som körs som den inloggade användaren
         (`schtasks /ru <user> /it`, kör en gång, ta bort), eller
         `CreateProcessAsUser` + `WTSQueryUserToken` (mer kod).
     - Detektera kontext: `WindowsIdentity.GetCurrent().IsSystem`,
       `(Get-Process -Id $PID).SessionId -eq 0`, aktiv konsol-session via
       `WTSGetActiveConsoleSessionId`.
  3. **Skyddsräcken:** ingen inloggad användare → exit non-zero med tydligt
     meddelande. Ev. mutex mot dubbla overlays. Ett `-Stop` för att ta bort
     overlayn (den går annars inte att stänga) — bra för RMM-uppdatering/städning.
  4. **STA-guard** i workern (relansera `-STA` om tråden är MTA) — bälte och
     hängslen även om pwsh/5.1 är STA här.
  5. **Repo-krav:** kommentarbaserad hjälp (`.SYNOPSIS`/`.DESCRIPTION`/exempel),
     rad i `README.md`, och checka in scriptet (nu otrackat).

  **Test:** kör launchern → returnerar direkt (exit 0), overlay syns i
  användarsessionen; kör som SYSTEM utan inloggad användare → exit non-zero, inget
  hänger.
