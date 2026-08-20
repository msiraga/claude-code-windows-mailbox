# SessionEnd hook -- remove this session from the mailbox registry.
#
# Two jobs, both about lifecycle:
#   1. Free the name, so the next session in that folder can take it cleanly instead
#      of getting a UUID suffix forever.
#   2. Tell the watcher to stop. A long watcher re-reads the registry every poll and
#      exits when its own session is gone, so removing the entry IS the stop signal.
#      No flag file, no second mechanism to keep in sync.
#
# SessionEnd hooks share a small time budget, so this must be fast: one small read,
# one small write, no subprocesses.
#
# Safety: any error exits 0. Failing to unregister leaves a stale entry and a watcher
# that ages out on its own -- untidy, never harmful.
$ErrorActionPreference = 'Stop'
$MBOX = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude\mailbox' }
$LOG  = Join-Path $MBOX 'log\register.log'

function L($m) {
  try { Add-Content -LiteralPath $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding utf8 } catch { }
}

try {
  $raw = [Console]::In.ReadToEnd()
  $sid = $null
  try { $sid = "$((($raw -replace '^﻿','') | ConvertFrom-Json).session_id)" } catch { }
  if (-not $sid) { exit 0 }

  $regPath = Join-Path $MBOX 'registry.json'
  if (-not (Test-Path -LiteralPath $regPath)) { exit 0 }

  $reg = $null
  try { $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json } catch { exit 0 }

  $mine = $null
  foreach ($p in $reg.PSObject.Properties) { if ($p.Value -eq $sid) { $mine = $p.Name; break } }
  if (-not $mine) { exit 0 }

  # Remember which name this UUID held. A session that resumes keeps its UUID but would
  # otherwise re-derive a fresh name from its folder -- silently detaching its title and
  # its watch opt-in, both of which are keyed on the name. Recording the binding here lets
  # registration reclaim it.
  $histPath = Join-Path $MBOX 'name-history.json'
  $hist = New-Object PSObject
  if (Test-Path -LiteralPath $histPath) {
    try { $hist = Get-Content -LiteralPath $histPath -Raw | ConvertFrom-Json } catch { }
  }
  $hist | Add-Member -NotePropertyName $sid -NotePropertyValue $mine -Force
  [System.IO.File]::WriteAllText($histPath, ($hist | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

  $reg.PSObject.Properties.Remove($mine)
  [System.IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
  L "unregistered '$mine' (session ended) -- name remembered for this UUID, watcher will stop on next poll"

  # The inbox file is deliberately NOT deleted. Mail addressed to a session that has
  # just ended should still be visible to a human, and pruning removes it on age.
  exit 0
}
catch {
  L ("unregister ERROR (exit 0 to stay safe): " + $_.Exception.Message)
  exit 0
}
