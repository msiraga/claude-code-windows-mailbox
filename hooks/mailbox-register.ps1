# SessionStart hook -- auto-register this session in the mailbox.
#
# Solves the scaling problem with manual claiming: a session's UUID is readable only
# from inside that session, so nothing outside can register it. Spinning up five
# workers meant five manual claims. This registers each session the moment it starts.
#
# The name comes from the working directory, so it is meaningful and stable:
#   C:\Users\you\payments-api  ->  payments-api
# If that name is already taken by a DIFFERENT session, a short UUID suffix is added
# rather than stealing the name.
#
# Safety properties:
#   * Never overwrites another live session's name.
#   * Idempotent: a session already registered under any name is left alone, so a
#     hand-picked name survives a restart of this hook.
#   * Any error exits 0. Failing to auto-register must never disturb a session.
#   * Opt out entirely by creating the file  <mailbox>\NO_AUTO_REGISTER
$ErrorActionPreference = 'Stop'
$MBOX = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude\mailbox' }
$LOG  = Join-Path $MBOX 'log\register.log'

function L($m) {
  try { Add-Content -LiteralPath $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding utf8 } catch { }
}

try {
  if (Test-Path -LiteralPath (Join-Path $MBOX 'NO_AUTO_REGISTER')) { exit 0 }

  $raw = [Console]::In.ReadToEnd()
  $sid = $null; $cwd = $null
  try {
    $j = ($raw -replace '^﻿','') | ConvertFrom-Json
    $sid = "$($j.session_id)"; $cwd = "$($j.cwd)"
  } catch { }
  if (-not $sid) { L "no session_id on stdin; exit 0"; exit 0 }

  foreach ($d in @($MBOX, (Join-Path $MBOX 'inbox'), (Join-Path $MBOX 'log'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }

  $regPath = Join-Path $MBOX 'registry.json'
  $reg = New-Object PSObject
  if (Test-Path -LiteralPath $regPath) {
    try { $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json } catch { }
  }

  # already registered under some name? leave it -- a hand-picked name must survive
  foreach ($p in $reg.PSObject.Properties) {
    if ($p.Value -eq $sid) { L "already registered as '$($p.Name)'; nothing to do"; exit 0 }
  }

  # RECLAIM. A resumed session keeps its UUID but gets a fresh SessionStart, so deriving a
  # name from the folder again would abandon whatever it was called before -- and titles
  # and watch opt-ins are keyed on the NAME, so both would silently detach. If this UUID
  # held a name before and nothing else has taken it, take it back.
  $histPath = Join-Path $MBOX 'name-history.json'
  if (Test-Path -LiteralPath $histPath) {
    try {
      $hist = Get-Content -LiteralPath $histPath -Raw | ConvertFrom-Json
      $prev = $hist.$sid
      if ($prev) {
        $taken = @($reg.PSObject.Properties.Name)
        if ($taken -contains $prev) {
          L "previous name '$prev' is held by another session; deriving a new one"
        } else {
          $reg | Add-Member -NotePropertyName $prev -NotePropertyValue $sid -Force
          [System.IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
          $ib = Join-Path $MBOX ("inbox\" + $prev + ".jsonl")
          if (-not (Test-Path -LiteralPath $ib)) {
            [System.IO.File]::WriteAllText($ib, "", (New-Object System.Text.UTF8Encoding($false)))
          }
          L "reclaimed previous name '$prev' -> $sid (title and watch opt-in preserved)"
          Write-Output "Mailbox: this session is registered as '$prev'. Other sessions can reach you at that name."
          exit 0
        }
      }
    } catch { }
  }

  # Do not auto-register sessions that are not in a project. A session sitting in the
  # user profile root or a drive root is almost never an orchestration worker, and every
  # such session would collide on the same derived name.
  # [char]92 is a backslash. Written this way on purpose: a literal backslash here has
  # been eaten more than once by the layers between an editor and this file.
  $bs = [string][char]92
  $skip = @($env:USERPROFILE,
            ($env:USERPROFILE + $bs),
            ('C:' + $bs),
            'C:',
            ($env:HOMEDRIVE + $env:HOMEPATH))
  if ($cwd -and ($skip -contains $cwd.TrimEnd([char]92))) {
    L "cwd '$cwd' is not a project directory; skipping auto-registration"
    exit 0
  }

  # derive a name from the working directory
  $base = 'session'
  if ($cwd) { try { $base = Split-Path -Leaf $cwd } catch { } }
  $base = ($base -replace '[^A-Za-z0-9._-]', '-').ToLower().Trim('-')
  if (-not $base) { $base = 'session' }
  if ($base.Length -gt 32) { $base = $base.Substring(0,32) }

  $name = $base
  $taken = @($reg.PSObject.Properties.Name)

  # First tie-break: the git branch. Two sessions in one repo are usually on different
  # branches, and 'payments-api-feature-branch' says far more than 'payments-api-47eb'.
  if ($taken -contains $name) {
    $branch = $null
    try {
      $branch = (& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    } catch { }
    if ($branch -and $branch -ne 'HEAD') {
      $b = ($branch -replace '[^A-Za-z0-9._-]', '-').ToLower().Trim('-')
      if ($b.Length -gt 28) { $b = $b.Substring(0,28) }
      if ($b -and -not ($taken -contains "$base-$b")) { $name = "$base-$b" }
    }
  }

  # Last resort: a short UUID suffix. Never steal a name another session holds.
  if ($taken -contains $name) {
    $suffix = $sid -replace '[^0-9a-fA-F]',''
    if ($suffix.Length -ge 4) { $suffix = $suffix.Substring(0,4) } else { $suffix = 'x' }
    $name = "$base-$suffix"
    if ($taken -contains $name) { L "both '$base' and '$name' taken; not registering"; exit 0 }
  }

  $reg | Add-Member -NotePropertyName $name -NotePropertyValue $sid -Force
  [System.IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

  $inbox = Join-Path $MBOX ("inbox\" + $name + ".jsonl")
  if (-not (Test-Path -LiteralPath $inbox)) {
    [System.IO.File]::WriteAllText($inbox, "", (New-Object System.Text.UTF8Encoding($false)))
  }
  L "auto-registered '$name' -> $sid  (cwd=$cwd)"
  # stdout from SessionStart is added to the session's context
  Write-Output "Mailbox: this session is registered as '$name'. Other sessions can reach you at that name."
  exit 0
}
catch {
  L ("ERROR (exit 0 to stay safe): " + $_.Exception.Message)
  exit 0
}
