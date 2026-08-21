<#
  daily-update.ps1
  Taegliches Update des GPU-Rental-Dashboards.

  Ablauf:
   1) RTX-4090-Marktdaten holen (rentgpu.org + offene Preis-JSON).
   2) Neuen Tages-Snapshot an data/history.json anhaengen (nicht verifizierte
      Werte werden vom Vortag uebernommen).
   3) Denselben Stand in index.html (#history-data) spiegeln + Datenstand setzen.
   4) Aenderungen committen und auf main pushen.

  Manuell testen:  powershell -ExecutionPolicy Bypass -File scripts\daily-update.ps1
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Pfade -----------------------------------------------------------------
$root     = Split-Path -Parent $PSScriptRoot
$histPath = Join-Path $root 'data\history.json'
$htmlPath = Join-Path $root 'index.html'
$logPath  = Join-Path $PSScriptRoot 'last-run.log'
Set-Location $root

function Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $logPath -Value $line -Encoding UTF8
}

$today   = (Get-Date).ToString('yyyy-MM-dd')
$todayDE = (Get-Date).ToString('dd.MM.yyyy')
Log "=== Lauf gestartet fuer $today ==="

# --- Helfer: letzten Tageswert einer rentgpu-Chartkick-Serie lesen ---------
function Get-LastSeriesValue([string]$html, [string]$name) {
  $m = [regex]::Match($html, '"name":"' + [regex]::Escape($name) + '","data":\[\[(.*?)\]\]')
  if (-not $m.Success) { return $null }
  $inner = '[[' + $m.Groups[1].Value + ']]'
  $pts = [regex]::Matches($inner, '\["\d{4}-\d{2}-\d{2}",([0-9.]+)\]')
  if ($pts.Count -eq 0) { return $null }
  return [double]$pts[$pts.Count - 1].Groups[1].Value
}

# --- Historie laden + Carry-forward vom letzten Snapshot -------------------
$histRaw = Get-Content $histPath -Raw
$hist = $histRaw | ConvertFrom-Json
$last = $hist.snapshots[$hist.snapshots.Count - 1]
$m = @{}
foreach ($p in $last.metrics.PSObject.Properties) { $m[$p.Name] = $p.Value }
$notes = @()

# --- Quelle 1: rentgpu.org (Vast / Clore / io.net) -------------------------
try {
  $html = (Invoke-WebRequest -Uri 'https://rentgpu.org/gpus/nvidia-rtx-4090' -TimeoutSec 45 -UseBasicParsing).Content
  $vast  = Get-LastSeriesValue $html 'vast-ai'
  $clore = Get-LastSeriesValue $html 'clore-ai'
  $ionet = Get-LastSeriesValue $html 'io-net'
  if ($vast)  { $m['vast_median_usd'] = [math]::Round($vast, 3);  $m['vast_host_eur'] = [math]::Round($vast * 0.92, 3) }
  if ($clore) { $m['clore_usd']       = [math]::Round($clore, 3) }
  if ($ionet) { $m['ionet_usd']       = [math]::Round($ionet, 3) }
  Log ("rentgpu OK: vast={0} clore={1} ionet={2}" -f $vast, $clore, $ionet)
} catch {
  $notes += 'rentgpu nicht erreichbar (Marktplatz-Werte uebernommen)'
  Log ("rentgpu FEHLER: " + $_.Exception.Message)
}

# --- Quelle 2: offene Preis-JSON (RunPod Community / Spheron) ---------------
try {
  $j = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/adriannutiu/gpu-rental-prices/main/data/latest.json' -TimeoutSec 45
  $rp = ($j.offers | Where-Object { $_.gpu -match '4090' -and $_.provider -eq 'runpod'  -and $_.kind -eq 'community' } | Select-Object -First 1).usd_hr
  $sp = ($j.offers | Where-Object { $_.gpu -match '4090' -and $_.provider -eq 'spheron' } | Select-Object -First 1).usd_hr
  if ($rp) { $m['runpod_community_usd'] = [double]$rp; $m['runpod_host_eur'] = [math]::Round([double]$rp * 0.92 * 0.93, 3) }
  if ($sp) { $m['spheron_usd'] = [double]$sp }
  Log ("preis-JSON OK: runpod={0} spheron={1}" -f $rp, $sp)
} catch {
  $notes += 'preis-JSON nicht erreichbar (RunPod/Spheron uebernommen)'
  Log ("preis-JSON FEHLER: " + $_.Exception.Message)
}

$note = 'Automatischer Lauf.'
if ($notes.Count) { $note += ' ' + ($notes -join '; ') + '.' }

# --- Snapshot bauen (feste Feldreihenfolge) --------------------------------
$keys = @('vast_median_usd','vast_host_eur','runpod_community_usd','runpod_host_eur',
          'ionet_usd','spheron_usd','clore_usd','market_median_usd','vast_utilization_pct',
          'ionet_offers','clore_offers','inference_cagr_pct','aethir_arr_musd',
          'total_risk_score','new_4090_price_usd')
$metrics = [ordered]@{}
foreach ($k in $keys) { $metrics[$k] = $m[$k] }
$snap = [pscustomobject]@{ date = $today; note = $note; metrics = [pscustomobject]$metrics }

# heutiges Datum ersetzen oder anhaengen
$list = [System.Collections.ArrayList]@($hist.snapshots)
$idx = -1
for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].date -eq $today) { $idx = $i } }
if ($idx -ge 0) { $list[$idx] = $snap; Log "Snapshot $today ersetzt." }
else            { [void]$list.Add($snap); Log "Snapshot $today angehaengt." }
$hist.snapshots = $list

# --- history.json schreiben (UTF-8 ohne BOM) -------------------------------
$jsonOut = $hist | ConvertTo-Json -Depth 10
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($histPath, $jsonOut, $utf8)

# --- index.html spiegeln ---------------------------------------------------
$htmlText = Get-Content $htmlPath -Raw
$rxData = [regex]'(?s)(<script type="application/json" id="history-data">\s*).*?(\s*</script>)'
$htmlText = $rxData.Replace($htmlText, { param($mm) $mm.Groups[1].Value + $jsonOut + $mm.Groups[2].Value }, 1)
$rxDate = [regex]'(Datenstand: <b>)\d{2}\.\d{2}\.\d{4}(</b>)'
$htmlText = $rxDate.Replace($htmlText, { param($mm) $mm.Groups[1].Value + $todayDE + $mm.Groups[2].Value }, 1)
[System.IO.File]::WriteAllText($htmlPath, $htmlText, $utf8)
Log "index.html + history.json aktualisiert."

# --- Git commit + push -----------------------------------------------------
# Git schreibt Fortschritt auf stderr; deshalb hier EAP lockern und stattdessen
# den Exit-Code pruefen (verhindert falsche Fehlermeldungen im Log).
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
  git add -A *> $null
  $status = git status --porcelain
  if ([string]::IsNullOrWhiteSpace($status)) {
    Log "Keine Aenderungen zu committen."
  } else {
    git commit -m "Daily update $today" *> $null
    git push origin main *> $null
    if ($LASTEXITCODE -eq 0) { Log "Commit + Push OK." }
    else { Log "Git-Push Exit-Code $LASTEXITCODE (bitte Anmeldung/Netzwerk pruefen)." }
  }
} catch {
  Log ("Git FEHLER: " + $_.Exception.Message)
} finally {
  $ErrorActionPreference = $prevEAP
}

Log "=== Lauf beendet ==="
