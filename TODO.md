# TODO

## Att göra

- [ ] **Copy-ToSharePoint: skiftlägesokänsliga filter + standardexkludering av skräpfiler**

  **1. Bugg – filtren är skiftlägeskänsliga.** rclone matchar `--exclude`
  skiftlägeskänsligt, robocopy `/XF /XD` (och Windows) gör det inte. Verifierat:
  `-ExcludeFile thumbs.db` missar `Thumbs.db`, `-ExcludeDir node_modules` missar
  `Node_Modules`. **Fix:** skicka alltid `--ignore-case` (verifierat att båda då
  träffar).

  **2. Standardexkludering av Windows/Office-skräp**, sådant som OneDrive-klienten
  och Utforskaren ändå inte får med:
  - filer: `Thumbs.db`, `ehthumbs.db`, `desktop.ini`, `.DS_Store`, `~$*`
    (Offices låsfiler)
  - mappar: `$RECYCLE.BIN`, `System Volume Information` — annars "access denied"-fel
    när källan är en enhetsrot (`D:\`)

  På som standard, och visas på headerns `Exclude`-rad markerade som standard så att
  det syns vad som hoppas över. `-NoDefaultExcludes` stänger av dem.

  **Beslut:**
  - **A.** Ska `*.tmp` ingå i standardlistan? Förslag: nej, sådana filer kan vara
    riktig data. Lägg till själv med `-ExcludeFile *.tmp`.
  - **B.** Skräpfiler som redan laddats upp ligger kvar: copy/sync rör inte filer på
    målet som matchar ett exclude, inte ens med `-Mirror`. Antingen raderar du dem
    för hand i SharePoint, eller så lägger vi till en opt-in-switch som skickar
    rclones `--delete-excluded` tillsammans med `-Mirror`. Den raderar *allt* på
    målet som matchar ett exclude, alltså även dina egna `-ExcludeDir`-mönster, och
    kräver `-Force` eller en bekräftelse. Förslag: lägg till switchen.
