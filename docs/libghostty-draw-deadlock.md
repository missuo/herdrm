# Known hang: main thread deadlocks in `ghostty_surface_draw` (libghostty draw-mutex family)

Status: **not fixable in herdrm today** — the deadlock is inside the pinned,
prebuilt GhosttyKit binary. The upstream fix exists but is not merged or
released yet. This page records the diagnosis so the next occurrence is
recognizable, and defines the bump condition that closes it.

- Hang artifact: `crash.log` (system spindump, 2026-10-26 08:49, herdrm PID 64524,
  debug build from this repo, ~39 h uptime, 11 surfaces)
- Upstream family: [ghostty-org/ghostty#14245](https://github.com/ghostty-org/ghostty/issues/14245)
  (fix: [PR #14444](https://github.com/ghostty-org/ghostty/pulls/14444), milestone 1.4.0, **open**)
- Our pinned ghostty ref: `82938b633b…` (libghostty-spm `1.6.20260909`, built 2026-09-09)

## What the hang looks like

The app beachballs forever; the spindump shows `Event: hang`, main thread
unresponsive, and this stack (61/61 samples, i.e. the entire sampled window):

```
MSDisplayLink CVDisplayLink callback (dispatched to main queue)
→ TerminalSurfaceCoordinator.synchronization(context:)   TerminalSurfaceCoordinator.swift:627
→ TerminalSurfaceCoordinator.tick()                      TerminalSurfaceCoordinator.swift:487
→ TerminalSurface.draw()                                 TerminalSurface.swift:194
→ ghostty_surface_draw
→ drawFrame → draw_mutex.lockUncancelable               (renderer/generic.zig:1616)
→ __ulock_wait2                                           ← blocked in kernel, never wakes
```

`ghostty_surface_draw + 16` is the return address of the function's very first
call (disassembly: `stp/mov/mov w1,#1; bl …`), i.e. the main thread never got
past acquiring the renderer's `draw_mutex` (Zig `std.Io.Mutex` → `os_unfair_lock`
→ `__ulock_wait2`).

## Who holds the mutex

The spindump lists 11 `renderer` threads (one per surface). Ten are parked in
`kevent64` (idle xev loop). One — thread `0x3438612` — is different in two ways:

1. **`priority 47 (base 47)`** while every sibling is `base 20`. os_unfair_lock
   turnstiles propagate priority: the priority-47 main thread blocking on the
   lock boosts its holder to 47. This thread is the holder.
2. Its 4th stack frame is Zig code (`herdrm.debug.dylib + 19016320`), **not**
   `kevent64` — it is parked inside work, not idle. Its `last ran 71.952s`
   matches the main thread's `71.950s` to within 2 ms: they blocked on each
   other in the same instant.

Symbolicating `+ 19016320` (`0x1222a80`) lands in a static (unnamed) Zig
function whose instruction at that address is the return slot of
`blr x8` — an indirect call through a `(context, fn)` pair loaded from the
object (`ldp x0, x8, [x23, #0x58]`). That is the calling shape of Zig's
`std.Io` interface operations — i.e. the renderer thread is blocked in an
**uncancelable `std.Io` wait while holding `draw_mutex`**.

## Root cause (mechanism)

In the **embedded** apprt, `apprt.must_draw_from_app_thread` is false
(`src/apprt/embedded.zig` does not define it; only GTK does). So besides the
app thread's own display-link draws, ghostty's per-surface renderer thread
also executes `renderer.drawFrame(false)` itself whenever it wakes with work
and its internal vsync link is not running (`Thread.drawFrame`:
`if (!now and self.renderer.hasVsync()) return;` and `hasVsync()` is false
whenever `syncDisplayLink` has stopped the idle link). That idle→wake
transition is exactly when this hang started: all renderers had been quiet,
then one woke and drew.

Two candidate terminal waits sit under `draw_mutex` on that path, both
uncancelable, both `std.Io`-interface calls, and both only resolved by
progress the frozen app thread can no longer provide. The artifact does not
distinguish between them, and the remediation is identical:

1. `drawFrame` → `swap_chain.nextFrame()` → `frame_sema.waitUncancelable(io)`
   (`renderer/generic.zig:304`, called at `:1689` under `draw_mutex` locked at
   `:1616`). The semaphore is only posted by `frameCompleted` — the
   graphics-API frame-completion callback. If Metal never completes the
   in-flight frames (display reconfiguration, occluded layer, drawable
   stall), the wait never ends. User reports on the same family mention
   monitor attach and app switching as triggers.
2. A `.forever` mailbox push (e.g. `frameCompleted`'s `renderer_health` push
   at `generic.zig:1934`, or the stream-handler pushes from the io side) into
   the app mailbox — a `BlockingQueue(Message, 64)` in `App.zig` **drained
   only by `App.tick` on the app thread**. Queue full + app thread blocked on
   `draw_mutex` = the exact deadlock shape documented upstream in #14245.

Either way: renderer thread parks holding `draw_mutex`; the next display-link
tick on main enters `ghostty_surface_draw`, blocks on the same mutex, and the
app hangs permanently. (Had main *not* been drawing, the blast radius would
have been one frozen pane instead of the whole app.)

## Why herdrm cannot fix this in-tree

- The blocking wait is compiled into `GhosttyKit.xcframework` (binary
  dependency, checksum-pinned). No config knob avoids it: `vsync = false`
  makes the renderer thread self-draw *more*; `vsync = true` (default) still
  stops the internal link when idle and re-opens the window at wake.
- The Swift render path (`TerminalSurfaceCoordinator.tick() → draw()`) is
  `final` and internal to the package — `LineBreakTerminalView` cannot
  override or bound it.
- Bumping today does not help: latest libghostty-spm `2.2.2026102101`
  (checked 2026-10-26) pins ghostty `1e9e14af5df1` — the #14245 fix series
  ("surface: keep the app mailbox draining while joining threads", PR #14444)
  is still unmerged, so **no released libghostty contains the fix**. Our ref
  already includes the earlier, related fix #14171 ("never stop the display
  link while holding the draw mutex", 82232ecd, 2026-09-07).

## What we do about it

1. **Bump when the fix ships.** When a libghostty-spm release's pinned ghostty
   commit contains PR #14444 (check the release body's "Ghostty commit" link
   for `keep the app mailbox draining` / the PR merge), bump `exactVersion` in
   `project.yml` per the supply-chain review rules, and retire this page.
2. **Report the variant upstream** — our stackshot is field evidence for the
   open PR: same family, different entry point (`surface_draw` from the app
   display link vs `surface_free`). Draft comment below.
3. **Recovery until then:** if herdrm beachballs with this signature, force
   quit is the only out (`killall -9 herdrm`); unsaved pane state is lost by
   definition of a hang, not additionally.

## Paste-ready upstream comment for #14245

> Another shape of this family, this time entering from the **app draw path**
> rather than `surface_free` — herdrm (macOS SwiftUI app embedding
> libghostty-spm 1.6.20260909, ghostty `82938b633b`, i.e. post-#14171) hung
> with the whole app frozen:
>
> - **App (main) thread** (61/61 samples over the whole spindump window):
>   host display-link tick → `ghostty_surface_draw` → `Surface.draw` →
>   `Renderer.drawFrame` → `draw_mutex.lockUncancelable` → `__ulock_wait2`.
>   It never gets past the lock (the blocked PC is the return address of
>   `drawFrame`'s first call).
> - **One `renderer` thread** holds the mutex: it is the only renderer parked
>   outside `kevent64`, and macOS's os_unfair_lock turnstile boosted it from
>   base 20 to 47 at the same instant the main thread blocked (`last ran`
>   71.952 s vs 71.950 s — within 2 ms). Its deepest walked frame resolves to
>   the return slot of an indirect `std.Io`-interface call inside a static
>   Zig function — consistent with an uncancelable wait under `draw_mutex`
>   (`frame_sema.waitUncancelable` in `nextFrame`, or a `.forever` push into
>   the app-drained mailbox).
> - All other per-surface `io`/`renderer`/`cf_release` threads idle in
>   `kevent64`; nothing else is stuck. 11 surfaces, ~39 h uptime, one
>   occurrence — the classic idle→wake transition (renderer self-draws when
>   `hasVsync()` is false because `syncDisplayLink` stopped the idle link).
>
> Since the embedded apprt leaves `must_draw_from_app_thread` false, the
> renderer thread runs `drawFrame` itself on wake, so any uncancelable wait it
> hits under `draw_mutex` takes down the app thread's next draw too. Field
> reports on this family (monitor attach / app switch) match a Metal
> frame-completion stall starving `nextFrame`.
>
> Happy to share the raw spindump if useful.

## Detection quick-reference

If this hang recurs, confirm it in one minute:

```sh
sample <pid> 5 -file /tmp/hang.txt
grep -A3 "ghostty_surface_draw" /tmp/hang.txt        # main thread stuck pre-lock
grep -B2 -A6 "Thread name: \"renderer\"" /tmp/hang.txt | grep -A4 -e priority -e dylib
```

A renderer thread showing `priority 47 (base 47)` + a non-`kevent` deepest
frame while main sits in `ghostty_surface_draw` is this bug.
