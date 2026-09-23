# Dreamshift – Minecraft 1.20.1 + Fabric Installer

Ein **idempotenter** Installer für **Minecraft 1.20.1 + Fabric** mit dem Mod-Set
**Dreamshift** und allen nötigen Abhängigkeiten. Die komplette „Intelligenz“
steckt in einem kleinen Manifest (`config/mods.json`): Der Installer behält
korrekte Dateien, verschiebt falsche/unbekannte `.jar`-Dateien **mit Zeitstempel**
nach `mods-backup/` und lädt fehlende Mods von Modrinth – beliebig oft
ausführbar, ohne Chaos.

## Kurzanleitung (Windows)

**Einfach installieren** — PowerShell öffnen (Win&nbsp;+&nbsp;R → `powershell`) und das hier einfügen:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; $i="$env:TEMP\dreamshift.zip"; Invoke-WebRequest -Uri 'https://github.com/DeutscherCOder/minecraft/archive/refs/heads/main.zip' -OutFile $i; Expand-Archive -Path $i -DestinationPath "$env:TEMP\dreamshift" -Force; & "$env:TEMP\dreamshift\minecraft-main\install.ps1"
```

… oder das Repo als **ZIP** laden, entpacken und `install.ps1` mit
„Rechtsklick → Mit PowerShell ausführen“ starten.

> **Zielverzeichnis:** Standard `%APPDATA%\.minecraft`.
> Ein anderes Verzeichnis (z. B. für Tests): `.\install.ps1 -GameDir "D:\mc-test"`.

## Das Mod-Set (7 Dateien)

| Mod | Version | Anmerkung |
| --- | --- | --- |
| Architectury API | 9.2.14 | Abhängigkeit von Dreamshift |
| Cloth Config API | 11.1.136 | Abhängigkeit von Dreamshift |
| Fabric API | 0.92.12+1.20.1 | exakt die Version aus deinem Screenshot |
| Immersive Portals | 5.2.0 | Abhängigkeit von Dreamshift |
| Sodium | 0.5.13 | Performance |
| Simple Voice Chat | 2.4.32 | letzter stabiler 1.20.1-Release (Ende 2023) |
| Dreamshift | 0.1.4.3.1 | ~491 MB – Download dauert einen Moment |

Alle URLs, SHA-1/SHA-512-Prüfsummen und Dateigrößen wurden am **2026-09-23**
gegen die Modrinth-/Fabric-APIs verifiziert und sind in `config/mods.json`
festgeschrieben.

## Wie der Installer entscheidet (Manifest-Regeln)

| Situation in `mods/` | Entscheidung |
| --- | --- |
| Gewünschte Datei, korrekte SHA-1/SHA-512 | **Behalten** |
| Gleiche Mod, andere Version (Dateiname-Muster `match`) | **Backup** → `mods-backup\<zeitstempel>\` |
| Unbekannte `.jar`-Datei | **Backup** → `mods-backup\<zeitstempel>\` |
| Gewünschte Mod fehlt / beschädigt | **Download** von Modrinth + Prüfsummen-Check |

Backups werden per Zeitstempel abgelegt (`mods-backup\2026-09-23_12-45-00\`) und
ein `mods-backup.manifest.json` protokolliert jede Verschobene Datei.

## Optionen von `install.ps1`

```powershell
.\install.ps1                        # Standard (echte Installation)
.\install.ps1 -GameDir "D:\mc-test"  # anderes Minecraft-Verzeichnis
.\install.ps1 -Offline               # nur Backup-Regeln, kein Netz/Java nötig
.\install.ps1 -Force                 # alle Mods neu laden
.\install.ps1 -Help                  # Hilfe
```

## Ablauf (die 6 Schritte)

1. **Zielverzeichnis** finden (`%APPDATA%\.minecraft`).
2. **Java** (≥ 17) prüfen – fehlt es, wird `winget install Oracle.JDK.17` versucht.
3. **Fabric CLI-Installer** (1.1.2) laden, SHA-1/SHA-512 prüfen.
4. **Fabric Loader** (`0.19.5`) per offiziellem CLI-Aufruf installieren:
   `java -jar fabric-installer-1.1.2.jar client -dir "…" -mcversion 1.20.1 -loader 0.19.5`
5. **mods/ analysieren** und jede Datei laut Manifest einstufen.
6. **Ausführen**: Behalten / Backup / Download + Prüfsummen-Check.

## Projektstruktur

```
.
├── install.ps1                      # Der Installer (konsumiert nur die Manifeste)
├── config/
│   ├── mods.json                    # Mod-Liste: URLs, Hashes, Größen, match-Muster  ← EINZIGE QUELLE
│   └── installer.json               # MC-Version, Loader, Fabric-Installer + Hashes
├── index.html / assets/             # GitHub-Pages-Website (rendert die Liste aus mods.json)
├── tests/
│   └── test-offline.ps1             # Offline-Selbsttest der Datei-Logik
└── .github/workflows/selftest.yml   # Echter Windows-Selbsttest (GitHub Actions)
```

Die Website (Pages) zeigt die Mod-Tabelle und die Copy-Paste-Kommandos –
**live gerendert aus derselben `config/mods.json`**, damit Installer und Seite
nie auseinanderlaufen.

## Selbsttest

- **Offline-Logik** (ohne Java/Netz): `pwsh -NoProfile -File tests\test-offline.ps1`
- **Echtes Windows-Setup**: automatisch per GitHub Actions
  (`.github/workflows/selftest.yml`) – lädt Modrinth-Mods, installiert Fabric,
  führt zwei Läufe für den Idempotenz-Check aus.

---

*Nicht zugehörig zu Mojang/Microsoft. Mods © jeweilige Autoren (Dreamshift: multision).*
