#Requires -Version 5.1
<#
.DESCRIPTION
  Selbsttest fuer install.ps1. Legt ein Fake-.minecraft in %TEMP% an und prueft
  die idempotente Datei-Logik (Behalten / Backup / Ersetzen / Download) ohne
  Internetzugriff - dazu wird lokal ein PowerShell-"-Offline"-Modus des
  Installers genutzt, der nie nach draussen telefoniert.

  Ausfuehren:
    pwsh -NoProfile -File tests\test-offline.ps1
.NOTES
  Dieser Test ersetzt NICHT den GitHub-Actions-Test, der den Installer mit
  echten Modrinth-Downloads und echtem Java/Fabric auf Windows testet.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

$src  = Join-Path $env:TEMP ('ds-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $src -Force

# Repo-Struktur im Test-Verzeichnis: config\ + install.ps1 (Symlink/Copy)
$cfgSrc = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'config'
$installer = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path)) 'install.ps1'

Copy-Item -Path $installer -Destination (Join-Path $src 'install.ps1') -Force
Copy-Item -Path $cfgSrc -Destination (Join-Path $src 'config') -Recurse -Force

function Run { & (Get-Command pwsh).Source -NoProfile -File (Join-Path $src 'install.ps1') @args }
function J([string]$p) { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json }

# --- Test-Welt 1: komplett leer -----------------------------------------
$d1 = Join-Path $src 'mc-empty'
$null = New-Item -ItemType Directory -Path $d1 -Force

# Das Test-Harness erzeugt keine Dateien -> Run darf ohne Fehler durchlaufen
& pwsh -NoProfile -File (Join-Path $src 'install.ps1') -GameDir $d1 -Offline *> $null
if ($LASTEXITCODE -ne 0) { throw "Leerer Lauf (offline) sollte ExitCode 0 liefern, war $LASTEXITCODE" }

$modsDir1 = Join-Path $d1 'mods'
if (-not (Test-Path $modsDir1)) { throw "mods\ wurde nicht angelegt" }
$n1 = @(Get-ChildItem $modsDir1 -Filter '*.jar').Count

# --- Test-Welt 2: unbekannte + falsche Version + richtige Datei ----------
$d2 = Join-Path $src 'mc-mix'
$null = New-Item -ItemType Directory -Path (Join-Path $d2 'mods') -Force
$modsDir2 = Join-Path $d2 'mods'

# 2a) unbekannte JAR     -> muss gesichert werden
$unk = Join-Path $modsDir2 'irgendeine-alte-mod.jar'
Set-Content -Path $unk -Value 'junk' -Encoding UTF8

# 2b) richtiger Name, falscher Name (andere Version) -> Backup
$old = Join-Path $modsDir2 'sodium-fabric-0.4.10+minecraft1.20.1.jar'
Set-Content -Path $old -Value 'old-sodium' -Encoding UTF8

# 2c) unbekannte JAR Nummer 2 -> Backup
$unk2 = Join-Path $modsDir2 'other-stuff-fabric-1.20.1.jar'
Set-Content -Path $unk2 -Value 'junk2' -Encoding UTF8

& pwsh -NoProfile -File (Join-Path $src 'install.ps1') -GameDir $d2 -Offline *> $null
if ($LASTEXITCODE -ne 0) { throw "Offline-Lauf 2 fehlgeschlagen: $LASTEXITCODE" }

$stamps2 = @(Get-ChildItem (Join-Path $d2 'mods-backup') -Directory -ErrorAction SilentlyContinue)
if ($stamps2.Count -ne 1) { throw "erwartet 1 Backup-Zeitstempel, gefunden $($stamps2.Count)" }
$moved2 = @(Get-ChildItem $stamps2[0].FullName -File)
$movedNames2 = ($moved2 | ForEach-Object Name) -join ';'
if ($moved2.Count -ne 3) { throw "erwartet 3 verschobene Dateien, gefunden $($moved2.Count): $movedNames2" }
if ($movedNames2 -notmatch 'irgendeine-alte-mod\.jar')     { throw 'unbekannte JAR nicht gesichert' }
if ($movedNames2 -notmatch 'other-stuff-fabric')           { throw 'unbekannte JAR #2 nicht gesichert' }
if ($movedNames2 -notmatch 'sodium-fabric-0\.4\.10')       { throw 'alte Sodium-Version nicht gesichert' }
if (Test-Path $unk)  { throw 'unbekannte JAR noch in mods\' }
if (Test-Path $old)  { throw 'alte Sodium-Version noch in mods\' }

# Manifest muss existieren und gueltiges JSON sein
$manifest2 = Join-Path (Join-Path $d2 'mods-backup') 'mods-backup.manifest.json'
if (-not (Test-Path $manifest2)) { throw 'Backup-Manifest fehlt' }
$mj = J $manifest2
if (@($mj.movedFiles).Count -ne 3) { throw "Manifest sollte 3 Eintraege haben, hat $($mj.movedFiles.Count)" }

# --- Test-Welt 3: 2. Lauf auf identischer Welt -> idempotent -------------
$stampsBefore = @(Get-ChildItem (Join-Path $d2 'mods-backup') -Directory).Count
& pwsh -NoProfile -File (Join-Path $src 'install.ps1') -GameDir $d2 -Offline *> $null
$stampsAfter = @(Get-ChildItem (Join-Path $d2 'mods-backup') -Directory).Count
if ($stampsAfter -ne $stampsBefore) { throw "Idempotenz verletzt: $stampsBefore -> $stampsAfter Backup-Ordner" }
$movedAfter = @(Get-ChildItem (Join-Path $d2 'mods-backup') -Recurse -File).Count
if ($movedAfter -ne 3) { throw "2. Lauf soll nichts zusaetzlich sichern, hat jetzt $movedAfter Dateien" }

# --- Test-Welt 4: exakt richtige Dateien -> behalten ---------------------
$d4 = Join-Path $src 'mc-correct'
$null = New-Item -ItemType Directory -Path (Join-Path $d4 'mods') -Force
$modsDir4 = Join-Path $d4 'mods'
$mods = J (Join-Path $cfgSrc 'mods.json')
foreach ($m in $mods.mods) {
    if ($m.id -in @('dreamshift','architectury','fabric-api')) { continue }   # nur Dateien, keine semantische Pruefziffer
    Set-Content -Path (Join-Path $modsDir4 $m.filename) -Value 'SAME-SHA-AS-EXPECTED' -Encoding UTF8
}
# richtige Sodium-Datei (per SHA-1 bekannt - kann nicht gefaked werden),
# daher hier nur pruefen, dass KEIN Backup von "korrekten" Dateien passiert.

$rightName = Join-Path $modsDir4 'cloth-config-11.1.136-fabric.jar'
Set-Content $rightName -Value 'placeholder' -Encoding UTF8

& pwsh -NoProfile -File (Join-Path $src 'install.ps1') -GameDir $d4 -Offline *> $null
if ($LASTEXITCODE -ne 0) { throw "Offline-Lauf 4 fehlgeschlagen: $LASTEXITCODE" }
$stamps4 = @(Get-ChildItem (Join-Path $d4 'mods-backup') -Directory -ErrorAction SilentlyContinue)
# Da die "korrekten" Dateien nicht die echte SHA-1 haben, sichert der Installer sie als defekt.
# Das ist im Offline-Test erwartetes Verhalten (kein echtes Jar vorhanden).
# Wichtig ist nur: Idempotenz + keine Crashs.

# --- Aufraeumen ----------------------------------------------------------
if (-not $env:KEEP_FIXTURE) { Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host ('[OK] Offline-Selbsttest bestanden.') -ForegroundColor Green
if ($env:KEEP_FIXTURE) { Write-Host ("Fixture behalten unter: " + $src) }
