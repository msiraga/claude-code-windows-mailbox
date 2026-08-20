# Layer 0 cross-session mailbox CLI.
#
#   msg.ps1 claim  <name> <session-id>          register this session under a name
#   msg.ps1 send   <name> <text> [<from>]       queue a message for that name
#   msg.ps1 read   <name>                       collect unread WITH framing (marks read)
#   msg.ps1 rename <old> <new>                  rename a session (moves its inbox too)
#   msg.ps1 prune  [days]                       drop READ mail older than N days (never unread)
#   msg.ps1 title  <name> ["Display Title"]     human title shown on message cards
#   msg.ps1 status                              registry, inbox depth, hook-fire log
#
# <from> attributes the sender. Precedence: 4th argument > $env:MAILBOX_MSG_FROM >
# 'unattributed'. Prefer the argument -- MAILBOX_MSG_FROM does NOT persist between
# PowerShell invocations.
#
# A <from> matching a registered name is delivered as a known PEER. Anything else is
# delivered as UNVERIFIED. There is no 'from the user' framing: the user speaks in
# chat, not through a file.
#
# NEVER read an inbox .jsonl file directly. Doing so delivers content WITHOUT the framing
# that carries authority, and leaves messages unread so the hook redelivers them -- you get
# every message twice and cannot tell a redelivery from a new one. Use 'read' instead.
#
# Env: MAILBOX_DIR overrides the mailbox root (default %USERPROFILE%\.claude\mailbox).
#      Point it at a scratch directory to test without touching live state.
param([Parameter(Position=0)][string]$cmd,
      [Parameter(Position=1)][string]$a,
      [Parameter(Position=2)][string]$b,
      [Parameter(Position=3)][string]$From)
$ErrorActionPreference = 'Stop'
$MBOX = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude\mailbox' }
$reg  = Join-Path $MBOX 'registry.json'

$titlesPath  = Join-Path $MBOX 'titles.json'
$watchedPath = Join-Path $MBOX 'watched.json'
function Load-Watched {
  if (Test-Path -LiteralPath $watchedPath) {
    try { return @((Get-Content -LiteralPath $watchedPath -Raw | ConvertFrom-Json)) } catch { }
  }
  return @()
}
function Save-Watched($list) {
  [System.IO.File]::WriteAllText($watchedPath, (@($list) | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
function Load-Reg {
  if (Test-Path -LiteralPath $reg) { return (Get-Content -LiteralPath $reg -Raw | ConvertFrom-Json) }
  return (New-Object PSObject)
}

function Load-History {
  # uuid -> the mailbox name it last held. Written when a session ends.
  $h = Join-Path $MBOX 'name-history.json'
  if (Test-Path -LiteralPath $h) {
    try { return (Get-Content -LiteralPath $h -Raw | ConvertFrom-Json) } catch { }
  }
  return (New-Object PSObject)
}

# Watching costs a background process per session. Auto-watching every send target is
# what makes "message that session" work without a separate setup step, but unbounded
# it is also what once put 18 watchers and half a gigabyte on this machine and stopped
# delivery outright. The cap is the load-shedding.
$WATCH_CAP = 8

# Session titles have two sources. titles.json is hand-set, and is the ONLY source for a
# session started from the `claude` CLI -- the desktop app writes no metadata file for
# those. For everything else the app's own session files are authoritative: they follow a
# rename, so unlike a hand-set title they cannot quietly go stale. Desktop wins where both
# exist. If the bridge is missing or unreadable, this degrades to exactly the old
# hand-set behaviour rather than failing.
$ccdLib = Join-Path (Split-Path -Parent $PSCommandPath) 'mailbox-ccd.ps1'
$script:HasCcd = $false
if (Test-Path -LiteralPath $ccdLib) { try { . $ccdLib; $script:HasCcd = $true } catch { } }

function Get-LiveMap {
  # Cached for the life of this process: scanning the app's session files costs ~0.6s.
  if ($null -ne $script:LiveCache) { return $script:LiveCache }
  $script:LiveCache = @{}
  if ($script:HasCcd) {
    try { $script:LiveCache = Get-CcdByMailboxName (Load-Reg) } catch { $script:LiveCache = @{} }
  }
  return $script:LiveCache
}

function Get-Live([string]$key) {
  $m = Get-LiveMap
  if ($m.ContainsKey($key)) { return $m[$key] }
  return $null
}

function Find-EndedByTitle([string]$wanted) {
  # A title visible on screen can belong to a session that is NOT in the registry --
  # usually because it has ended. "not a registered session" reads as a typo and sends
  # people hunting for the wrong problem, so identify it and say what actually happened.
  # Returns @{ Cli; Rec; LastName } or $null. Only a unique match counts.
  if (-not $script:HasCcd) { return $null }
  try {
    $n = Normalize $wanted
    if (-not $n) { return $null }
    $regUuids = @((Load-Reg).PSObject.Properties.Value)
    $hits = @()
    $all = Get-CcdSessions
    foreach ($cli in $all.Keys) {
      if ($regUuids -contains $cli) { continue }
      if ((Normalize $all[$cli].Title) -eq $n) { $hits += $cli }
    }
    if ($hits.Count -ne 1) { return $null }
    $cli = $hits[0]
    $last = $null
    try { $last = (Load-History).$cli } catch { }
    return @{ Cli = $cli; Rec = $all[$cli]; LastName = $last }
  } catch { }
  return $null
}

function Load-Titles {
  if ($null -ne $script:TitlesCache) { return $script:TitlesCache }
  $t = New-Object PSObject
  if (Test-Path -LiteralPath $titlesPath) {
    try { $t = Get-Content -LiteralPath $titlesPath -Raw | ConvertFrom-Json } catch { }
  }
  try {
    $live = Get-LiveMap
    foreach ($k in $live.Keys) {
      $t | Add-Member -NotePropertyName $k -NotePropertyValue $live[$k].Title -Force
    }
  } catch { }
  $script:TitlesCache = $t
  return $t
}


function Normalize([string]$s) {
  # "Messaging #2" -> "messaging-2".  Lower-case, non-alphanumerics to dashes,
  # collapse runs, trim. Lets a human type the session title they see on screen.
  if (-not $s) { return '' }
  $x = $s.ToLower() -replace '[^a-z0-9]+', '-'
  return $x.Trim('-')
}

function Resolve-Name([string]$wanted) {
  # Returns the canonical registry key, or $null. Exact match wins, then normalized
  # match, then unique prefix. Ambiguity is reported rather than guessed.
  #
  # Diagnostics go to Write-Host, NEVER Write-Output: anything written to the output
  # stream inside a PowerShell function becomes part of its return value, and a
  # diagnostic returned as a name gets used as a filename.
  $script:ResolveAmbiguous = $false
  $r = Load-Reg
  $keys = @($r.PSObject.Properties.Name)

  # -contains is case-insensitive, so return the KEY, not the caller's casing
  foreach ($k in $keys) { if ($k -ceq $wanted) { return $k } }
  foreach ($k in $keys) { if ($k -eq  $wanted) { return $k } }

  $n = Normalize $wanted
  if (-not $n) { return $null }

  # Display titles resolve too. status prints the title on the registry line, so people
  # naturally address it -- and having the tool show a name it then refuses is a trap.
  $ti = Load-Titles
  $byTitle = @()
  foreach ($tp in $ti.PSObject.Properties) {
    if ((Normalize $tp.Value) -eq $n -and ($keys -contains $tp.Name)) { $byTitle += $tp.Name }
  }
  if ($byTitle.Count -eq 1) { return $byTitle[0] }
  if ($byTitle.Count -gt 1) { $script:ResolveAmbiguous = $true; Write-Host ("AMBIGUOUS title '$wanted' matches: " + ($byTitle -join ', ')) -ForegroundColor Yellow; return $null }

  $hits = @($keys | Where-Object { (Normalize $_) -eq $n })
  if ($hits.Count -eq 1) { return $hits[0] }
  if ($hits.Count -gt 1) { $script:ResolveAmbiguous = $true; Write-Host ("AMBIGUOUS '$wanted' matches: " + ($hits -join ', ')) -ForegroundColor Yellow; return $null }

  $pre = @($keys | Where-Object { (Normalize $_).StartsWith($n) })
  if ($pre.Count -eq 1) { return $pre[0] }
  if ($pre.Count -gt 1) { $script:ResolveAmbiguous = $true; Write-Host ("AMBIGUOUS '$wanted' matches: " + ($pre -join ', ')) -ForegroundColor Yellow; return $null }

  return $null
}

switch ($cmd) {
  'claim' {
    if (-not $a -or -not $b) { Write-Output "usage: msg.ps1 claim <name> <session-id>"; exit 1 }
    $r = Load-Reg
    $r | Add-Member -NotePropertyName $a -NotePropertyValue $b -Force
    [System.IO.File]::WriteAllText($reg, ($r | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $ib = Join-Path $MBOX ("inbox\" + $a + ".jsonl")
    if (-not (Test-Path -LiteralPath $ib)) { New-Item -ItemType File -Path $ib | Out-Null }
    Write-Output "claimed '$a' -> $b"
  }
  'send' {
    if (-not $a -or -not $b) { Write-Output "usage: msg.ps1 send <name> <text> [<from>]"; exit 1 }
    $target = Resolve-Name $a
    if (-not $target) {
      $allNames = ((Load-Reg).PSObject.Properties.Name -join ', ')
      if ($script:ResolveAmbiguous) {
        Write-Output "ERROR: '$a' is ambiguous. Nothing was queued -- say which one you mean."
        Write-Output "       Registered: $allNames"
        exit 1
      }
      $ended = Find-EndedByTitle $a
      if ($ended) {
        $when = if ($ended.Rec.LastActivityAt) { $ended.Rec.LastActivityAt.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
        Write-Output "ERROR: '$($ended.Rec.Title)' is a real session, but it is not registered right now."
        Write-Output "       Last activity: $when.  A session registers at its next turn, so this one"
        Write-Output "       has almost certainly ended rather than been renamed."
        if ($ended.LastName) {
          Write-Output "       It last held the mailbox name '$($ended.LastName)', and reclaims that name if"
          Write-Output "       it resumes. To leave mail waiting for that:"
          Write-Output "         msg.ps1 send $($ended.LastName) ""your text"" <your-name>"
        }
        Write-Output "       Nothing was queued."
        exit 1
      }
      if ($a -match '^[A-Za-z0-9._-]+$') {
        Write-Output "WARNING: '$a' is not a registered session; queuing under that literal name."
        Write-Output "         Registered: $allNames"
        $target = $a
      } else {
        Write-Output "ERROR: '$a' did not resolve to exactly one session, and is not usable as a literal name."
        Write-Output "       Registered: $allNames"
        exit 1
      }
    } elseif ($target -ne $a) {
      Write-Output "resolved '$a' -> '$target'"
    }
    $a = $target
    $ib = Join-Path $MBOX ("inbox\" + $a + ".jsonl")
    # precedence: explicit arg > env var > unattributed
    $sender = $From
    if (-not $sender) { $sender = $env:MAILBOX_MSG_FROM }
    if (-not $sender) {
      $sender = 'unattributed'
      Write-Output "NOTE: no sender given. Pass it as the 4th argument to attribute this message."
      Write-Output "      An unattributed message is delivered as UNVERIFIED, not as user input."
    }
    $m = @{ from = $sender; ts = (Get-Date -Format 'o'); text = $b; read = $false }
    [System.IO.File]::AppendAllText($ib, (($m | ConvertTo-Json -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "queued for '$a' (inbox now $(@(Get-Content -LiteralPath $ib | Where-Object {$_.Trim() -ne ''}).Count) line(s))"

    # Queuing is not delivering. An unwatched session collects mail only when it next
    # finishes a turn, which for an idle session can be never -- so say which case this is
    # instead of letting "queued" imply it arrived.
    $isReg = ((Load-Reg).PSObject.Properties.Name -contains $a)
    $live  = Get-Live $a
    if ($live -and $live.IsArchived) {
      Write-Output "NOTE: '$a' is ARCHIVED in the desktop app; it reads this only if reopened."
    }
    if ($isReg) {
      $w = @(Load-Watched)
      if ($w -contains $a) {
        Write-Output "wake: '$a' is watched -- if its watcher is running, this arrives without a turn."
      } elseif ($w.Count -lt $WATCH_CAP) {
        Save-Watched ($w + $a)
        Write-Output "wake: '$a' was not watched. Now watching it -- but its watcher only starts at that"
        Write-Output "      session's NEXT turn, so THIS message still waits for a turn boundary."
        Write-Output "      Sends after that one can wake it while idle."
      } else {
        Write-Output "wake: '$a' is not watched and the watch list is full ($WATCH_CAP), so this waits"
        Write-Output "      for a turn boundary. Free a slot with: msg.ps1 unwatch <name>"
      }
    }
  }
  'rename' {
    if (-not $a -or -not $b) { Write-Output "usage: msg.ps1 rename <old-name> <new-name>"; exit 1 }
    $r = Load-Reg
    if (-not ($r.PSObject.Properties.Name -contains $a)) { Write-Output "ERROR: '$a' is not registered"; exit 1 }
    if ($r.PSObject.Properties.Name -contains $b) { Write-Output "ERROR: '$b' already exists"; exit 1 }
    $uuid = $r.$a
    $r.PSObject.Properties.Remove($a)
    $r | Add-Member -NotePropertyName $b -NotePropertyValue $uuid -Force
    [System.IO.File]::WriteAllText($reg, ($r | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    $oldIb = Join-Path $MBOX ("inbox\" + $a + ".jsonl")
    $newIb = Join-Path $MBOX ("inbox\" + $b + ".jsonl")
    if (Test-Path -LiteralPath $oldIb) { Move-Item -LiteralPath $oldIb -Destination $newIb -Force }
    else { New-Item -ItemType File -Path $newIb -Force | Out-Null }
    Write-Output "renamed '$a' -> '$b'  (uuid $uuid, inbox moved)"
    Write-Output "NOTE: tell that session its new name; senders must use it from now on."
  }
  'read' {
    # Sanctioned pull. Reading the inbox file directly bypasses the framing that carries
    # authority, and leaves messages unread so the hook redelivers them. This invokes the
    # REAL hook with a synthetic payload, so the framing is identical by construction and
    # cannot drift, and messages are marked read exactly as a push delivery would.
    if (-not $a) { Write-Output "usage: msg.ps1 read <name>"; exit 1 }
    $r = Load-Reg
    if (-not ($r.PSObject.Properties.Name -contains $a)) { Write-Output "ERROR: '$a' is not registered"; exit 1 }
    $hook = Join-Path (Split-Path -Parent $PSCommandPath) 'mailbox-stop.ps1'
    if (-not (Test-Path -LiteralPath $hook)) { Write-Output "ERROR: hook not found at $hook"; exit 1 }
    $payload = (@{ session_id = $r.$a; cwd = 'msg.ps1-read'; hook_event_name = 'Stop' } | ConvertTo-Json -Compress)
    $out = $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook
    if ($out) {
      $j = ($out -join '') | ConvertFrom-Json
      Write-Output $j.reason
    } else {
      Write-Output "no unread messages for '$a'"
    }
  }
  'prune' {
    # Drops READ messages older than N days and trims logs. Never touches unread mail.
    $days = 7
    if ($a) { $days = [int]$a }
    $cut = (Get-Date).AddDays(-$days)
    $totalDropped = 0
    Get-ChildItem (Join-Path $MBOX 'inbox') -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object {
      $keep = @(); $dropped = 0
      foreach ($line in (Get-Content -LiteralPath $_.FullName -Encoding utf8)) {
        $x = $line -replace '^﻿',''
        if ($x.Trim() -eq '') { continue }
        $m = $null
        try { $m = $x | ConvertFrom-Json } catch { $keep += $x; continue }
        if (-not $m.read) { $keep += $x; continue }
        $old = $false
        try { $old = ([datetime]::Parse($m.ts)) -lt $cut } catch { }
        if ($old) { $dropped++ } else { $keep += $x }
      }
      if ($dropped -gt 0) {
        [System.IO.File]::WriteAllText($_.FullName, (($keep -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
      }
      $totalDropped += $dropped
      Write-Output ("  {0,-20} kept={1} dropped={2}" -f $_.BaseName, $keep.Count, $dropped)
    }
    Write-Output "dropped $totalDropped read message(s) older than $days day(s). Unread mail untouched."
  }
  'title' {
    # msg.ps1 title NAME "Display Title"   set a human title for a session
    # msg.ps1 title NAME                   show the current title
    if (-not $a) { Write-Output "usage: msg.ps1 title <name> [<display title>]"; exit 1 }
    $key = Resolve-Name $a
    if (-not $key) { Write-Output "ERROR: '$a' does not resolve to a registered session."; exit 1 }
    $ti = Load-Titles
    if (-not $b) {
      $cur = $ti.$key
      if ($cur) { Write-Output "$key : '$cur'" } else { Write-Output "$key : (no title set)" }
      exit 0
    }
    $ti | Add-Member -NotePropertyName $key -NotePropertyValue $b -Force
    [System.IO.File]::WriteAllText($titlesPath, ($ti | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "title set: $key -> '$b'"
    Write-Output "Message cards addressed to or from this session will now show that title."
  }
  'reap' {
    # msg.ps1 reap [hours]   remove registry entries for sessions that are gone
    $hrs = 12
    if ($a) { $hrs = [int]$a }
    $r = Join-Path (Split-Path -Parent $PSCommandPath) 'mailbox-reap.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $r -ReapHours $hrs
    Write-Output "(a session wrongly reaped re-registers at its next turn -- register also runs on Stop)"
  }
  'watch' {
    if (-not $a) {
      $w = Load-Watched
      Write-Output "watched sessions (these get a background idle-wake watcher):"
      if (@($w).Count -eq 0) { Write-Output "  (none -- every session receives mail at turn boundaries only)" }
      else { @($w) | ForEach-Object { Write-Output ("  " + $_) } }
      exit 0
    }
    $key = Resolve-Name $a
    if (-not $key) { Write-Output "ERROR: '$a' does not resolve to a registered session."; exit 1 }
    $w = @(Load-Watched)
    if ($w -contains $key) { Write-Output "'$key' is already watched"; exit 0 }
    Save-Watched ($w + $key)
    Write-Output "watching '$key' -- it gets a background watcher at its next turn, and can then be woken while idle"
  }
  'unwatch' {
    if (-not $a) { Write-Output "usage: msg.ps1 unwatch <name>"; exit 1 }
    $key = Resolve-Name $a
    if (-not $key) { $key = $a }
    $w = @(Load-Watched) | Where-Object { $_ -ne $key }
    Save-Watched $w
    Write-Output "no longer watching '$key' -- it still receives mail at turn boundaries"
    Write-Output "(a watcher already running for it stops within one poll)"
  }
  'sessions' {
    # Every session the desktop app knows about, addressable or not. The registry answers
    # "who can receive mail"; this answers "who exists", which is what someone actually has
    # in mind when they name a session by the title on their screen.
    if (-not $script:HasCcd) {
      Write-Output "ERROR: the session-title bridge (mailbox-ccd.ps1) is not installed next to msg.ps1."
      exit 1
    }
    $all = Get-CcdSessions
    if ($all.Count -eq 0) {
      Write-Output "No desktop session files found."
      Write-Output "Sessions started from the CLI never appear here -- title those by hand:"
      Write-Output "  msg.ps1 title <name> ""Some Title"""
      exit 0
    }
    $r = Load-Reg
    $byUuid = @{}
    foreach ($p in $r.PSObject.Properties) { $byUuid[$p.Value] = $p.Name }
    $hist = Load-History
    $w = @(Load-Watched)
    $rows = @()
    foreach ($cli in $all.Keys) {
      $rec = $all[$cli]
      $name = $null; $state = ''
      if ($byUuid.ContainsKey($cli)) {
        $name = $byUuid[$cli]
        if ($w -contains $name) { $state = 'reachable, wakes idle' } else { $state = 'reachable at turn end' }
      } else {
        $prev = $null
        try { $prev = $hist.$cli } catch { }
        if ($prev) { $name = $prev; $state = 'ENDED - reclaims this name if resumed' }
        else       { $state = 'never used the mailbox' }
      }
      if ($rec.IsArchived) { $state = 'archived; ' + $state }
      $rows += [PSCustomObject]@{
        Last  = $rec.LastActivityAt
        Title = $rec.Title
        Name  = $(if ($name) { $name } else { '-' })
        State = $state
      }
    }
    $show = if ($a) { [int]$a } else { 15 }
    Write-Output "=== sessions the desktop app knows (most recent $show) ==="
    $rows | Sort-Object Last -Descending | Select-Object -First $show | ForEach-Object {
      $t = if ($_.Last) { $_.Last.ToString('MM-dd HH:mm') } else { '   ?   ' }
      Write-Output ("  {0}  {1,-38} {2,-22} {3}" -f $t, $_.Title, $_.Name, $_.State)
    }
    Write-Output ""
    Write-Output "Send using either column: the title or the mailbox name resolves to the same session."
    Write-Output "CLI sessions are absent here by design -- the desktop app writes no metadata for them."
  }
  'status' {
    Write-Output "=== registry ==="
    if (Test-Path -LiteralPath $reg) {
      $ti = Load-Titles
      (Load-Reg).PSObject.Properties | ForEach-Object {
        $tt = $ti.($_.Name)
        $wm = ''
        if ((Load-Watched) -contains $_.Name) { $wm = '  [watched]' } else { $wm = '  [NOT watched -- receives only at turn boundaries]' }
        if ($tt) { Write-Output ("  {0,-16} {1}  '{2}'{3}" -f $_.Name, $_.Value, $tt, $wm) }
        else     { Write-Output ("  {0,-16} {1}{2}" -f $_.Name, $_.Value, $wm) }
      }
    }
    else { Write-Output "  (none)" }
    Write-Output "=== inboxes ==="
    Get-ChildItem (Join-Path $MBOX 'inbox') -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object {
      $all = @(Get-Content -LiteralPath $_.FullName | Where-Object { $_.Trim() -ne '' })
      $un = 0; foreach ($l in $all) { try { if (-not ($l|ConvertFrom-Json).read) { $un++ } } catch {} }
      Write-Output ("  {0,-24} total={1} unread={2}" -f $_.BaseName, $all.Count, $un)
    }
    Write-Output "=== hook fired (PREVIEW - last 12 lines only) ==="
    $lg = Join-Path $MBOX 'log\hook-fired.log'
    if (Test-Path -LiteralPath $lg) {
      $n = @(Get-Content -LiteralPath $lg).Count
      Get-Content -LiteralPath $lg -Tail 12 | ForEach-Object { Write-Output ("  " + $_) }
      Write-Output ""
      Write-Output "  ^ showing 12 of $n lines. This is a PREVIEW, not the record."
      Write-Output "    A session missing from this window has NOT necessarily stopped firing."
      Write-Output "    Authority: $lg"
    }
    else { Write-Output "  NEVER FIRED - hook is not running" }
  }
  default {
    Write-Output "usage:"
    Write-Output "  msg.ps1 claim  <name> <session-uuid>"
    Write-Output "  msg.ps1 send   <name> <text> [<from>]   # <from> attributes the sender"
    Write-Output "  msg.ps1 read   <name>                   collect unread WITH framing"
    Write-Output "  msg.ps1 rename <old-name> <new-name>"
    Write-Output "  msg.ps1 prune  [days]                   drop READ mail older than N days (default 7)"
    Write-Output "  msg.ps1 title  <name> [<display title>]  set/show the name shown on message cards"
    Write-Output "  msg.ps1 reap   [hours]                  drop registry entries for sessions that are gone"
    Write-Output "  msg.ps1 sessions [<n>]                  list sessions by their on-screen title"
    Write-Output "  msg.ps1 watch  [<name>]                 opt a session into background idle-wake (or list)"
    Write-Output "  msg.ps1 unwatch <name>                  opt it back out"
    Write-Output "  msg.ps1 status"
    Write-Output ""
    Write-Output "  <from> precedence: 4th arg > MAILBOX_MSG_FROM > 'unattributed'"
    Write-Output "  MAILBOX_DIR overrides the mailbox root (for testing)"
  }
}
