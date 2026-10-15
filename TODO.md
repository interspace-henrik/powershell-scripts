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

  **Beslut som behövs (styr designen):**
  - **A. Auth:** interaktiv OAuth (enkelt, kräver människa en gång) *eller* Azure
    AD-appregistrering (client id/secret, oövervakad körning)? Ska det kunna köras
    oövervakat?
  - **B. "Mappa upp":** riktig enhetsbokstav (`rclone mount` + WinFSP) att robocopa
    in i, *eller* räcker `rclone copy` direkt mot remoten? (Rekommendation: copy.)
  - **C. copy vs mirror default:** ska dest-filer som saknas i källan raderas
    (mirror) eller behållas (copy, default)?
  - **D. Källans credentials:** är nätverksenheten redan åtkomlig (inloggad/mappad),
    eller ska wrappern köra `net use` med angivna uppgifter?
  - **E. rclone-version:** pinna en version (reproducerbart) eller alltid senaste?

  **Repo-krav:** kommentarbaserad hjälp (`.SYNOPSIS`/`.DESCRIPTION`/exempel), rad i
  `README.md`.
