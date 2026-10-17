# LagScope

A small World of Warcraft addon that answers one question: **is this lag my addons, my connection, or the server?**

Those three feel identical in game and get treated as the same problem. They aren't, and the fix for each is completely different. LagScope measures them separately so you can stop guessing.

## What it measures

| Signal | How | What it tells you |
|---|---|---|
| Frame hitches | `OnUpdate` frame time, with the top 3 addons by CPU at that exact frame | Whether a stall is addon code, and which addon |
| Per-addon CPU | `C_AddOnProfiler` | How many frames each addon spent over 10 ms. No CVar to enable |
| Addon traffic | hook on `SendAddonMessage` | Whether something is flooding the addon channel (real network impact) |
| Latency timeline | `GetNetStats` every 5 s, recorded on change | **World vs home latency over time** |
| Lua errors | wrapped error handler | Error count per addon |

The latency timeline is the useful one. World and home latency travel over the same link, so when world climbs to 2000 ms while home stays flat at 185 ms, the problem is not your connection, your router or your addons — it's the world server. That single comparison settles most arguments.

## Install

Drop the `LagScope` folder into `Interface/AddOns/` and restart the client.

## Usage

```
/lagscope reset     before the pull
                    ... play ...
/lagscope           after the fight, full report
/reload             flushes the data to disk
```

That last `/reload` matters: SavedVariables are only written on reload or logout. A hard client crash loses the session, and no addon can work around that — Lua has no file writing API.

### Pre-pull macro

One button that sizes the buffers for a long session, clears the counters and makes sure collection is on:

```
/run LagScopeDB.maxSpikes = 300
/run LagScopeDB.maxLatency = 1000
/lagscope reset
/lagscope on
```

The two `/run` lines only need to happen once — those values are saved — but leaving them in costs nothing and makes the macro self-contained on a fresh install.

Careful with the button mid-raid: `reset` wipes everything collected so far. Press it when you zone in, not between pulls, or you lose the earlier fights.

### Commands

| Command | What it does |
|---|---|
| `/lagscope` | Full report |
| `/lagscope cpu [n]` | Addons ranked by frames over 10 ms |
| `/lagscope spikes [n]` | Recent hitches with the culprits of each |
| `/lagscope latency [n]` | Latency timeline — when it started climbing |
| `/lagscope net` | Latency plus addon message traffic |
| `/lagscope errors` | Lua errors per addon |
| `/lagscope reset` | Clears every counter |
| `/lagscope threshold <ms>` | Hitch threshold, default 50 ms |
| `/lagscope off` \| `on` | Stops or resumes hitch detection |

`/lsc` works as a short form of `/lagscope`.

### Buffer sizes

Defaults hold 60 hitches and 400 latency samples, which fills up in one raid night and starts dropping the oldest entries. The pre-pull macro above raises them to 300 and 1000; the same thing as a one-liner:

```
/run LagScopeDB.maxSpikes = 300; LagScopeDB.maxLatency = 1000; print('ok')
```

Latency samples are only stored when the value changes, and `GetNetStats` refreshes roughly every 30 seconds, so 1000 samples covers about eight hours.

## Reading the data outside the game

Everything lands in `WTF/Account/<account>/SavedVariables/LagScope.lua`. It's a plain Lua table, readable by eye, but the included script summarizes it:

```bash
python3 tools/parse_lagscope.py "/path/to/WTF/Account/<account>/SavedVariables/LagScope.lua"
```

It prints the latency range, every sample in order, traffic by prefix, errors, and the worst hitches with who led them.

## Measuring the network while it happens

The addon tells you what the client sees. `tools/wownet.sh` tells you what the network sees, and the two together are what settle the argument. It finds the game servers you are connected to right now and runs a TCP `mtr` against each one.

**Run it while the lag is happening — not before, not after.** A clean report taken ten minutes later proves nothing. The entire value is in having a network measurement that overlaps the bad window, so you can hold it against the latency the game was reporting in that same minute.

```bash
sudo -v && bash tools/wownet.sh
```

Written and tested on macOS. It should work on GNU/Linux as well: it only needs `lsof` and `mtr`, and it matches connections by port rather than by process name, so the client running under Wine or Proton makes no difference.

Two environment variables:

```bash
CYCLES=100 OUTDIR=~/wowlogs bash tools/wownet.sh
```

`CYCLES` is the number of probes per host (default 50, roughly one per second, so it also sets how long the run takes). `OUTDIR` is where the `<ip>.log` reports are written (default: current directory).

### Reading the result

The script prints the destination row of each report, which is the only row that proves anything:

```
  17.|-- 24.105.52.31    0.0%  50  184.5  204.2 176.1 1186.   141.9
  19.|-- 64.224.29.233   0.0%  50  216.4  227.0  51.3  846.3   92.6
```

Loss at intermediate hops with a clean destination is routers deprioritizing their replies, not packets being dropped. A packet cannot cross a hop that loses 94% and still arrive intact at the next one. Only loss that persists all the way to the last row is real.

The probes are TCP on port 3724 on purpose: Blizzard drops ICMP, so a plain `ping` or a default `mtr` reports 100% loss at the destination and tells you nothing at all.

### What the two endpoints mean

The client holds two connections: one to the realm/chat server (home) and one to the world server. They leave over the same link, so comparing them is a controlled experiment.

If the path to the world server comes back clean — no loss, normal round trip — while the game is reporting a second of world latency and home latency hasn't moved, the delay isn't in transit. The server is taking that long to answer.

## Cost

In the steady state LagScope does one subtraction per frame. Per-addon counters are read when you ask for a report, not on a timer, so the monitor doesn't become part of the problem it measures.

## Known limits

- `GetNetStats` refreshes latency roughly every 30 seconds, so per-second correlation isn't possible. The shape of the curve is what's meaningful, not the exact millisecond on a given frame.
- If BugSack/BugGrabber installs its error handler after LagScope, the error counter stops seeing errors. Everything else keeps working.
- Frame hitch attribution names the addon that used the most CPU *in that frame*. When a 1800 ms hitch shows a 70 ms addon, the addon is 4% of it — the rest is the client waiting on something else. Read the ratio, not just the name.
