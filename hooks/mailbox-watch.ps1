# Layer 1 -- idle-wake watcher.  Stop hook, registered with async + asyncRewake.
#
# Runs in the background after a turn ends. Polls this session's inbox. When mail
# arrives it emits the FRAMED payload on stderr and exits 2, which wakes the idle
# session. On timeout it exits 0 and no wake occurs.
#
# The framing is produced by invoking the real mailbox-stop.ps1, not by reimplementing
# it, so push delivery and wake delivery cannot drift apart -- and that call also marks
# the messages read, so the synchronous hook will not redeliver them.
#
# Safety properties, all deliberate:
#   * One watcher per session, enforced by a lock file. A stale lock is stolen only
#     after it exceeds its own maximum lifetime.
#   * Wakes ONLY when there is real unread mail. A quiet poll exits 0 and costs nothing.
#   * Bounded: stops polling well before the configured hook timeout.
#   * Any error exits 0, so a fault here can never wake or trap a session.
#   * An unregistered session exits immediately and is never watched.
param(
  # How long this watcher polls before giving up. Stop hooks pass a short window
  # (re-armed every turn); the SessionStart hook passes a long one to cover idleness.
  [int]$MaxSeconds = 240
)
$ErrorActionPreference = 'Stop'

$MBOX      = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude\mailbox' }
$LOG       = Join-Path $MBOX 'log\watch.log'
$POLL_SEC  = 5     # how often to check the inbox
$MAX_SEC   = $MaxSeconds   # caller-supplied; must stay inside the hook timeout
$LOCK_TTL  = 60    # a live watcher refreshes its lock every poll, so a lock older than
                   # this belongs to a dead process regardless of how long the watcher
                   # was meant to run. Do NOT tie this to MAX_SEC.
$VERSION   = 10     # bumped on every change. A running watcher keeps the code it started
                   # with for up to MAX_SEC, so the version in the log tells you which
                   # script actually produced a line.
$WAKE_CAP  = 10    # max autonomous wakes per session inside the window below
$WAKE_WIN  = 300   # sliding window, seconds
$REG_WAIT  = 30    # seconds to wait for our own registration to appear (parallel hooks)

function L($m) {
  try { Add-Content -LiteralPath $LOG -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding utf8 } catch { }
}

$lock = $null
try {
  $raw = [Console]::In.ReadToEnd()
  $sid = $null
  try { $sid = "$((($raw -replace '^﻿','') | ConvertFrom-Json).session_id)" } catch { }
  if (-not $sid) { L "no session_id on stdin; exit 0"; exit 0 }

  # Wait for this session to appear in the registry before giving up.
  #
  # SessionStart hooks run in PARALLEL, so this watcher and mailbox-register.ps1 start at
  # the same instant. Exiting immediately on "not registered" meant the watcher always
  # lost that race and died ~1s in, before registration finished -- so the long
  # SessionStart watcher never actually ran for any session, and sessions were only ever
  # watched after their first Stop. Retry instead of assuming.
  $regPath = Join-Path $MBOX 'registry.json'
  $me = $null
  $waited = 0
  while ($waited -le $REG_WAIT) {
    if (Test-Path -LiteralPath $regPath) {
      try {
        $reg = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json
        foreach ($p in $reg.PSObject.Properties) { if ($p.Value -eq $sid) { $me = $p.Name; break } }
      } catch { }
    }
    if ($me) { break }
    Start-Sleep -Seconds 2
    $waited += 2
  }
  # Genuinely unregistered (auto-registration skipped it, or it never claimed): not an
  # error, just nothing to watch.
  if (-not $me) { exit 0 }
  if ($waited -gt 0) { L "$me : registration appeared after ${waited}s" }

  # OPT-IN. A watcher is a long-lived polling process; one per registered session does
  # not scale. Auto-registration happily registers every session that opens in a project
  # folder, and watching all of them produced 18 concurrent watchers, 549 MB, and ten
  # dead locks -- at which point real messages stopped being delivered.
  #
  # So watching is opt-in: a session receives mail at turn boundaries for free, and gets
  # a background watcher only when someone says it is part of an orchestration.
  #   msg.ps1 watch <name>     opt in
  #   msg.ps1 unwatch <name>   opt out
  $watchedPath = Join-Path $MBOX 'watched.json'
  $isWatched = $false
  if (Test-Path -LiteralPath $watchedPath) {
    try {
      $w = Get-Content -LiteralPath $watchedPath -Raw | ConvertFrom-Json
      if (@($w) -contains $me) { $isWatched = $true }
    } catch { }
  }
  if (-not $isWatched) { exit 0 }

  # one watcher per session
  $lock = Join-Path $MBOX ("watch-" + $me + ".lock")
  if (Test-Path -LiteralPath $lock) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds
    if ($age -lt $LOCK_TTL) { L "$me : watcher already running (lock age ${age}s); exit 0"; exit 0 }
    L "$me : stealing stale lock (age ${age}s)"
  }
  Set-Content -LiteralPath $lock -Value $sid -Encoding utf8

  $inbox = Join-Path $MBOX ("inbox\" + $me + ".jsonl")
  $hook  = Join-Path (Split-Path -Parent $PSCommandPath) 'mailbox-stop.ps1'
  L "$me : watching for up to ${MAX_SEC}s (watcher v$VERSION)"

  # WALL-CLOCK deadline, not a count of sleeps. Counting sleeps drifts: every iteration
  # costs the sleep PLUS the work, so a 540-iteration loop overran its 600s hook timeout
  # and was killed mid-flight -- no exit log, a leaked lock, and the session went dark.
  $started  = Get-Date
  $deadline = $started.AddSeconds($MAX_SEC)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $POLL_SEC
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    # keep the lock warm: proves liveness to any watcher that starts while we run
    try { (Get-Item -LiteralPath $lock).LastWriteTime = Get-Date } catch { }

    # Lifecycle: a long watcher must not outlive its session. SessionEnd removes this
    # session from the registry, so a missing entry means "stop watching". Checked every
    # poll, which also frees the name for reuse promptly.
    $stillThere = $false
    try {
      $r2 = Get-Content -LiteralPath $regPath -Raw | ConvertFrom-Json
      foreach ($p2 in $r2.PSObject.Properties) { if ($p2.Value -eq $sid) { $stillThere = $true; break } }
    } catch { $stillThere = $true }   # unreadable registry is transient; do not exit on it
    if (-not $stillThere) {
      L "$me : no longer registered (session ended); stopping watcher after ${elapsed}s"
      Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
      exit 0
    }

    $unread = 0
    if (Test-Path -LiteralPath $inbox) {
      foreach ($line in (Get-Content -LiteralPath $inbox -Encoding utf8)) {
        $t = $line -replace '^﻿',''
        if ($t.Trim() -eq '') { continue }
        try { if (-not ($t | ConvertFrom-Json).read) { $unread++ } } catch { }
      }
    }
    if ($unread -eq 0) { continue }

    # RATE CAP -- checked BEFORE the hook is called, which matters: the hook marks
    # messages read. Tripping the cap must not consume the mail. When capped we exit
    # without touching it, so the message stays unread and the synchronous hook still
    # delivers it at the session's next real turn. A cap trip degrades this to
    # trigger-based delivery; it never drops a message.
    $wlog = Join-Path $MBOX ("log\wakes-" + $me + ".log")
    $recent = 0
    if (Test-Path -LiteralPath $wlog) {
      $cut = (Get-Date).AddSeconds(-$WAKE_WIN)
      foreach ($t in (Get-Content -LiteralPath $wlog -Encoding utf8)) {
        if ($t.Trim() -eq '') { continue }
        try { if ([datetime]::Parse(($t -replace '^﻿','')) -gt $cut) { $recent++ } } catch { }
      }
    }
    if ($recent -ge $WAKE_CAP) {
      L "$me : RATE CAP -- $recent wakes in last ${WAKE_WIN}s (cap $WAKE_CAP). Not waking. Mail left UNREAD for the next real turn."
      Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
      exit 0
    }

    # Real mail, under the cap. Get the framed payload from the hook itself, which also
    # marks it read.
    L "$me : $unread unread after ${elapsed}s -- waking ($recent/$WAKE_CAP wakes in window)"
    # BOM-free: Add-Content -Encoding utf8 writes a BOM on PS 5.1. The reader strips it,
    # but a writer that never emits one is the safer half of that pair.
    [System.IO.File]::AppendAllText($wlog, ((Get-Date -Format 'o') + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $payload = (@{ session_id = $sid; cwd = 'mailbox-watch'; hook_event_name = 'Stop' } | ConvertTo-Json -Compress)
    $out = $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    if ($out) {
      $reason = (($out -join '') | ConvertFrom-Json).reason
      [Console]::Error.WriteLine($reason)
      exit 2
    }
    # someone else collected it between the poll and the call; nothing to wake for
    L "$me : mail was already collected; exit 0"
    exit 0
  }

  L "$me : quiet for ${MAX_SEC}s; exit 0 (no wake)"
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue

  # Housekeeping on the quiet path only. Drops READ messages older than $KEEP_DAYS and
  # trims logs. Unread mail is never touched, at any age.
  try {
    $KEEP_DAYS = 7
    $KEEP_LINES = 2000
    $cutoff = (Get-Date).AddDays(-$KEEP_DAYS)
    if (Test-Path -LiteralPath $inbox) {
      $keep = @(); $dropped = 0
      foreach ($line in (Get-Content -LiteralPath $inbox -Encoding utf8)) {
        $t = $line -replace '^﻿',''
        if ($t.Trim() -eq '') { continue }
        $m = $null
        try { $m = $t | ConvertFrom-Json } catch { $keep += $t; continue }
        if (-not $m.read) { $keep += $t; continue }          # never drop unread
        $old = $false
        try { $old = ([datetime]::Parse($m.ts)) -lt $cutoff } catch { }
        if ($old) { $dropped++ } else { $keep += $t }
      }
      if ($dropped -gt 0) {
        [System.IO.File]::WriteAllText($inbox, (($keep -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        L "$me : pruned $dropped read message(s) older than ${KEEP_DAYS}d"
      }
    }
    foreach ($lf in @($LOG, (Join-Path $MBOX 'log\hook-fired.log'), $(Join-Path $MBOX ("log\wakes-" + $me + ".log")))) {
      if (-not (Test-Path -LiteralPath $lf)) { continue }
      $all = @(Get-Content -LiteralPath $lf -Encoding utf8)
      if ($all.Count -gt $KEEP_LINES) {
        $tail = $all[($all.Count - $KEEP_LINES)..($all.Count - 1)]
        [System.IO.File]::WriteAllText($lf, (($tail -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        L ("trimmed " + (Split-Path -Leaf $lf) + " from " + $all.Count + " to $KEEP_LINES lines")
      }
    }
  } catch { L ("prune skipped: " + $_.Exception.Message) }

  # Reap dead registry entries on the same quiet path. SessionEnd is the fast way to
  # free a name; this is the backstop for when it does not fire.
  try {
    $reaper = Join-Path (Split-Path -Parent $PSCommandPath) 'mailbox-reap.ps1'
    if (Test-Path -LiteralPath $reaper) {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reaper | Out-Null
    }
  } catch { L ("reap skipped: " + $_.Exception.Message) }
  exit 0
}
catch {
  L ("ERROR (exit 0 to stay safe): " + $_.Exception.Message)
  if ($lock) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
  exit 0
}
