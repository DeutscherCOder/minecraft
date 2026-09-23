#Requires -Version 5.1
<#
.SYNOPSIS
  Dreamshift Modpack-Installer - richtet Minecraft 1.20.1 + Fabric + die 7 Mods ein.

.DESCRIPTION
  Idempotenter Installer auf Basis von config/mods.json (Manifest):
    - findet das .minecraft-Verzeichnis (%APPDATA%\.minecraft auf Windows)
    - installiert Fabric Loader per offiziellem CLI-Installer (ohne GUI)
    - behaelt korrekte Mods, verschiebt falsche/unbekannte .jar-Dateien
      mit Zeitstempel nach mods-backup/ und laedt fehlende Mods von Modrinth
    - gleicher Befehl kann beliebig oft ausgefuehrt werden, ohne Chaos

.PARAMETER GameDir
  Pfad zum Minecraft-Verzeichnis. Standard: %APPDATA%\.minecraft
  Im Test:     .\install.ps1 -GameDir "$env:TEMP\mc-fixture"
  Normal:      .\install.ps1

.PARAMETER Offline
  Nur die *lokalen* Regeln anwenden (Behalten/Backup), nichts herunterladen
  und Fabric nicht installieren. Nuetzlich zum Durchspielen der Backup-Logik.

.PARAMETER Force
  Auch dann neu herunterladen, wenn eine Datei bereits stimmt (Refresh).

.EXAMPLE
  .\install.ps1
  # Standard-Installation fuer einen echten Spieler.

.EXAMPLE
  .\install.ps1 -GameDir "$env:TEMP\mc-fixture" -Offline
  # Sandkasten-Test: kein Netz, kein Java, nur Datei-Logik.
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [switch]$Offline,
    [switch]$Force,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # schnelle Downloads via Invoke-WebRequest

# ---------------------------------------------------------------------------
# Konstanten aus den Config-Dateien
# ---------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
# install.ps1 liegt im Repo-Root, config/ ebenfalls -> direkt daneben suchen.
$RootDir     = $ScriptDir
$ConfigDir   = Join-Path $RootDir 'config'
$InstallerCfg = Join-Path $ConfigDir 'installer.json'
$ModsCfg      = Join-Path $ConfigDir 'mods.json'

$MinecraftVersion = '1.20.1'

function Assert-File([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Konfiguration fehlt: $What ($Path). Bitte komplettes Repo herunterladen (Releases ZIP), nicht nur das Script."
    }
}
Assert-File $InstallerCfg 'installer.json'
Assert-File $ModsCfg 'mods.json'

$global:InstallerJson = Get-Content -LiteralPath $InstallerCfg -Raw -Encoding UTF8 | ConvertFrom-Json
$global:ModsJson      = Get-Content -LiteralPath $ModsCfg      -Raw -Encoding UTF8 | ConvertFrom-Json

$LoaderVersion  = $InstallerJson.loader.version      # z.B. "0.19.5"
$FabricInstallerVersion = $InstallerJson.installer.version
$FabricInstallerName    = $InstallerJson.installer.name
$FabricInstallerUrl     = $InstallerJson.installer.url
$FabricInstallerSha1    = $InstallerJson.installer.sha1
$FabricInstallerSha512  = $InstallerJson.installer.sha512
$MinJava                = [int]$InstallerJson.loader.minJava
$MetaEula               = 'https://meta.fabricmc.net/v2/versions/game'

$BackupRoot = 'mods-backup'   # relativ zum GameDir
$ManifestName = 'mods-backup.manifest.json'

# ---------------------------------------------------------------------------
# Kleine Helfer
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-OK  ([string]$Message) { Write-Host ("  {0} {1}" -f [char]0x2713, $Message) -ForegroundColor Green }
function Write-INFO([string]$Message) { Write-Host ("  {0} {1}" -f [char]0x2022, $Message) -ForegroundColor DarkGray }
function Write-WARN([string]$Message) { Write-Host ("  {0} {1}" -f [char]0x26A0, $Message) -ForegroundColor Yellow }
function Write-FAIL([string]$Message) { Write-Host ("  {0} {1}" -f [char]0x2717, $Message) -ForegroundColor Red }

function Format-Size([double]$Bytes) {
    if ($Bytes -lt 1KB)  { return ("{0} B"   -f $Bytes) }
    if ($Bytes -lt 1MB)  { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB)  { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Get-ShortPath([string]$Path, [int]$Max = 46) {
    if ($Path.Length -le $Max) { return $Path }
    return '...' + $Path.Substring($Path.Length - ($Max - 3))
}

# SHA-1 + SHA-512 einer Datei (fuer grosse JARs ohne RAM-Explosion)
function Get-FileHashSafe([string]$Path, [string]$Algorithm) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($Algorithm -eq 'SHA1')   { $hash = [System.Security.Cryptography.SHA1]::Create() }
        else                          { $hash = [System.Security.Cryptography.SHA512]::Create() }
        try {
            $bytes = $hash.ComputeHash($stream)
            return -join ($bytes | ForEach-Object { $_.ToString('x2') })
        } finally { $hash.Dispose() }
    } finally { $stream.Dispose() }
}

function Test-JavaAvailable([int]$RequiredMajor) {
    foreach ($cmd in @('java.exe','java')) {
        try { $null = Get-Command $cmd -ErrorAction Stop } catch { continue }
        try {
            # java -version schreibt nach stderr -> 2>&1
            $verOut = (& $cmd -version 2>&1 | Out-String).Trim()
            if ($verOut -match '"(\d+)(?:\.(\d+))?') {
                $major = if ([int]$Matches[1] -eq 1) { [int]$Matches[2] } else { [int]$Matches[1] }
                if ($major -ge $RequiredMajor) { return $true }
            }
        } catch { continue }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Hilfe
# ---------------------------------------------------------------------------
if ($Help) {
@"
Dreamshift Modpack-Installer
============================

Nutzt:
  .\install.ps1                        Standard: %APPDATA%\.minecraft
  .\install.ps1 -GameDir "D:\mc-test"  anderes Minecraft-Verzeichnis
  .\install.ps1 -Offline               nur Backup-Regeln, nichts herunterladen
  .\install.ps1 -Force                 alle Mods neu herunterladen

Ablauf:
  1. Minecraft-Verzeichnis finden        (Standard %APPDATA%\.minecraft)
  2. Java pruefen                        (>= $MinJava)
  3. Fabric CLI-Installer laden/pruefen
  4. Fabric Loader $LoaderVersion installieren (idempotent)
  5. mods/ analysieren -> Behalten / Backup / Download anhand config/mods.json
  6. Zusammenfassung

Backup: falsche Versionen und unbekannte .jar-Dateien landen in
  %APPDATA%\.minecraft\mods-backup\<zeitstempel>\

"@ | Out-Host
    return
}

# ---------------------------------------------------------------------------
# 0) Ziel-Verzeichnis bestimmen
# ---------------------------------------------------------------------------
Write-Step 'Dreamshift Modpack-Installer (Minecraft 1.20.1 + Fabric)'

if (-not $GameDir) {
    if ($env:APPDATA) {
        # Windows: %APPDATA%\.minecraft  (auch nocheinmal explizit, falls $env:OS fehlt)
        $GameDir = Join-Path $env:APPDATA '.minecraft'
    } elseif ($env:HOME) {
        # Linux/macOS-Sandbox (CI)
        $GameDir = Join-Path $env:HOME '.minecraft'
    } else {
        $GameDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.minecraft'
    }
}

$GameDir = [System.IO.Path]::GetFullPath($GameDir)
Write-Host ('Ziel: ' + (Get-ShortPath $GameDir))
if (-not (Test-Path -LiteralPath $GameDir)) {
    $null = New-Item -ItemType Directory -Path $GameDir -Force
    Write-INFO 'Verzeichnis wurde angelegt.'
}

$ModsDir   = Join-Path $GameDir 'mods'
$BackupDir = Join-Path $GameDir $BackupRoot
if (-not (Test-Path -LiteralPath $ModsDir)) { $null = New-Item -ItemType Directory -Path $ModsDir -Force }

# ---------------------------------------------------------------------------
# Fabric-EULA / -Daten (nur Netzzugriff)
# ---------------------------------------------------------------------------
if ($Offline) {
    Write-WARN 'Offline-Modus: kein Download, keine Fabric-/Java-Installation. Nur Datei-Regeln.'
} else {
    # Windows 10 / PowerShell 5.1 braucht TLS 1.2 (default bis .NET 4.6)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $eulaOk = $false
    try {
        $meta = Invoke-RestMethod -Uri $MetaEula -UseBasicParsing -TimeoutSec 20 -ErrorAction SilentlyContinue
        $eulaOk = [bool]$meta
    } catch { $eulaOk = $false }
    if (-not $eulaOk) {
        throw "Minecraft-Metadaten nicht erreichbar ($MetaEula). Bitte Internetverbindung pruefen (oder -Offline zum reinen Datei-Test)."
    }
    Write-INFO "Metadaten erreichbar. Minecraft: $MinecraftVersion   Fabric Loader: $LoaderVersion"
}

# ---------------------------------------------------------------------------
# Java pruefen (bzw. installieren, falls fehlt)
# ---------------------------------------------------------------------------
if (-not $Offline) {
    $hasJava = Test-JavaAvailable $MinJava
    if (-not $hasJava) {
        Write-WARN "Java $MinJava (oder neuer) nicht gefunden - versuche Installation via winget."
        try {
            if (-not (Get-Command winget -ErrorAction Stop)) { throw 'winget fehlt' }
            winget install --id Oracle.JDK.17 --scope user --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
            if (-not (Test-JavaAvailable $MinJava)) { throw 'Java nach winget-Installation nicht verfuegbar' }
            Write-OK 'Java 17 wurde ueber winget installiert.'
        } catch {
            $jdkMsg = @(
                'Konnte Java nicht automatisch installieren.',
                'Bitte manuell installieren: https://adoptium.net/temurin/releases/?version=17',
                '   (Temurin JDK 17, .msi) - danach dieses Script erneut ausfuehren.',
                'oder fuer den reinen Logik-Test:  .\install.ps1 -Offline'
            ) -join [Environment]::NewLine
            throw $jdkMsg
        }
    } else {
        Write-OK 'Java vorhanden (>= 17).'
    }
}

# ---------------------------------------------------------------------------
# Fabric Loader installieren (idempotent)
# ---------------------------------------------------------------------------
if (-not $Offline) {
    $DownloadDir = Join-Path $GameDir '.cache'
    if (-not (Test-Path -LiteralPath $DownloadDir)) { $null = New-Item -ItemType Directory -Path $DownloadDir -Force }
    $FabricJar  = Join-Path $DownloadDir $FabricInstallerName
    $NeedDownload = $true

    if ($Force) { $NeedDownload = $true }
    elseif (Test-Path -LiteralPath $FabricJar) {
        $existingSha1 = (Get-FileHashSafe $FabricJar 'SHA1')
        if ($existingSha1 -eq $FabricInstallerSha1) { $NeedDownload = $false }
    }

    if ($NeedDownload) {
        Write-STEP ''
        Write-Host ("Lade Fabric-Installer {0} herunter ..." -f $FabricInstallerVersion)
        Invoke-WebRequest -Uri $FabricInstallerUrl -OutFile $FabricJar -UseBasicParsing
    }

    # Datei immer gegen die gepinnten Hashes pruefen
    $sha1   = Get-FileHashSafe $FabricJar 'SHA1'
    $sha512 = Get-FileHashSafe $FabricJar 'SHA512'
    if ($sha1 -ne $FabricInstallerSha1 -or $sha512 -ne $FabricInstallerSha512) {
        throw "Fabric-Installer ungueltig (Hash-Mismatch). Erwartet SHA-1 $FabricInstallerSha1, bekommen $sha1"
    }
    Write-OK ("Fabric-Installer {0} verifiziert (SHA-1/SHA-512)." -f $FabricInstallerVersion)

    # CLI-Aufruf: fully idempotent, legt Profile + versions/ an
    Write-STEP ("Installiere Fabric Loader {0} (CLI, ohne GUI) ..." -f $LoaderVersion)

    # Der offizielle Installer braucht eine Launcher-Profildatei, um das
    # "fabric-loader" Profil einzutragen. Falls keine existiert (frische/
    # Test-Verzeichnisse), legen wir eine leere an - wie es der Installer auch tut.
    $profilesWin32   = Join-Path $GameDir 'launcher_profiles.json'
    $profilesMsStore = Join-Path $GameDir 'launcher_profiles_microsoft_store.json'
    if (-not (Test-Path -LiteralPath $profilesWin32) -and -not (Test-Path -LiteralPath $profilesMsStore)) {
        Set-Content -LiteralPath $profilesWin32 -Value '{"profiles":{}}' -Encoding UTF8
        Write-INFO 'launcher_profiles.json angelegt (kein bestehendes Profil gefunden).'
    }

    $cliArgs = @('-jar', $FabricJar, 'client', '-dir', $GameDir, '-mcversion', $MinecraftVersion, '-loader', $LoaderVersion)
    & java @cliArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Fabric-Installer wurde mit Exit-Code $LASTEXITCODE beendet."
    }
    Write-OK 'Fabric Loader installiert.'
}

# ---------------------------------------------------------------------------
# Mods organisieren (idempotent, Manifest-basiert)
# ---------------------------------------------------------------------------
$mods = @($ModsJson.mods)

# Pfade normalisieren (jeder Mod braucht target + match)
foreach ($m in $mods) {
    $m | Add-Member -NotePropertyName 'TargetPath' -NotePropertyValue (Join-Path $ModsDir $m.filename) -Force
    if (-not $m.match) { $m | Add-Member -NotePropertyName 'match' -NotePropertyValue @() -Force }
}

# RegEx-Muster pro Mod vorbereiten (Dateiname in Kleinbuchstaben pruefen)
$regexes = @{}
foreach ($m in $mods) {
    $patterns = @()
    foreach ($p in $m.match) { $patterns += $p }
    $patterns += [regex]::Escape($m.filename)   # exakter Dateiname matcht immer
    $regexes[$m.id] = $patterns
}

$manifestPath = Join-Path $BackupDir $ManifestName

$actions    = @()   # {type, modId, from, to}
$stats      = @{ kept = 0; backedUp = 0; download = 0; refreshed = 0 }
$backupTime = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

# Path-Karte fuer das Backup-Manifest (Quelle -> Ziel)
$pathMap = @{}

# ---------------------------------------------------------------------------
# Schritt A: bekannte Mod-Dateien in mods/ identifizieren
# ---------------------------------------------------------------------------
$knownMap = @{}   # modId -> { m, fileInfo }
foreach ($file in (Get-ChildItem -LiteralPath $ModsDir -File -Filter '*.jar' -ErrorAction SilentlyContinue)) {
    $lower = $file.Name.ToLowerInvariant()
    $matched = $null
    foreach ($m in $mods) {
        foreach ($p in $regexes[$m.id]) {
            if ($lower -match $p) { $matched = $m; break }
        }
        if ($matched) { break }
    }
    if ($matched) {
        # letzte (neueste) bekannte Version gewinnt
        if (-not $knownMap.ContainsKey($matched.id)) { $knownMap[$matched.id] = @() }
        $knownMap[$matched.id] += $file
    }
}

# ---------------------------------------------------------------------------
# Schritt B: fuer jeden Mod entscheiden
# ---------------------------------------------------------------------------
foreach ($m in $mods) {
    $target = $m.TargetPath
    $targetExists = (Test-Path -LiteralPath $target -PathType Leaf)

    if ($targetExists -and -not $Force) {
        # exakter Dateiname vorhanden -> Pruefsumme pruefen
        $realSha1 = Get-FileHashSafe $target 'SHA1'
        if ($realSha1 -eq $m.sha1) {
            # korrekt -> behalten, aber danebenliegende andere Versionen trotzdem sichern
            $stats.kept++
        } else {
            # falscher Inhalt unter richtigem Namen -> Ersetzen noetig
            $actions += @{ type = 'replace'; modId = $m.id; from = $target; m = $m }
            $stats.refreshed++
        }
    } else {
        # fehlt (oder -Force) -> herunterladen (gezaehlt wird beim echten Download)
        $actions += @{ type = 'download'; modId = $m.id; m = $m }
    }

    # andere Versionen derselben Mod daneben -> Backup
    $others = if ($knownMap.ContainsKey($m.id)) { @($knownMap[$m.id]) } else { @() }
    foreach ($other in $others) {
        if ($other.FullName -eq $target) { continue }
        if ($actions | Where-Object { $_.from -and $_.from -eq $other.FullName }) { continue }
        $actions += @{ type = 'backup'; modId = $m.id; from = $other.FullName; m = $m }
    }
}

# ---------------------------------------------------------------------------
# Schritt C: unbekannte .jar-Dateien -> Backup
# ---------------------------------------------------------------------------
$allKnownFullNames = @{}
foreach ($m in $mods) { $allKnownFullNames[$m.TargetPath.ToLowerInvariant()] = $true }
foreach ($knownId in $knownMap.Keys) {
    foreach ($f in $knownMap[$knownId]) { $allKnownFullNames[$f.FullName.ToLowerInvariant()] = $true }
}

foreach ($file in (Get-ChildItem -LiteralPath $ModsDir -File -Filter '*.jar' -ErrorAction SilentlyContinue)) {
    if ($allKnownFullNames.ContainsKey($file.FullName.ToLowerInvariant())) { continue }
    $actions += @{ type = 'backup-unbekannt'; modId = $null; from = $file.FullName; m = $null }
}

# --- Backup-Ordner jetzt anlegen (Zeitstempel), falls noetig
$stampDir = $null
$needBackup = (@($actions | Where-Object { $_.type -like 'backup*' -or $_.type -eq 'replace' })).Count -gt 0
if ($needBackup) {
    $stampDir = Join-Path $BackupDir $backupTime
    if (-not (Test-Path -LiteralPath $stampDir)) { $null = New-Item -ItemType Directory -Path $stampDir -Force }
}

# ---------------------------------------------------------------------------
# Schritt D: ausfuehren (Backup zuerst, dann Downloads)
# ---------------------------------------------------------------------------
# D1: Dateien verschieben
foreach ($a in @($actions | Where-Object { $_.type -like 'backup*' -or $_.type -eq 'replace' })) {
    $name = Split-Path -Leaf $a.from
    $dest = Join-Path $stampDir $name
    # Namenskollision im Stamp-Ordner vermeiden
    $i = 2
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $stampDir ("{0}.{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($name), $i, [System.IO.Path]::GetExtension($name))
        $i++
    }
    Move-Item -LiteralPath $a.from -Destination $dest -Force
    $pathMap[$a.from.ToLowerInvariant()] = $dest
    if ($a.type -eq 'backup')      { $stats.backedUp++ ; Write-WARN ("Backup (andere Version): {0}" -f $name) }
    elseif ($a.type -eq 'replace') { $stats.backedUp++ ; Write-WARN ("Backup (defekt, wird ersetzt): {0}" -f $name) }
    else                           { $stats.backedUp++ ; Write-WARN ("Backup (unbekannt): {0}" -f $name) }
}

# D2: Downloads
foreach ($a in @($actions | Where-Object { $_.type -eq 'download' -or $_.type -eq 'replace' })) {
    $m = $a.m
    if ($Offline) {
        # Trockenlauf: nichts anfassen, nur protokollieren.
        # (Keine Platzhalter schreiben -> zweiter Lauf bleibt idempotent.)
        if ($a.type -eq 'replace') { Write-INFO ("Wuerde ersetzen (Offline): {0}" -f $m.filename) }
        else                        { Write-INFO ("Wuerde laden (Offline):    {0} {1}" -f $m.filename, $m.version) }
        continue
    }
    Write-Host ("Lade {0} {1} ({2}) ..." -f $m.title, $m.version, (Format-Size $m.size)) -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $m.url -OutFile $m.TargetPath -UseBasicParsing
    $sha1   = Get-FileHashSafe $m.TargetPath 'SHA1'
    $sha512 = Get-FileHashSafe $m.TargetPath 'SHA512'
    $ok = ($sha1 -eq $m.sha1) -or ($sha512 -eq $m.sha512)
    if (-not $ok) {
        Remove-Item -LiteralPath $m.TargetPath -Force -ErrorAction SilentlyContinue
        throw ("Pruefsumme fuer {0} stimmt nicht (SHA-1: erwartet {1}, bekommen {2}). Datei wurde verworfen." -f $m.filename, $m.sha1, $sha1)
    }
    if ($a.type -eq 'download') { $stats.download++ }

    Write-OK ("{0} {1} installiert." -f $m.title, $m.version)
}

# ---------------------------------------------------------------------------
# Schritt E: Backup-Manifest schreiben (fuer Transparenz)
# ---------------------------------------------------------------------------
if ($stampDir -and $pathMap.Count -gt 0) {
    $manifestData = [ordered]@{
        createdAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        minecraft  = $MinecraftVersion
        loader     = $LoaderVersion
        note       = 'Von install.ps1 automatisch gesicherte Mods (falsche Version / unbekannte JAR / defekte Datei).'
        movedFiles = @()
    }
    foreach ($entry in $pathMap.GetEnumerator()) {
        $manifestData.movedFiles += [ordered]@{
            movedFrom = $entry.Key
            movedTo   = $entry.Value
        }
    }
    $manifestData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Schritt F: Zusammenfassung
# ---------------------------------------------------------------------------
Write-STEP ''
Write-STEP '[Zusammenfassung]'
$total = $mods.Count
Write-Host ("  Benoetigte Mods: {0}" -f $total)
Write-Host ("  Behalten (korrekt): {0}" -f $stats.kept)
Write-Host ("  Gesichert   (Backup):  {0} Datei(en) -> mods-backup\{1}\" -f $stats.backedUp, $backupTime) -ForegroundColor Yellow
Write-Host ("  Geladen / aufgefrischt: {0}" -f ($stats.download + $stats.refreshed))
if ($Offline) {
    Write-WARN 'Offline-Test: Downloads/Fabric wurden uebersprungen.'
}
Write-STEP ''
Write-Host '  ' -NoNewline; Write-Host ('Minecraft 1.20.1 Fabric ist bereit. Viel Spass mit Dreamshift!') -ForegroundColor Green
