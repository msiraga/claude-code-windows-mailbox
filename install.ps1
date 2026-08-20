<#
  Installs the cross-session mailbox for Claude Code on Windows.

  Global: applies to EVERY project, not one repo. Nothing is written into any git
  repository. Safe to re-run -- it replaces only its own hook entries, preserves any
  hooks you added yourself, and backs up settings.json first.

      powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

  Registers four hooks:
    SessionStart  mailbox-register.ps1   auto-claim a name from the working directory
    SessionStart  mailbox-watch.ps1      long idle-wake watcher (7.5 h, inside an 8 h timeout)
    SessionEnd    mailbox-unregister.ps1 free the name, stop the watcher
    Stop          mailbox-stop.ps1       deliver queued mail at turn end
    Stop          mailbox-watch.ps1      idle-wake watcher (8 min), re-armed each turn
#>
$ErrorActionPreference = 'Stop'
$src      = Split-Path -Parent $MyInvocation.MyCommand.Path
$claude   = Join-Path $env:USERPROFILE '.claude'
$hooks    = Join-Path $claude 'hooks'
$mbox     = Join-Path $claude 'mailbox'
$settings = Join-Path $claude 'settings.json'
$utf8     = New-Object System.Text.UTF8Encoding($false)

Write-Host ""
Write-Host "Installing the cross-session mailbox to $claude" -ForegroundColor Cyan

foreach ($d in @($hooks, (Join-Path $mbox 'inbox'), (Join-Path $mbox 'log'))) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$scripts = @('mailbox-stop.ps1','mailbox-watch.ps1','mailbox-register.ps1','mailbox-unregister.ps1','mailbox-reap.ps1','mailbox-ccd.ps1','msg.ps1')
foreach ($s in $scripts) {
  $from = Join-Path $src ("hooks\" + $s)
  if (-not (Test-Path -LiteralPath $from)) { Write-Host "  MISSING in package: $s" -ForegroundColor Red; exit 1 }
  Copy-Item $from $hooks -Force
}
Write-Host ("  copied " + $scripts.Count + " scripts") -ForegroundColor Green

if (Test-Path -LiteralPath $settings) {
  $backup = "$settings.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $settings $backup -Force
  Write-Host "  settings backed up -> $backup" -ForegroundColor Green
  $cfg = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
} else {
  $cfg = New-Object PSObject
}

function New-HookEntry($file, $extraArgs, $isAsync, $timeout) {
  $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $hooks $file))
  if ($extraArgs) { $a += $extraArgs }
  $h = [ordered]@{ type = 'command'; command = 'powershell.exe'; args = $a }
  if ($isAsync) { $h['async'] = $true; $h['asyncRewake'] = $true }
  if ($timeout) { $h['timeout'] = $timeout }
  return $h
}

$want = @{
  'SessionStart' = @(
    (New-HookEntry 'mailbox-register.ps1' $null                    $false $null),
    (New-HookEntry 'mailbox-watch.ps1'    @('-MaxSeconds','27000') $true  28800)
  )
  'SessionEnd' = @(
    (New-HookEntry 'mailbox-unregister.ps1' $null $false 10)
  )
  'Stop' = @(
    (New-HookEntry 'mailbox-stop.ps1'     $null                $false $null),
    (New-HookEntry 'mailbox-register.ps1' $null                $false 15),
    (New-HookEntry 'mailbox-watch.ps1' @('-MaxSeconds','480')   $true  600)
  )
}

if (-not ($cfg.PSObject.Properties.Name -contains 'hooks')) {
  $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
}

foreach ($ev in @('SessionStart','Stop','SessionEnd')) {
  $existing = @()
  if ($cfg.hooks.PSObject.Properties.Name -contains $ev) { $existing = @($cfg.hooks.$ev) }

  # Drop only OUR previous entries so a re-run upgrades instead of duplicating.
  # Anything you added yourself is kept untouched.
  $kept = @()
  foreach ($grp in $existing) {
    $inner = @()
    foreach ($h in @($grp.hooks)) {
      $isOurs = $false
      foreach ($s in $scripts) { if ("$($h.args)" -like "*$s*") { $isOurs = $true } }
      if (-not $isOurs) { $inner += $h }
    }
    if ($inner.Count -gt 0) { $kept += [ordered]@{ matcher = $grp.matcher; hooks = $inner } }
  }

  $kept += [ordered]@{ matcher = ''; hooks = $want[$ev] }
  $cfg.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $kept -Force
  Write-Host ("  registered " + $want[$ev].Count + " hook(s) on $ev") -ForegroundColor Green
}

[System.IO.File]::WriteAllText($settings, ($cfg | ConvertTo-Json -Depth 12), $utf8)

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host "  Sessions auto-register by working-directory name at session start."
Write-Host "  To opt this machine out of auto-registration, create:"
Write-Host ("     " + (Join-Path $mbox 'NO_AUTO_REGISTER'))
Write-Host ""
Write-Host "Verify with:" -ForegroundColor Cyan
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $src 'verify.ps1') + "`"")
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $hooks 'msg.ps1') + "`" status")
Write-Host ""
Write-Host "Start a NEW session for the hooks to take effect." -ForegroundColor Yellow
Write-Host ""
