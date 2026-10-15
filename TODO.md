# TODO

## Att göra

- [ ] **Copy-ToSharePoint.ps1 — rclone-wrapper: nätverksenhet → SharePoint**

  **Mål:** kopiera filer från en nätverksenhet (UNC/mappad enhet) till ett
  SharePoint-dokumentbibliotek, med rclone i botten, självnedladdning av
  beroenden, robocopy-liknande UX och en progressbar.

  **Arkitektur (förslag):**
  1. **Beroenden:** wrappern kollar efter `rclone.exe`; saknas den → ladda ner
     Windows-zip från rclone.org, extrahera till en tools-dir
     (`%LOCALAPPDATA%\rclone`), verifiera version. (WinFSP behövs bara om vi
     monterar som enhet — se beslut B.)
  2. **SharePoint-remote:** rclones **onedrive-backend mot dokumentbibliotek**
     (Microsoft Graph/OAuth, modern auth) — inte legacy WebDAV/"sharepoint". Första
     körningen konfigurerar remoten (site-URL + bibliotek) och kör OAuth en gång;
     token cachas i `rclone.conf`.
     **Tenant-agnostiskt:** inget hårdkodat per tenant. Parametrar: `-SiteUrl`
     (`https://<tenant>.sharepoint.com/sites/<site>`), `-Library` (t.ex. "Documents"/
     "Delade dokument"), valfri `-TargetPath` (undermapp i biblioteket), och
     `-RemoteName`/`-ConfigPath` så flera tenants kan ha var sin cachad remote/token
     sida vid sida. Finns remoten redan konfigurerad återanvänds den; annars körs
     OAuth-setup för just den.
  3. **Kopiering:** `rclone copy` (eller `rclone sync` med `-Mirror`) från källa →
     bibliotek. Robocopy → rclone-mappning:
     - `/MIR` → `-Mirror` (`sync`, **raderar extra på dest** — var försiktig)
     - `/R:n /W:n` → `-Retries` / `--low-level-retries`
     - `/MT` → `-Transfers` / `-Checkers`
     - `/XF /XD` → `-ExcludeFile` / `-ExcludeDir` (rclone `--exclude`)
     - `/LOG` → `-LogFile` (`--log-file`)
     - `/L` → `-WhatIf` (`--dry-run`)
     - `/Z` (restartbar) → rclone chunkad/resumbar transfer inbyggt + checksum
  4. **Progressbar:** default rclone `--progress` (inbyggd live-bar). Alternativ:
     PowerShell `Write-Progress` genom att parsa `--use-json-log --stats 1s` för en
     mer robocopy-integrerad känsla.
  5. **Körläge:** troligen interaktivt. Oövervakad körning (Ninja/schemalagt) kräver
     app-registrering — se beslut A.

  **Beslut:**
  - **A. Auth:** ✅ interaktiv OAuth (rclone öppnar webbläsaren en gång, token
    cachas). Oövervakad körning via app-registrering sparas till senare om det behövs.
  - **B. Uppmappning:** ✅ `rclone copy` direkt mot remoten — ingen monterad enhet/
    WinFSP. robocopy-känslan via flaggor/UX.
  - **C. copy vs mirror:** copy (icke-förstörande) som default; `-Mirror` som opt-in
    med varning + `-WhatIf`-rekommendation (sync raderar extra på dest).
  - **D. Källans credentials:** anta åtkomlig; valfri `-SourceCredential` som kör
    `net use` vid behov.
  - **E. rclone-version:** pinna känd-fungerande version; `-UpdateRclone`-switch för
    senaste.

  **Repo-krav:** kommentarbaserad hjälp (`.SYNOPSIS`/`.DESCRIPTION`/exempel), rad i
  `README.md`.
