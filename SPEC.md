# pingr — specification

Status: implemented as `~/.local/bin/pingr` (single Python file, stdlib only, macOS).
This document records the decisions taken during design and the internals that follow
from them, so future changes can be judged against the original intent.

## Problem

`pingr` used to be a one-line zsh function that resolved the router once and then ran
`ping` forever, flooding the terminal. After a network switch it kept pinging a stale
address until restarted by hand. `mtr` was the desired look (coloured per-sample history)
but needs root on macOS and crashes when the network changes.

## Goals

1. One screen of history instead of a scrolling log: seconds, minutes and hours at once.
2. Re-read network parameters continuously so a changed gateway is picked up without a manual
   restart, without flapping.
3. Never misreport a network change or a laptop sleep as packet loss.
4. Say which half of the path broke: LAN, uplink, or HTTP.
5. No root, no dependencies beyond the Python standard library.

## Non-goals

- Per-hop tracing (the only thing mtr actually provided). No traceroute, no TUI of hops.
- Remediation: no DHCP renew, no radio toggling, no Tailscale re-up. Read-only monitoring.
- Configuration files or a plugin system. Targets, bins and intervals are constants.
- Background/daemon operation. Foreground only; history is persisted, events are logged.

## Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Deliverable | Standalone script, not an inline shell function, not an mtr wrapper |
| 2 | Language | Python 3 + stdlib `curses`; Go/Rust rejected because ICMP needs a subprocess either way and curses is free |
| 3 | Sampling | `/sbin/ping -i 1 -W 900` per ICMP target (macOS blocks unprivileged ICMP sockets from scripts) |
| 4 | Self-heal | Re-resolve only; report `no route`/`no gateway` with a since-time; no privileged remediation |
| 5 | Targets | Router + two public DNS anchors + two `generate_204` HTTP endpoints |
| 6 | HTTP semantics | 30 s TTFB probes are a liveness/latency signal, not throughput; real throughput is a manual `t` keypress (10 MB) |
| 7 | Layout | mtr-style rows per target, one active zoom, other zooms compressed to two bottom rows for the worst target |
| 8 | Colour | Fixed bins per target class, calibrated on real medians, plus a Δ-vs-hour-median column |
| 9 | Persistence | Per-minute aggregates to disk (24 h), per-second history in memory (1 h) |
| 10 | Install | `~/.local/bin/pingr`, old function deleted from both zsh files, copy in `~/scripts/pingr-legacy.zsh` |
| 11 | Down rule | 3 consecutive losses on a target; one loss is noise |
| 12 | Discontinuities | Gateway change → `│` marker; sample gap > 5 s → `~`, excluded from loss counting |
| 13 | CLI | `-q`, `-1`, `--ascii`, `--no-http`; non-TTY stdout implies `-q` |
| 14 | Keys | `1/2/3`, `t`, `s`, `p`, `r`, `?`, `q` |
| 15 | VPN context | Header shows interface, LAN IP, router, default-route device and the Tailscale exit-node name refreshed every 30 s |
| 16 | ts path | `tailscale ping` on demand (`s`), not periodic — it takes seconds and would fight the 1 s cadence |

## Architecture

Four kinds of threads plus the renderer, all sharing one `State` guarded by a `Lock`.

- **clock** (1 Hz): detects sleep gaps, re-resolves network parameters every 5 s with a
  two-read confirmation, refreshes the Tailscale exit node every 30 s, recomputes the mode,
  recomputes per-target hour medians, persists minute aggregates every 10 s.
- **pinger ×3**: one per ICMP target. Holds a `ping` subprocess, parses `time=` and
  `Request timeout` lines, records `(timestamp, rtt | None)`. Restarts when `State.gen`
  changes (network change, manual `r`, gap) or when the target disappears.
- **http_probe**: sequentially fetches both 204 endpoints every 30 s, records TTFB or `None`,
  maintains consecutive-failure counters.
- **renderer**: `curses` loop at 5 Hz; redraws from a snapshot taken under the lock.

### Data model

```
series[name] : deque[(ts, rtt | None | "gw" | "gap")]
    lan/wan1/wan2  maxlen 3600   (1 h at 1 Hz)
    gstatic/cloudflare  maxlen 120  (1 h at 30 s)
minutes[name] : {minute_epoch: [sum, count, losses]}   persisted, 24 h retention
http_fail[name] : consecutive failed 204 probes
dev / gw / route_dev / ip / ts_exit / mode / since / detail / gen / paused / note
```

`"gw"` and `"gap"` are markers stored in the same series so they land in the right column
of every zoom; they are filtered out before any loss or latency computation.

### Zoom rendering

`bucketize(points, now, window, cols)` maps the last `window` seconds onto `cols` columns and
returns `(median, peak, lost)` per bucket:

- markers win over data (so a `│` is never hidden by a sample in the same bucket);
- any lost sample marks the bucket lost → bold red `x`;
- otherwise the colour class comes from the bucket **median**, which keeps a single outlier
  from painting the whole band; if the bucket peak exceeds the red bin, the dot is forced red.

Zoom windows: 600 s (10 m), 3600 s (1 h), 86400 s (24 h). The 24 h band is built from
`minutes`; the other two from `series`. Column count follows the terminal width, so a 5 s
bucket at 120 columns and 1 s buckets are only possible when 600 columns fit.

### State machine

```
no route      route -n get default yields no interface
no gateway    route exists, but no active port reports a DHCP router
LAN down      router lost 3 consecutive samples
uplink down   both public anchors lost 3 consecutive samples
HTTP blocked  both 204 endpoints failed twice in a row
ok            otherwise
```

Checked in that order each second; a change updates `since`, `detail`
(`route=<dev> gw=<dev>/<ip>`) and appends a log line.

### Network change detection

`resolve()` returns `(gateway device, router, default-route device)`. The gateway device is
the default-route interface when it has a router option (normal Wi-Fi/Ethernet), otherwise
the first hardware port with both an IPv4 address and a router — which is what makes the
tool work while a Tailscale tunnel owns the default route.

A candidate change counts only after `CONFIRM = 2` identical reads 5 s apart. On adoption:
write a `│` marker into every ICMP series, bump `gen` so pingers restart with the new target,
log `network change <old> -> <new> via <dev>`.

### Sleep handling

The clock measures the interval between its own ticks; above 5 s it writes `~` into the ICMP
series, bumps `gen` (stale subprocesses are killed and restarted) and logs the gap. Gaps are
excluded from loss counts and from the 3-loss down rule, so a resumed laptop does not
announce an outage.

### Persistence

Every 10 s, and on exit, each series is folded into minute buckets restricted to the last
24 h and merged into `minutes`, then written atomically (`.tmp` + `os.replace`) to
`history.json` if the payload changed. The renderer's 24 h band reads from `minutes`, so
history survives restarts; per-second detail does not.

Known limit: a restart in the middle of a minute rewrites that minute with a partial count.
Irrelevant for a trend view; revisit only if exact totals ever matter.

## Verification

- `pingr --selftest`: bucketing (markers, loss, median, peak), severity bins, mode transitions.
- `pingr -1`: five live probes, non-zero exit when any target fails.
- pty sessions driving `1/2/3`, `t`, `s`, `p`, `?`, `r`, `q`; no tracebacks, clean exit.
- Real measurements: 204 TTFB 280–540 ms through the Tailscale exit node, 10 MB throughput
  14–19.7 Mbps, `tailscale ping` reporting a direct path.
- `zsh -l -i -c 'command -v pingr'` resolves to `~/.local/bin/pingr` with the function removed.

## Risks / open edges

- Colour bins are calibrated to one network (Wi-Fi through a Tailscale exit node). Wired or a
  nearer exit node needs lower `BINS` values.
- `p` stops ICMP sampling but an in-flight HTTP probe or a 30 s wait finishes first.
- The Tailscale exit node is resolved by matching `ExitNodeStatus.ID` against peer IDs; a
  Tailscale change to that JSON shape degrades to "no ts exit", not to an error.
- Terminal narrower than ~60 columns truncates the stats column; the graph still renders.
