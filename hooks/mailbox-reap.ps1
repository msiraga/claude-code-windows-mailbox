# Reaper -- remove registry entries for sessions that are gone.
#
# WHY THIS EXISTS
# SessionEnd is the fast path for freeing a name, but it does not always fire: a CLI
# session exited normally and never unregistered, so its name stayed held and the next
# session in that folder got a UUID suffix. Left alone the registry grows without bound,
# every name gets consumed, and meaningful names stop being possible.
#
# LIVENESS, CAREFULLY
# An idle session is not a dead one. Two signals, and BOTH must say dead:
#   * no FIRED line in hook-fired.log within $ReapHours
#   * no watcher lock (a live watcher refreshes its lock every poll)
# Sessions registered within $GraceMinutes are never touched, so a session still
# starting up cannot be reaped out from under itself.
#
# SELF-HEALING
# Being wrong here is survivable: mailbox-register.ps1 also runs on Stop, so a session
# that is wrongly reaped re-registers at its next turn. That is why this can afford to
# act at all rather than only ever warn.
#
# Safety: any error exits 0. Reaping is housekeeping; it must never break a session.
param(
  [int]$ReapHours = 12,
  [int]$GraceMinutes = 30,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$MBOX = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude\mailbox' }
$LOG  = Join-Path $MBOX 'log\register.log'

function L($m) {
  try { Add-Content -LiteralPath $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding utf8 } catch { }
}

try {
  $regPath = Join-Path $MBOX 'registry.json'
  if (-not (Test-Path -LiteralPath $regPath)) { exit 0 }
  $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json

  $now      = Get-Date
  $reapCut  = $now.AddHours(-$ReapHours)
  $graceCut = $now.AddMinutes(-$GraceMinutes)

  # last time each session id fired the hook
  $lastFire = @{}
  $fired = Join-Path $MBOX 'log\hook-fired.log'
  if (Test-Path -LiteralPath $fired) {
    foreach ($line in (Get-Content -LiteralPath $fired -Encoding utf8)) {
      $m = [regex]::Match($line, '^(\S+)\s+FIRED session=([0-9a-fA-F-]{36})')
      if ($m.Success) {
        try { $lastFire[$m.Groups[2].Value] = [datetime]::Parse($m.Groups[1].Value) } catch { }
      }
    }
  }

  # when each name was registered, so a starting session is inside its grace period
  $registeredAt = @{}
  if (Test-Path -LiteralPath $LOG) {
    foreach ($line in (Get-Content -LiteralPath $LOG -Encoding utf8)) {
      $m = [regex]::Match($line, "^(\S+)\s+auto-registered '([^']+)'")
      if ($m.Success) {
        try { $registeredAt[$m.Groups[2].Value] = [datetime]::Parse($m.Groups[1].Value) } catch { }
      }
    }
  }

  $reaped = @()
  foreach ($p in @($reg.PSObject.Properties)) {
    $name = $p.Name
    $sid  = "$($p.Value)"

    # never reap something that still has a live watcher
    $lock = Join-Path $MBOX ("watch-" + $name + ".lock")
    if (Test-Path -LiteralPath $lock) {
      $age = ($now - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds
      if ($age -lt 120) { continue }
    }

    $seen = $null
    if ($lastFire.ContainsKey($sid)) { $seen = $lastFire[$sid] }

    if ($seen) {
      if ($seen -gt $reapCut) { continue }          # fired recently enough: alive
      $reason = "last fired $([int]($now - $seen).TotalHours)h ago"
    } else {
      # never fired at all. Only reap once past the grace period.
      $regAt = $null
      if ($registeredAt.ContainsKey($name)) { $regAt = $registeredAt[$name] }
      if ($regAt -and $regAt -gt $graceCut) { continue }   # too new to judge
      if (-not $regAt) { continue }                        # unknown age: leave it alone
      $reason = "never fired the hook, registered $([int]($now - $regAt).TotalMinutes)m ago"
    }

    $reaped += [pscustomobject]@{ Name = $name; Sid = $sid; Reason = $reason }
  }

  if ($reaped.Count -eq 0 -and $DryRun) { Write-Output "nothing to reap from the registry" }

  foreach ($r in $reaped) {
    if ($DryRun) { Write-Output ("would reap {0,-24} {1}" -f $r.Name, $r.Reason); continue }
    $reg.PSObject.Properties.Remove($r.Name)
    L "reaped '$($r.Name)' -- $($r.Reason)"
    Write-Output ("reaped {0,-24} {1}" -f $r.Name, $r.Reason)
  }
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
  }

  # Sweep orphaned inbox files. Registering creates an inbox, so sessions that come and go
  # leave one behind; they accumulate faster than registry entries do.
  #
  # THREE conditions, all required, because deleting mail is not recoverable:
  #   * the name is not in the registry (no live session owns it)
  #   * the name is not in name-history (no resuming session can reclaim it)
  #   * the inbox holds NO unread messages, at any age
  # An inbox with unread mail is never touched, even if its session is long gone -- that
  # mail is the record of something nobody read.
  try {
    $histPath2 = Join-Path $MBOX 'name-history.json'
    $reclaimable = @()
    if (Test-Path -LiteralPath $histPath2) {
      try {
        $h2 = Get-Content -LiteralPath $histPath2 -Raw | ConvertFrom-Json
        foreach ($hp2 in $h2.PSObject.Properties) { $reclaimable += "$($hp2.Value)" }
      } catch { }
    }
    $liveNames = @($reg.PSObject.Properties.Name)
    $swept = 0
    Get-ChildItem (Join-Path $MBOX 'inbox') -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object {
      $nm = $_.BaseName
      if ($liveNames -contains $nm)   { return }
      if ($reclaimable -contains $nm) { return }
      $unread = 0
      foreach ($line in (Get-Content -LiteralPath $_.FullName -Encoding utf8 -ErrorAction SilentlyContinue)) {
        $x = $line -replace '^﻿',''
        if ($x.Trim() -eq '') { continue }
        try { if (-not ($x | ConvertFrom-Json).read) { $unread++ } } catch { $unread++ }
      }
      if ($unread -gt 0) { return }
      if ($DryRun) { Write-Output ("would sweep inbox {0}" -f $nm); return }
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      $swept++
    }
    if ($swept -gt 0) {
      L "swept $swept orphaned inbox file(s)"
      Write-Output "swept $swept orphaned inbox file(s)"
    }
  } catch { L ("inbox sweep skipped: " + $_.Exception.Message) }

  exit 0
}
catch {
  L ("reap ERROR (exit 0 to stay safe): " + $_.Exception.Message)
  exit 0
}
