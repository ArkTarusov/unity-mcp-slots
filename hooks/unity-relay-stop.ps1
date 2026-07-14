# Windows half of the Unity MCP slot cleanup. The macOS/Linux half is unity-relay-stop.sh;
# the plugin manifest picks between them by `uname`.
#
# Why this exists: Unity's AI Assistant counts one logical client per root claude.exe PID and
# holds that slot until the client's named pipe closes. The relay connects eagerly — a chat
# spawns it at session start even when Unity is never used — and claude.exe outlives its chat
# window, so a finished chat keeps a slot until the process is reaped. The connection cap is
# entitlement-driven (a handful of slots), so idle chats starve chats doing real work.
#
# Why killing the relay is safe: Claude Code respawns a dead stdio MCP server on the next tool
# call. The slot is released now and reacquired only if Unity is used again, at the cost of one
# process start.
#
# Never touches the hub (`relay_win.exe --relay`): it is owned by the Unity Editor and serves
# every connected client, so killing it would break the bridge for everyone. Never touches
# another chat's relay: slots are per root claude.exe PID, so only this process's own child is
# a candidate.
#
# Having no relay to kill is the normal, expected outcome — in a project without Unity MCP, or
# on a turn that never touched the Editor — and stays silent. Anything else is unexpected and
# is reported on stderr: a hook that fails quietly would leave the user believing slots are
# being freed while they are not. Exit stays 0 throughout, because failing to reclaim a slot
# must never break the turn.

$ErrorActionPreference = 'Stop'

function Write-Problem([string]$text) {
    [Console]::Error.WriteLine("unity-mcp-slots: $text")
}

try {
    # Walk up from this process to the claude.exe that owns it. The relay is a direct child of
    # that process, which is also the identity Unity counts the slot against.
    $claudePid = $null
    $cur = $PID
    for ($i = 0; $i -lt 12 -and $cur; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -eq 'claude.exe') { $claudePid = $p.ProcessId; break }
        $cur = $p.ParentProcessId
    }

    if (-not $claudePid) {
        # Every hook runs as a descendant of claude.exe, so failing to find it means the process
        # tree is not what this script assumes and no slot can be reclaimed.
        Write-Problem "could not find the owning claude.exe within 12 parents of PID $PID - slot not released"
        exit 0
    }

    $relays = @(Get-CimInstance Win32_Process -Filter "Name='relay_win.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ParentProcessId -eq $claudePid -and
            $_.CommandLine -match '--mcp' -and
            $_.CommandLine -notmatch '--relay'
        })

    foreach ($r in $relays) {
        try {
            Stop-Process -Id $r.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Problem "failed to stop relay PID $($r.ProcessId) (owner claude.exe $claudePid): $($_.Exception.Message)"
        }
    }
} catch {
    Write-Problem "unexpected failure, slot not released: $($_.Exception.Message)"
    exit 0
}

exit 0
