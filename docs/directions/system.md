# System (direction 3)

The machine: our own background processes (statusline, Hammerspoon, samplers, collectors), disk writes, swap and
stores. The owner chat is «Передача system-doctor-ux»: System doctor's own fixes are that chat's or the night's
System fixer's, never a side job of another direction.

## Metric

- Own background CPU-min/day, from System doctor `~/.cache/system-doctor/latest.json` (`background`).
- SSD GB written a day, from `days.jsonl` (`ssd_gb_day`; `swap_gib_day` beside it).
- Third-party and Apple processes are watched, never worked. On 10-15, in CPU-min/day: claude 377, WindowServer
  223, codex 154, Jump 148.
- Test CPU (`run-suites`, 86 CPU-min/day) belongs to Lost time.

## State on 2026-10-15 (7.4 days)

| own process | CPU-min/day |
|---|---:|
| Hammerspoon | 98 |
| `statusline.sh` | 66 |
| `worker-run` | 22 |

| | 10-06 … 10-13 | 10-14 | 10-15 |
|---|---|---:|---:|
| SSD written, GB/day (limit 200) | 137–576 | 756 | 670 |
| swap written, GiB/day | 0–46 | 398 | 338 |

The cause of the swap jump is unknown: the doctor's memory column does not see per-process RSS (1.5 GiB average
in total). On 10-14 claude used 27 CPU-hours, against 4 the day before.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 10-06 | statusline render cuts | ≈230 → 120 ms CPU a render; the interval stays 3 s | `docs/handoffs/2026-10-05-hook-cuts-left.md` |
| 10-13 | ssd-sampler v3 installed as a system service: per-process writes, CPU, memory | | |
| 10-13 | token-map writer fixed | writes 1.3 GB/h → 3.5 MB/h | |
| 10-13 | Background grouped by project | | |
| 10-14 | Hammerspoon tab poll made idle-adaptive | CPU 0.068 → 0.07 cores, not proven | hammerspoon b4a4941, 75d60db |
| 10-14 | the System doctor's blind spot | | 7fcf0fc1 |

## Why the statusline was pushed

The 10-13 research (`docs/system-doctor-design.md`) found a spawn storm of 1,150–1,430 process births a second:
- at night the statusline made 52.5 % of the births;
- the kernel spent ≈43 % of task CPU on short-lived processes' lifecycle, a cost that is not in the statusline's
  own 66 min.

Births were down to 118 a second on 10-15.

## Decisions

- The statusline refresh stays 3 s.
- Apple causes are reported only. Disk cleanup, the bench pool and Spotlight are Egor's trades.
- transcriptions-gpt's overlay CPU and daemon writes are accepted.

## Open

- The swap and SSD jump since 10-14: who holds the memory at the peaks (owner chat).
- The statusline cohort has no measured baseline.
- The owner chat's pending check of `worker-run`'s CPU.
