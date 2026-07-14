#!/usr/bin/env bash
# macOS / Linux half of the Unity MCP slot cleanup. The Windows half is unity-relay-stop.ps1;
# the plugin manifest picks between them by `uname`.
#
# Why this exists: Unity's AI Assistant counts one logical client per root claude process and
# holds that slot until the client's named pipe closes. The relay connects eagerly — a chat
# spawns it at session start even when Unity is never used — and the claude process outlives
# its chat window, so a finished chat keeps a slot until the process is reaped. The connection
# cap is entitlement-driven (a handful of slots), so idle chats starve chats doing real work.
#
# Why killing the relay is safe: Claude Code respawns a dead stdio MCP server on the next tool
# call. The slot is released now and reacquired only if Unity is used again, at the cost of one
# process start.
#
# Never touches the hub (the process carrying --relay): it is owned by the Unity Editor and
# serves every connected client. Never touches another chat's relay: slots are per root claude
# PID, so only this process's own child is a candidate.
#
# Having no relay to kill is the normal, expected outcome — in a project without Unity MCP, or
# on a turn that never touched the Editor — and stays silent. Anything else is unexpected and
# is reported on stderr: a hook that fails quietly would leave the user believing slots are
# being freed while they are not. Exit stays 0 throughout, because failing to reclaim a slot
# must never break the turn.

set -u

problem() {
    printf 'unity-mcp-slots: %s\n' "$1" >&2
}

# Walk up the parent chain to the claude process that owns this hook. The relay is a direct
# child of that process, which is also the identity Unity counts the slot against. Matching is
# on the executable basename only: this script's own path contains ".claude", so matching the
# whole argument string would hit every ancestor.
claude_pid=""
pid=$$
i=0
while [ "$i" -lt 12 ]; do
    info="$(ps -o ppid=,args= -p "$pid" 2>/dev/null)" || break
    [ -z "$info" ] && break
    ppid="$(printf '%s\n' "$info" | awk '{print $1}')"
    exe="$(printf '%s\n' "$info" | awk '{print $2}')"
    [ -z "$ppid" ] && break
    case "$(basename "$exe")" in
        claude)
            claude_pid="$pid"
            break
            ;;
    esac
    pid="$ppid"
    i=$((i + 1))
done

if [ -z "$claude_pid" ]; then
    # Every hook runs as a descendant of the claude process, so failing to find it means the
    # process tree is not what this script assumes and no slot can be reclaimed.
    problem "could not find the owning claude process within 12 parents of PID $$ - slot not released"
    exit 0
fi

# The relay client ships per-user under ~/.unity/relay/ with a platform-specific binary name,
# so match on the path plus --mcp rather than on the executable name. Requiring the parent to
# be this claude process is what keeps other chats' slots untouched; requiring "relay" in the
# path is what keeps this off the session's other MCP servers. Anything carrying --relay is the
# hub and must survive.
#
# Candidates are collected before killing so the kills do not run in a pipeline subshell, where
# a failure could not be reported.
candidates="$(
    ps -eo pid=,ppid=,args= 2>/dev/null | while read -r rpid rppid rargs; do
        [ "$rppid" = "$claude_pid" ] || continue
        case "$rargs" in
            *--relay*) continue ;;
        esac
        case "$rargs" in
            *relay*--mcp*) printf '%s\n' "$rpid" ;;
        esac
    done
)"

for rpid in $candidates; do
    kill -9 "$rpid" 2>/dev/null || problem "failed to kill relay PID $rpid (owner claude $claude_pid)"
done

exit 0
