# How fast is the pen, and where does the time go

Measured 2026-11-14 on the owner's MacBook Pro (M3 Pro, built-in 120 Hz display), macOS 26.6.2,
Wine Staging 11.16 with our IOSurface patch, SAI Ver.2, Wacom Intuos BT S over Bluetooth, app
0.3.14. Low Power Mode off, timelapse recording on, the DLL's debug log on.

## Short version

**Our own code is already fast.** From the moment macOS stamps a pen event to the moment SAI has
the point, our part takes well under 0.1 ms. Nothing in it is worth optimising further, and two
attempts to do so earlier the same day made it no better (see "Tried, not worth it").

**The time that can be felt is in three places, none of them the pen path:**

1. **The tablet itself.** Points arrive 7.6 ms apart on average (about 132 Hz), and most longer
   strokes contain at least one pause of 20 to 40 ms between two points. The pauses are already in
   macOS's own event stamps, so they happen before any of our code. Bluetooth or the Wacom driver;
   which of the two was not tested. A minute of drawing over USB would tell.
2. **The click that starts a stroke.** SAI starts a stroke on the mouse click Wine makes from the
   pen touch, and that click reaches SAI about 10 ms after our first packet. Since 0.3.14 our first
   packets wait for it, so the start of the line is no longer lost; it appears about 10 ms later
   instead. The delay is inside Wine: it picks mouse events up once per display frame (8.3 ms at
   120 Hz). Whether macOS or Wine sets that rhythm is the one question left open.
3. **Rare waits of 2 to 9 ms** before macOS hands a pen event to our tap (about 1.5% of events),
   and rare long waits in SAI's own message queue (one of 131 ms in a short session). Neither moved
   when we changed our code.

**One thing was fixed on the way:** the DLL no longer opens its control files about a hundred times
a second while the pen is idle. Pinch to zoom and "wake SAI" now travel on the pen port. Branch
`control-over-udp`, tested on the device, not merged yet.

## The pen path, stage by stage

| Stage | Typical | Worst seen | Ours? |
|---|---|---|---|
| Tablet makes a point (interval between points) | 7.6 ms | 42 ms | No |
| macOS stamps the event, our tap sees it | under 0.25 ms | 4.9 ms (1.5% over 2 ms) | No |
| Our tap callback, start to finish | 0.06 ms | 1.1 ms | Yes |
| ... of which the UDP send | 0.04 ms | 1.0 ms | Yes |
| ... of which handing the sample to the file writer | 0.01 ms | 0.06 ms | Yes |
| App to DLL (above the fastest delivery seen) | 0.10 ms | 2.45 ms | Yes |
| DLL: datagram received to `PostMessage` done | 0.02 to 0.05 ms | 1.8 ms | Yes |
| DLL: `GetCursorPos` + `GetWindowRect` per hover sample | 0.02 ms | 0.3 ms | Yes |
| SAI's message queue holds the packet | under 0.25 ms | 131 ms (p99 3 to 4 ms) | No |
| SAI draws, Wine and macOS put it on screen | not measured | not measured | Partly |

Numbers come from one session of 39 strokes and about 14 seconds of pen-down time (1797 points),
so the "typical" column is solid and the "worst seen" column is not.

Other things that session showed:

- SAI kept up. Of 1797 pen-down points, one was merged with its neighbour; SAI had no unread packet
  waiting 94 to 97% of the time. So the idea of posting a merged point sooner has almost nothing to
  act on, and `POST_WINDOW` (3) is not what limits anything.
- Short strokes and long strokes wait the same before our tap (1.3% and 1.6% of events over 2 ms).

## The click that starts a stroke

SAI ignores our pen-down packets until it has taken the left-button click that Wine makes from the
same touch. 0.3.14 holds the first packets back until SAI takes that click (at most 30 ms), which is
why the start of a stroke is no longer lost. The cost is that the stroke begins when the click
arrives. Three probes followed the click through its path:

| Point on the click's way | When |
|---|---|
| The click is made | With the first pressure: in 65 touches of 65, the first event carrying pressure **is** the mouse-down. The stamp Wine gives the click equals our first packet's time to within 1 ms in 62 of 62. |
| Our tap (HID level) sees it | 0.07 ms after its stamp (worst 1.9 ms) |
| A tap at the last stop before the app (annotated session) sees it | 0.1 to 0.2 ms |
| Wine's thread in SAI handles it (`macdrv_mouse_button`) | 4 to 9 ms after its stamp (19 clicks) |
| SAI takes the click off its queue | 0 to 3 ms after that; **7 to 12 ms in all**, median 10 (62 clicks) |

So the click is made on time and macOS has it ready within a fraction of a millisecond. It then
waits before Wine's thread gets to it. This is not Bluetooth: the click and the first pressure
sample are the same event and travel together, yet our packet from that event is in SAI in a
fraction of a millisecond.

**Wine handles mouse events on a rhythm.** In Wine's own trace, the time between two handled mouse
events is 8 or 9 ms in 652 cases of 1017, then 17 ms and 25 ms: one, two or three steps of 8.3 ms,
which is one frame of the 120 Hz display. The events themselves are stamped anywhere from 4 to 12 ms
apart. A click therefore waits for the next step, half a frame on average, plus handling. Ordinary
mouse moves show the same thing: their age when handled is spread evenly from 1 to 9 ms.

**Not found out:** who sets the rhythm. Either macOS delivers mouse events to every app once per
display frame (then there is nothing to fix), or Wine's Mac driver only passes them on once per
frame (then it could be changed in our Wine patch). The probe for it is built: branch
`click-delay-probe` logs when an ordinary Mac app, ours, receives pen events (`LOCAL` and `GLOBAL`
lines in `/tmp/sai-click.log`). It was not run. Prediction if it is macOS: the `LOCAL` receive
times sit on the same 8.3 ms grid.

**What it would be worth:** 5 to 8 ms at the very start of each stroke, and nothing during it,
because points inside a stroke travel our own path and do not wait for Wine's mouse events.
Supplying the click ourselves is not an option: rewriting SAI's mouse messages has stopped the pen
from drawing altogether twice (#19).

Separately from the usual 10 ms: in the second session, 4 strokes of 88 had no click within the
30 ms limit (their packets were posted without it), and one of those got no click at all in 128 ms
and was lost. That is the known rare lost stroke (`wtc_nc_*` in `wintab_core.h`), cause still
unknown.

## Fixed on the way: control files polled all the time

While the pen was not drawing, the DLL's producer thread opened files to see if they had changed:
the sample file at every 15 ms tick (67 times a second, even with the UDP stream working),
`wt_zoom.txt` every 30 ms, `wt_wake.txt` every 150 ms. Each open is a round trip to wineserver,
which SAI's own thread also waits on. None of it ran during a stroke, so it never showed in the pen
numbers; it cost CPU while idle and made a pinch wait up to 30 ms.

Branch `control-over-udp` (`7ed42bb`):

- pinch to zoom and "wake SAI" are sent as datagrams on the pen port (`Z <steps>`, `K <token>`);
- the files are still written and read, as a fallback: the zoom file only while the pen port is not
  ours, the wake file once a second, the sample file four times a second;
- the tap no longer waits for the disk on every zoom step;
- the message hook no longer calls `getenv` on SAI's thread for every message SAI takes;
- a zoom is sent as a change, not a running total, so restarting the app with SAI open can no
  longer make the canvas jump; each wake request has a name that is new for every start of the app,
  so the first wake after a restart can no longer be mistaken for an old one.

Checked on the device: 88 strokes and 5099 points with none lost, pinch (20 steps, all by
datagram), two-finger pan, and wake (24 requests carried out). How much idle CPU it saves was not
measured.

## Tried, not worth it

- **Shared memory instead of UDP** (branch `experiment-shm-transport`): about 0.5 ms slower, because
  the DLL has to poll the ring while UDP wakes it.
- **The event tap on its own thread** (branch `tap-thread`): no fewer waits; 1.11% of events over
  2 ms against 0.70% in one round. The main thread was not the cause of the rare waits.
- **Skipping the Wine calls on hover samples, skipping the file hand-over:** measured at 0.02 ms and
  0.01 ms. Not done.
- **Posting a merged point sooner** (variant "wake" in the measuring build): the case came up once
  in 1797 points. Nothing to compare.

## Not settled

- **A higher priority for the DLL's pen thread.** In the measuring build three variants took turns,
  six strokes each. With normal priority 8 packets waited over 5 ms in SAI's queue (one of them
  131 ms); with the highest priority none did, and the longest wait was 3.3 ms. Too little data to
  call it: the normal-priority variant also drew the session's first strokes and had 2.5 times as
  many points. It is one line if a longer round confirms it.
- **Whether recording is behind the long waits in SAI's queue.** Recording was on for every session
  here. The measuring build notes it in each report; a few minutes with it off would tell.
- **USB against Bluetooth**, for the tablet's pauses.
- **SAI to the screen** (stage 6). Needs a phone filming at 240 frames per second; no code.
- **SAI's stabiliser.** A brush with the stabiliser at S-1 or above is delayed by SAI on purpose,
  by more than everything above together. Worth a look before blaming anything else.
- **The debug log.** With "DLL logging" on (Advanced tab), SAI's own thread writes a line per click
  and per 64 points. It was on throughout; users have it off.

## How this was measured

Three local branches, none merged and none pushed. Each builds a separately named test app into
`dist/` with its own bundle id.

| Branch | What it adds | Where the numbers go |
|---|---|---|
| `measure-all` | Meters on both sides (`wintab-src/measure_core.h`, `wacom-helper/MacMeasure.swift`); three DLL variants taking turns | `C:\wt_measure.txt` in the prefix, `/tmp/sai-measure.log` |
| `control-over-udp` | The fix above | the usual `wtlog.txt` |
| `click-delay-probe` | Two extra listen-only taps and two event monitors for the click; `CLICKTIME` and `MOUSEAGE` lines from the DLL; Wine started with `WINEDEBUG=+timestamp,+event,+cursor` | `/tmp/sai-click.log`, `wtlog.txt`, `/tmp/sai-wine-trace.log` |

`click-delay-probe` slows SAI a little (Wine's trace) and is for measuring only.

The stroke-start and mid-stroke lines of the ordinary debug log (`START ...`, `MID ...`) were enough
for the tablet's pauses and the click's delay; the meters were needed for everything under a
millisecond.
