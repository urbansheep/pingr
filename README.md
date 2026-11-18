# pingr

One-screen network monitor for macOS: LAN gateway, two public anchors and two HTTP
204 endpoints, with mtr-style coloured history at three time scales — no root, no mtr,
no scrolling output.

## Install

```sh
git clone https://github.com/urbansheep/pingr.git
cd pingr
./install.sh   # copies pingr to ~/.local/bin, runs the self-test
```

Requires macOS with stock Python 3. No dependencies, no config files.

Live command: `~/.local/bin/pingr` (that directory is on `PATH`; the old zsh function was
removed from `~/.zsh_aliases` and `~/.zshrc.pre-oh-my-zsh`). Original one-liner kept at
`~/scripts/pingr-legacy.zsh` for rollback.

## Usage

```sh
pingr              # full-screen monitor (falls back to -q when stdout is not a TTY)
pingr -q           # state changes only, timestamped; also writes the log
pingr -1           # one five-row snapshot, exits 1 if anything failed
pingr --ascii      # . : + ! instead of . o O @
pingr --no-http    # ICMP only, no 204 probes (HTTP rows hidden)
```

Keys: `1` `2` `3` zoom (10 min per second · 1 h per minute · 24 h per hour),
`t` 10 MB throughput test, `s` `tailscale ping` on the current exit node,
`p` pause sampling, `r` restart samplers now, `?` help line, `q` quit.

## Screen

```
pingr 00:31:30  en0 192.168.1.9  gw 192.168.1.1  route utun4  ts exit urbansheep-vu
ok  route=utun4 gw=en0/192.168.1.1

lan   192.168.1.1         14ms    +1ms    0%   ................................x
wan1  1.1.1.1             72ms   +17ms    2%   o..o.o.o...oo.oo.oooooo.ooooo.o.x
wan2  9.9.9.9             37ms   -23ms    2%   ooo.oooooooo.ooooooooo..o.oooooox
http1 www.gstatic.com    334ms   +11ms    0%      . .. . .. . .. . .. . .. . .. .
http2 cp.cloudflare.co   365ms    +4ms    0%    . .. . .. . .. . .. . .. . o. .
```

Per row: current sample, Δ against the last hour's median, loss over 60 s (300 s for HTTP),
then the history band for the active zoom. The two inactive zoom levels are shown at the
bottom for whichever target is currently worst.

Colour follows the **median** of each time bucket against per-class bins; a bucket
containing a peak above the red bin is drawn red anyway, so spikes are never averaged away.

| glyph | meaning |
|-------|---------|
| `.` / `o` / `O` / `@` | green / yellow / magenta / red latency bucket |
| `x` | lost samples in that bucket (bold red) |
| `│` | network parameters changed here |
| `~` | sample gap > 5 s (sleep/suspend), not an outage |

## States

| state | condition |
|-------|-----------|
| `no route` | `route -n get default` yields no interface |
| `no gateway` | route exists but no active port has a DHCP router |
| `LAN down` | router lost 3 consecutive probes |
| `uplink down` | both `1.1.1.1` and `9.9.9.9` lost 3 consecutive probes |
| `HTTP blocked` | both 204 endpoints failed twice in a row |
| `ok` | none of the above |

Each transition logs one line and shows `since HH:MM:SS (Ns)` in the header. A single lost
sample is treated as noise (Wi-Fi drops plenty); three in a row is an outage.

## How it samples

- ICMP: one `/sbin/ping -i 1 -W 900` process per target. macOS refuses unprivileged ICMP
  sockets to scripts, so ping subprocesses are the only root-free option.
- Network parameters (`route -n get default`, `ipconfig getoption <dev> router`, hardware-port
  scan as fallback) are re-read every 5 s. A changed gateway/route is adopted only after two
  identical reads, then all pingers restart and a `│` marker is written.
- HTTP: `GET /generate_204` against `www.gstatic.com` and `cp.cloudflare.com` every 30 s,
  measuring time-to-first-byte. That says the path works, not how fast it is.
- Throughput on demand: 10 MB from `speed.cloudflare.com`, reported as Mbps in the footer.

## Files

| path | content |
|------|---------|
| `~/.local/bin/pingr` | the script; targets, colour bins and intervals are constants at the top |
| `~/Library/Logs/pingr.log` | transitions, network changes, throughput and `ts ping` results; rotates to `pingr.log.1` at 1 MB |
| `~/Library/Application Support/pingr/history.json` | per-minute aggregates for the 24 h band (24 h retention, atomic writes) |
| `install.sh` | copies `pingr` to `~/.local/bin` and runs the self-test |
| `~/scripts/pingr-legacy.zsh` | the original `pingr()` one-liner |
| `~/scripts/pingr/SPEC.md` | design decisions and internals |

## Tuning

Colour bins live in `BINS` (`lan`, `wan`, `http`) as `(green, yellow, red)` millisecond
thresholds. Current values were calibrated on Wi-Fi through a Tailscale exit node
(LAN p50 14 ms, WAN p50 72 ms, both with 500–800 ms spikes). Wired or a nearer exit node
will want lower numbers.

## Troubleshooting

- **`pingr` still runs the old loop** in an existing shell: `unfunction pingr`. Sourcing
  `~/.zsh_aliases` cannot delete a function that is already defined.
- **`no gateway` while a VPN is up**: expected if the LAN is gone; the default route can be
  a tunnel even when no port has a router.
- **`ts exit` missing**: Tailscale app is not running or no exit node is selected;
  everything else still works.
- **Header shows a huge WAN RTT**: check `ts exit` — traffic is going through that node.
- `pingr --selftest` runs the hidden assert checks (bucketing, thresholds, state machine).
