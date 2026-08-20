# Session-title bridge.
#
# The mailbox addresses sessions by a name derived from their working directory
# ('payments-api'). A human addresses them by the title on screen
# ('Payments API - staging'). Nothing in the hook payload carries that title, so it
# had to be typed in by hand, and went stale silently whenever a session was renamed.
#
# The desktop app writes one metadata file per session under
#   %APPDATA%/Claude/claude-code-sessions/<a>/<b>/local_<uuid>.json
# and that file contains BOTH identifiers:
#   sessionId     local_<uuid-A>   the id the desktop app uses
#   cliSessionId  <uuid-B>         the id the hooks receive on stdin
# cliSessionId is the join. It is an exact key, not a heuristic. An earlier attempt
# recovered this by searching session transcripts for the mailbox name, which matched
# every session that had merely MENTIONED that name -- one session which had printed
# the registry matched all nine, and would have mapped every name to itself.
#
# Scope, stated because it is easy to assume otherwise: these files are written by the
# DESKTOP app. A session started from the `claude` CLI has no file here and no title to
# recover, so callers must keep a manual fallback for those.
#
# NO REGEX AND NO BACKSLASH LITERALS BELOW, deliberately. The first version of this file
# parsed with regex, and the layers between the editor and disk silently collapsed the
# doubled backslashes in five patterns -- turning the two-character escape sequence \n
# into a match for a real newline. It threw, a catch-all swallowed it, and the function
# reported "no sessions found" rather than "I could not parse". Index-based scanning has
# nothing to corrupt; the one backslash that IS needed is written as [char]92.
$script:CCD_HEAD_BYTES = 8192

function Get-CcdRoot {
  if ($env:MAILBOX_CCD_ROOT) { return $env:MAILBOX_CCD_ROOT }
  $ad = $env:APPDATA
  if (-not $ad) { $ad = Join-Path $env:USERPROFILE 'AppData/Roaming' }
  return (Join-Path $ad 'Claude/claude-code-sessions')
}

function Write-CcdLog([string]$m) {
  try {
    $mbox = if ($env:MAILBOX_DIR) { $env:MAILBOX_DIR } else { Join-Path $env:USERPROFILE '.claude/mailbox' }
    $log  = Join-Path $mbox 'log/ccd.log'
    Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding utf8
  } catch { }
}

function Read-Head([string]$path, [int]$n) {
  $fs = $null
  try {
    # ReadWrite share: the app holds these files open and writes to them live.
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                 [System.IO.FileAccess]::Read,
                                 [System.IO.FileShare]::ReadWrite)
    $buf = New-Object byte[] $n
    $read = $fs.Read($buf, 0, $n)
    if ($read -le 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  } catch { return '' }
  finally { if ($fs) { $fs.Dispose() } }
}

function Find-JsonValueStart([string]$s, [string]$name) {
  # Index just past the colon for a top-level key, or -1.
  # The key is matched WITH its quotes, so "title" cannot match "titleSource".
  $key = '"' + $name + '"'
  $i = $s.IndexOf($key)
  if ($i -lt 0) { return -1 }
  $i = $s.IndexOf(':', $i + $key.Length)
  if ($i -lt 0) { return -1 }
  $i++
  while ($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])) { $i++ }
  return $i
}

function Get-JsonStringField([string]$s, [string]$name) {
  # Returns the DECODED string value, or $null if absent, not a string, or cut off by
  # the head limit. Returning $null on truncation matters: half a title is worse than
  # no title, because it would be shown as if it were the whole one.
  $bs = [char]92
  $i = Find-JsonValueStart $s $name
  if ($i -lt 0 -or $i -ge $s.Length) { return $null }
  if ($s[$i] -ne '"') { return $null }
  $i++
  $sb = New-Object System.Text.StringBuilder
  $closed = $false
  while ($i -lt $s.Length) {
    $c = $s[$i]
    if ($c -eq $bs) {
      if ($i + 1 -ge $s.Length) { return $null }   # escape split by the head boundary
      [void]$sb.Append($c)
      [void]$sb.Append($s[$i + 1])
      $i += 2
      continue
    }
    if ($c -eq '"') { $closed = $true; break }
    [void]$sb.Append($c)
    $i++
  }
  if (-not $closed) { return $null }
  # Hand the escapes to a real JSON parser rather than unescaping them by hand.
  try { return ('"' + $sb.ToString() + '"' | ConvertFrom-Json) } catch { return $sb.ToString() }
}

function Get-JsonRawField([string]$s, [string]$name) {
  # Raw token for a number or boolean, or $null.
  $i = Find-JsonValueStart $s $name
  if ($i -lt 0 -or $i -ge $s.Length) { return $null }
  $j = $i
  while ($j -lt $s.Length -and $s[$j] -ne ',' -and $s[$j] -ne '}' -and $s[$j] -ne "`n") { $j++ }
  if ($j -ge $s.Length) { return $null }
  $v = $s.Substring($i, $j - $i).Trim()
  if (-not $v) { return $null }
  return $v
}

function Get-CcdSessions {
  # cliSessionId -> @{ Title; IsArchived; LastActivityAt; Cwd; AppId }
  $out = @{}
  $scanned = 0
  $parsed  = 0
  try {
    $root = Get-CcdRoot
    if (-not (Test-Path -LiteralPath $root)) {
      Write-CcdLog "root not found: $root"
      return $out
    }
    $files = @(Get-ChildItem -LiteralPath $root -Filter 'local_*.json' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      $scanned++
      $head = Read-Head $f.FullName $script:CCD_HEAD_BYTES
      if (-not $head) { continue }

      $cli = Get-JsonStringField $head 'cliSessionId'
      if (-not $cli) { continue }
      $title = Get-JsonStringField $head 'title'
      if (-not $title) { continue }   # untitled sessions are not addressable by title

      $arch = $false
      $rawA = Get-JsonRawField $head 'isArchived'
      if ($rawA -eq 'true') { $arch = $true }

      $last = $null
      $rawL = Get-JsonRawField $head 'lastActivityAt'
      if ($rawL) {
        try { $last = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rawL).LocalDateTime } catch { }
      }

      $rec = @{
        Title          = $title
        IsArchived     = $arch
        LastActivityAt = $last
        Cwd            = (Get-JsonStringField $head 'cwd')
        AppId          = (Get-JsonStringField $head 'sessionId')
      }

      # One cliSessionId can appear more than once when a session is forked; newest wins.
      if ($out.ContainsKey($cli)) {
        $prev = $out[$cli]
        if ($prev.LastActivityAt -and $last -and $prev.LastActivityAt -gt $last) { continue }
      }
      $out[$cli] = $rec
      $parsed++
    }
    if ($scanned -gt 0 -and $parsed -eq 0) {
      Write-CcdLog "scanned $scanned file(s) but parsed 0 -- format may have changed"
    }
  } catch {
    # Never break a delivery over this. But say WHY, so a silent zero is diagnosable.
    Write-CcdLog ("ERROR after $scanned file(s): " + $_.Exception.Message)
    return @{}
  }
  return $out
}

function Get-CcdByMailboxName([object]$registry) {
  # mailbox name -> the same record, joined through the registry's UUID.
  $out = @{}
  try {
    $ccd = Get-CcdSessions
    if ($ccd.Count -eq 0) { return $out }
    foreach ($p in $registry.PSObject.Properties) {
      if ($ccd.ContainsKey($p.Value)) { $out[$p.Name] = $ccd[$p.Value] }
    }
  } catch {
    Write-CcdLog ("join ERROR: " + $_.Exception.Message)
    return @{}
  }
  return $out
}
