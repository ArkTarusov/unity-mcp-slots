# unity-mcp-slots

A Claude Code plugin that frees the Unity MCP connection slot your session is holding, so idle
chats stop crowding out the ones doing real work.

Built for Unity's own MCP integration — the relay shipped with the `com.unity.ai.assistant`
package. It has nothing to do with the various third-party "Unity MCP" servers.

## The problem

Unity's AI Assistant counts **one connection per Claude Code process**, and it holds that slot
until the client's pipe closes. Two behaviours make that expensive:

- **The relay connects eagerly.** A chat spawns it at session start, whether or not you ever
  touch the Editor. Measured: the relay is alive ~2 seconds into a session that never uses Unity.
- **The process outlives the window.** Closing a chat does not free anything; the slot lives on
  until the process is finally reaped, which can take tens of minutes.

The connection cap is entitlement-driven — a handful of slots. A few forgotten chats are enough
to lock you out of the Editor from the chat you actually care about.

## What the plugin does

It kills the relay client at `SessionStart` and again at `Stop`. Claude Code transparently
respawns a dead stdio MCP server on the next tool call, so nothing breaks: the slot is released
immediately and re-taken only if you actually use the Editor again, at the cost of one process
start. A slot then exists only while Unity is genuinely in use.

Subagents cost nothing extra — they share their parent's process, so a hundred of them still map
to a single slot.

### What it never touches

- **The hub** (`--relay`). That process belongs to the Editor and serves every client; killing it
  would break the bridge for everyone.
- **Other sessions' relays.** Only the relay spawned by *this* process is a candidate.
- **Anything, in a project without Unity MCP.** No relay, no action, silent exit.

## Install

Add both keys to the `.claude/settings.json` of any project that should have it. Committing that
file gives the whole team the same behaviour; the marketplace registers itself on clone, and each
developer confirms the install once.

```json
{
  "extraKnownMarketplaces": {
    "unity-mcp-slots": {
      "source": { "source": "github", "repo": "ArkTarusov/unity-mcp-slots" }
    }
  },
  "enabledPlugins": {
    "unity-mcp-slots@unity-mcp-slots": true
  }
}
```

Enabling it per project rather than globally keeps the hooks from firing where they have no work
to do. To opt out of a project that enables it, set the same plugin to `false` in your own
`.claude/settings.local.json` — local settings win over project ones.

## Connecting Unity MCP itself

The plugin only manages slots; it does not configure the server. That part stays personal,
because the relay binary is named per platform and lives in your home directory:

```
claude mcp add --scope local unity-mcp -- ~/.unity/relay/relay_win.exe --mcp        # Windows
claude mcp add --scope local unity-mcp -- ~/.unity/relay/relay_mac_arm64 --mcp      # macOS (Apple silicon)
```

`--scope local` keeps the entry in your own config rather than the repository, which is what you
want: a shared `.mcp.json` cannot express the per-platform binary name.

## Verifying it works

Ask the session to do anything through Unity MCP, then look for the relay client:

```
# Windows
Get-CimInstance Win32_Process -Filter "Name='relay_win.exe'" |
    Select-Object ProcessId, ParentProcessId, CommandLine

# macOS
ps -eo pid,ppid,args | grep '[r]elay.*--mcp'
```

While the turn runs you should see a client carrying `--mcp`. Once the answer finishes it should
be gone, leaving only the hub process carrying `--relay`.

## Status

The Windows path is verified end to end. **The macOS path passes a syntax check but has never
been executed** — if you run it there, confirming the behaviour above is genuinely useful.

## License

MIT — see [LICENSE](LICENSE).
