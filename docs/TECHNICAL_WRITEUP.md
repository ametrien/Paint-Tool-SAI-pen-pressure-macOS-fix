# PaintTool SAI 1.2.5 on Whisky/Wine (Apple Silicon M3) — Full Technical Writeup

End-to-end record of the investigation, the exact sources/repos used, the C patches
we wrote to `wineserver`, everything we ruled out, and the challenges still open.

---

## 1. Goals

1. Make **PaintTool SAI 1.2.5** launch and run under **Whisky** on **macOS / Apple Silicon (M3)**.
2. Get **pen pressure** (tablet / WinTab) working.

## 2. Environment (as measured)

| Thing | Value |
|---|---|
| Machine | MacBook Pro, Apple **M3**, macOS Darwin 25.x, **arm64** |
| Wrapper | **Whisky 2.5.0** (`com.isaacmarovitz.Whisky`) |
| Wine engine | Bundled **WhiskyWine = CrossOver 22.1.1, Wine 7.7** + Apple GPTK, with **esync + msync** |
| Server protocol | **762** (this number is critical — see §5) |
| Toolchain present | Xcode CLT (clang 17), Homebrew, autoconf, `bison 3.8` (Cellar), flex, Rosetta 2 |
| Bottle | `8B587661-05A9-4D5F-9101-AD181A74ACA2` — "XP Bottle SAI2", `winxp64`, reports **Windows Server 2003 SP2**, UAC=0 |
| SAI | Real install at `C:\PaintToolSAI\sai.exe` (installer run inside the bottle) |

Wine binaries live in:
```
~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/{wine64,wineserver,...}
```
Bottle (WINEPREFIX):
```
~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/8B587661-.../
```

## 3. Why this needed a *custom Wine* and not config tweaks

SAI's failure was not a real permission problem. Via `WINEDEBUG=+security` we saw SAI run
its **own ACL self-test**:

1. Build an ACL granting *Everyone* (SID `S-1-1-0`) full control (access mask `0x001f01ff`).
2. `SetFileSecurityW` → `NtSetSecurityObject` — **write** that descriptor onto its data folder.
3. Immediately `NtQuerySecurityObject` / `RtlGetDaclSecurityDescriptor` — **read it back and verify it matches**.
4. Repeat on the `thumbnail` subfolder.

macOS/APFS has no NTFS security descriptors. Wine's server stores only POSIX mode bits and
**reconstructs** a descriptor on read via `mode_to_sd()` — which never reproduces the exact
ACE layout SAI wrote. So SAI's verify step always fails → it logs *"Directory not have access
rights"* and exits. No amount of `chmod`/`xattr`/`attrib`/registry could fix a set/read-back
mismatch that happens **inside Wine before touching the real filesystem**. Hence: patch Wine.

Only **`wineserver`** implements security-descriptor storage, so that's the *only* binary we
had to rebuild. The client DLLs stay stock.

## 4. Sources / repositories used

| Purpose | Source | Notes |
|---|---|---|
| The Wine tree to build | **CrossOver 22.1.1 GPL source** — `https://media.codeweavers.com/pub/crossover/source/crossover-sources-22.1.1.tar.gz` (~147 MB) | Free, GPL-mandated. Use `sources/wine`. Its `VERSION` = `Wine version 7.7`. This is the exact fork Whisky's engine is built from. |
| Protocol match | **`marzent/wine-msync`** — `https://github.com/marzent/wine-msync` → file **`msync-cx22.patch`** | Adds macOS `msync` server requests. Bumps `SERVER_PROTOCOL_VERSION` **755 → 762**. |
| Reference (wrapper) | **`Whisky-App/Whisky`** — `https://github.com/Whisky-App/Whisky` | Confirmed engine = CrossOver 22.1.1 + GPTK; Wine tarball served from `data.getwhisky.app`. |

We did **not** use upstream WineHQ source: it produces a different server protocol version and
would fail the client/server handshake.

## 5. The protocol-version trap (why the first build didn't load)

First build = CrossOver 22.1.1 vanilla → `SERVER_PROTOCOL_VERSION 755`. The installed client
DLLs expect **762**, so launching gave:

```
wine client error:0: version mismatch 755/762.
```

Diagnosis: the installed `ntdll.so` references **both** `esync` and `msync`; vanilla CX 22.1.1
has only esync. Whisky adds **msync** via `marzent/wine-msync` (`msync-cx22.patch`), which adds
server requests and bumps the protocol exactly 755 → 762. Applying that patch fixed the
handshake. (The patch's new files `server/msync.c`, `dlls/ntdll/unix/msync.c` etc. are created
with git-style diffs — apply with `git apply`, not BSD `patch`, which fumbles new-file hunks.)

## 6. The C patches we wrote

All against the CX 22.1.1 `sources/wine` tree, after `msync-cx22.patch`.

### 6a. `server/file.c` — cache exact SD for **files**

Add include:
```c
#include <sys/xattr.h>
```

In `file_set_sd()`, after the `fchmod` block that applies DACL bits, cache the exact descriptor
and also persist it to a macOS xattr:

```c
/* Preserve the exact security descriptor the app wrote instead of letting it
 * get reconstructed (lossily) from the resulting POSIX mode bits on the next
 * query. PaintTool SAI writes an SD and immediately reads it back to verify;
 * mode_to_sd() never reproduces the original ACE layout, so the verification
 * always fails without this cache. */
{
    data_size_t sd_size = sizeof(*sd) + sd->owner_len + sd->group_len +
                           sd->sacl_len + sd->dacl_len;
    struct security_descriptor *copy = mem_alloc( sd_size );
    if (copy)
    {
        memcpy( copy, sd, sd_size );
        free( obj->sd );
        obj->sd = copy;
        if (fstat( unix_fd, &st ) != -1) { file->mode = st.st_mode; file->uid = st.st_uid; }
    }
    /* persist across separate opens (SetFileSecurityW and GetFileSecurityW use
     * different handles, so the in-memory obj->sd cache alone isn't enough) */
    fsetxattr( unix_fd, "user.wine.sd", sd, sd_size, 0, 0 );
}
```

In `file_get_sd()`, before the `mode_to_sd()` fallback, return the cached xattr blob verbatim
if present and self-consistent:

```c
{
    char xattr_buf[65536];
    ssize_t len = fgetxattr( unix_fd, "user.wine.sd", xattr_buf, sizeof(xattr_buf), 0, 0 );
    if (len >= (ssize_t)sizeof(struct security_descriptor))
    {
        const struct security_descriptor *x = (const struct security_descriptor *)xattr_buf;
        if ((data_size_t)len == sizeof(*x) + x->owner_len + x->group_len + x->sacl_len + x->dacl_len)
        {
            struct security_descriptor *copy = mem_alloc( len );
            if (copy) { memcpy( copy, xattr_buf, len ); free( obj->sd ); obj->sd = copy;
                        file->mode = st.st_mode; file->uid = st.st_uid; return copy; }
        }
    }
}
```

### 6b. `server/change.c` — same fix for **directories** (this is the one SAI needed)

Directories are a *different* server object (`struct dir`, handlers `dir_set_sd` / `dir_get_sd`).
SAI sets security on **folders**, so the file.c patch alone did nothing — the directory version
is what actually unblocked SAI. Same include (`<sys/xattr.h>`) and the identical cache-write in
`dir_set_sd()` (using `dir->mode`/`dir->uid`) + cache-read in `dir_get_sd()`.

### 6c. `server/window.c` — throttle a pathological `EnumWindows` busy-loop (for Problem 2)

Add `#include <unistd.h>`. At the top of `DECL_HANDLER(get_window_children)`:

```c
/* Throttle pathological EnumWindows busy-loops (PaintTool SAI spins
 * get_window_children ~70,000x/sec on one thread, pegging this single-threaded
 * server and starving the UI thread's winemac events). Detect the same thread
 * repeating the identical query 64+ times back-to-back and usleep() to cap the
 * rate. Gated so tightly no normal app is ever affected. */
{
    static unsigned int last_thread, last_parent, last_atom, last_tid, last_desktop, repeat;
    unsigned int tid = current ? current->id : 0;
    if (tid == last_thread && req->parent == last_parent && req->atom == last_atom &&
        req->tid == last_tid && req->desktop == last_desktop && !cls_name.len)
    {
        if (++repeat > 64) usleep( 250 );
    }
    else { last_thread=tid; last_parent=req->parent; last_atom=req->atom;
           last_tid=req->tid; last_desktop=req->desktop; repeat=0; }
}
```

## 7. Build recipe (server only)

```bash
tar xzf crossover-sources-22.1.1.tar.gz sources/wine
cd sources/wine
git apply /path/to/msync-cx22.patch          # protocol 755 -> 762, adds server/msync.c
git apply /path/to/sai-acl-selftest-fix.patch # + the file.c/change.c/window.c edits above
echo '#define DISTVERSION "7.7"' > programs/winedbg/distversion.h   # missing header stub

mkdir build-x86_64 && cd build-x86_64
PATH="/opt/homebrew/opt/bison/bin:$PATH" \
CC="clang -arch x86_64 -mmacosx-version-min=10.13" \
../configure --host=x86_64-apple-darwin --disable-tests --enable-win64 \
  --without-freetype --without-fontconfig --without-gettext --without-gstreamer \
  --without-cups --without-sane --without-gphoto --without-capi --without-dbus \
  --without-krb5 --without-gssapi --without-ldap --without-netapi --without-opencl \
  --without-openal --without-osmesa --without-sdl --without-udev --without-usb \
  --without-v4l2 --without-vulkan --without-pcap --without-x
PATH="/opt/homebrew/opt/bison/bin:$PATH" make -j$(sysctl -n hw.ncpu) server/wineserver
```

Gotchas encountered:
- **`bison` 2.3** (system) too old → put Homebrew `bison 3.8` first on `PATH`.
- 32-bit host `makedep` link failed (`_fopen$UNIX2003`) → use `--enable-win64` (builds the
  64-bit `wineserver` we need and skips the broken 32-bit host path).
- `programs/winedbg/resource.h` includes a **`distversion.h`** that isn't in the tarball →
  create a one-line stub.
- Target **x86_64** (Whisky's Wine is x86_64 under Rosetta), not arm64.

Install (back up first!):
```bash
WB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"
cp "$WB/wineserver" "$WB/wineserver.orig-backup"   # 631888 bytes, stock
cp build-x86_64/server/wineserver "$WB/wineserver"
```
Revert = copy `wineserver.orig-backup` back. **Decline any Whisky "update Wine" prompt** — it
overwrites the patched server.

## 8. What we EXCLUDED (with evidence)

### Problem 1 (launch) — none of these were the cause:
1. Unix filesystem perms — 777 on both folders, no change.
2. Parent folder blocking — `ProgramData` normal 755.
3. macOS quarantine / xattr — `xattr` empty.
4. Wrong path / registry redirect — `%ProgramData%` resolves correctly.
5. Missing folder — folder + subfolder pre-existed.
6. Raw filesystem open — `+file` trace showed `NtCreateFile` succeeding.
7. macOS-native ACLs — `ls -le` showed none.
8. Windows DOS attributes — `attrib` blank on both.
9. UAC / OS-version — identical failure on the UAC=0 XP bottle.

→ **Real cause:** the Wine security-descriptor **set/read-back self-test** (§3). Fixed in §6a/§6b.

### Problem 2 (freeze) — ruled out:
- msync vs esync — freezes identically with both.
- Our ACL/xattr patch — server sample shows it idle/healthy, not in `getxattr`.
- General server-build breakage — **Notepad runs perfectly** on the same patched server.
- WinTab error alone / virtual-desktop mode / window hierarchy — none change the freeze.

→ **Real cause:** a SAI thread spins **`get_window_children`** (`EnumWindows`) ~70,000×/sec
(831,604 of 906,162 server calls in 12 s), saturating the single-threaded server and starving
the UI thread. Fix under test in §6c.

## 9. Current status & open challenges

| Item | Status |
|---|---|
| **Launch SAI** (ACL self-test) | ✅ **Solved** — `file.c` + `change.c` + `user.wine.sd` xattr; protocol matched via `msync-cx22`. SAI opens to full UI. |
| **Freeze on menu/canvas** | ⏳ Throttle patch (§6c) under test. If starvation → fixed; if not → needs `+relay` trace to see the unsatisfiable wait. |
| **Pen pressure (WinTab)** | ❌ Not started. `errlog` shows `wintab.c(655): WTInfo(WTI_INTERFACE, IFC_SPECVERSION)` failing — Wine's `wintab32` doesn't bridge macOS tablet/`NSEvent` pressure. Likely the real Goal-2 work: a `wintab32` that feeds pressure from the Mac driver. |

### Debugging notes for future sessions
- `winedbg` **crashes with SIGFPE** in this build — can't get Windows-side stacks that way.
- macOS `sample` works but shows emulated (PE) frames as `???`; only native `ntdll.so`/system
  frames symbolize. Good enough to tell "spinning on server calls" vs "idle waiting".
- Best PE-level visibility available: **`WINEDEBUG=+relay`** (logs every WinAPI call with a
  return address into `sai.exe`) and **`WINEDEBUG=+server`** (per-request histogram — how we
  found the `get_window_children` loop).

### Key artifacts
- `sai-acl-selftest-fix.patch` — original file.c hunk (the fix later extended to change.c + xattr + window.c).
- `wineserver.orig-backup` — stock server (revert target).
- `PaintTool SAI errlog.txt` — SAI's own log (`C:\PaintToolSAI\errlog.txt` in the bottle); the ground truth for whether a run passed the ACL check.

---

## 10. UPDATE — the winning pivot: 64-bit SAI Ver.2 + rebuildable winemac.drv

### SAI 1.2.5 freeze: not solved, but sidestepped
SAI 1.2.5's freeze is a **timing livelock** — its UI thread busy-loops `get_window_children`
(EnumChildWindows) + `GetProp(_SFLWININFO_/_SFLWINAPR_)` without pumping messages, waiting on a
window-property condition that only resolves if another thread runs first. Only a **global
slowdown** breaks it: `WINEDEBUG=+relay ... >/dev/null` runs SAI 1.2.5 usably. A server-side
per-thread rate-cap on `get_window_children` (in `window.c`) did **not** fix it (proving it's
not pure CPU starvation). Left as: use relay, or use SAI2.

### The pivot that worked: SAI Ver.2 (64-bit)
- SAI **1.2.5 is 32-bit only** → forces CrossOver's proprietary **x86_32on64** layer, which is
  exactly what made rebuilding `winemac.drv` painful.
- **SAI Ver.2 (64-bit Technical Preview**, official: `https://www.systemax.jp/en/sai/`, file
  `sai2-YYYYMMDD-64bit-en.zip`, run `sai2.exe` **from its extracted folder**) runs as pure
  x86_64 under Rosetta — **no 32on64**, and its modern code has **no freeze**. It opens, draws,
  is smooth at full speed with the ACL-patched `wineserver`. **This is the usable SAI.**
- SAI2 supports **WinTab API and TabletPC API** (a "Pen Tablet Control API" setting in
  `sai2.ini` / Options) — two possible pressure paths.
- Known SAI2-beta issue: `!FileError(161): Path is invalid` on `...\SAIv2\hisdata\...` = its
  disk undo/history feature; aggravated by the user's disk being **95% full**. Free disk space.

### winemac.drv IS rebuildable (build wall broken)
Confirmed `winemac.drv.so` (the Cocoa Mac driver, unix side) builds and is **ABI-compatible**
with Whisky's runtime (swapped a vanilla rebuild in; SAI2 still opens/renders/draws). The
obstacles were all cross-toolchain tooling, fixed with a `toolbin/` on PATH:
- `x86_64-apple-darwin-{ar,ranlib,strip,nm,ld}` → wrapper scripts that `exec` the bare tool
  (the `/usr/bin/ar|ld` Xcode shims are argv[0]-sensitive and fail under the prefixed name).
- a **`clang` wrapper** that (a) `exec`s `/usr/bin/clang` for automatic macOS SDK detection and
  (b) strips flags native clang rejects: **`-mabi=ms`** (spurious on the trivial `32on64_ldt.c`)
  and **`-fuse-ld=lld`** (Apple clang has no lld; the system linker is fine for a `.so`).
- Build: `make dlls/winemac.drv/winemac.drv.so` with `PATH=toolbin:homebrew-bison:...`.
- Install: back up `lib/wine/x86_64-unix/winemac.drv.so` → `.orig-backup`, copy rebuild over it.

### Pen pressure — the remaining implementation (architecture confirmed)
Wine's `winemac.drv` has **zero** tablet code. `wintab32.dll` (present) loads the graphics
driver and calls four exports it expects: **`LoadTabletInfo`, `AttachEventQueueToTablet`,
`WTInfoW`, `GetCurrsorInfo`**. `winex11.drv/wintab.c` (~1600 lines, XInput-backed) is the
reference. Plan for a minimal Mac implementation:
1. **`cocoa_window.m`**: in the mouse handlers, read `[NSEvent pressure]` and the tablet
   subtype (`NSEventSubtypeTabletPoint`); currently discarded.
2. **`macdrv_cocoa.h`**: add a `pressure` (and proximity) field to the `mouse_button` /
   `mouse_moved` event structs (union in `macdrv_event`).
3. **new `dlls/winemac.drv/wintab.c`**: implement the 4 exports. `WTInfoW` reports 1 device
   with a pressure axis (0..1023) + a default context (this is the `WTI_INTERFACE/IFC_SPECVERSION`
   call SAI's log showed failing). Keep latest pressure in a global; on each mouse event post a
   `WTPACKET` (`pkX,pkY,pkNormalPressure,pkButtons,pkStatus`) to the attached window.
4. **`winemac.drv.spec`**: `@ cdecl LoadTabletInfo / AttachEventQueueToTablet / WTInfoW / GetCurrsorInfo`.
5. **`Makefile.in`**: add `wintab.c` to the module sources.
Headers available: `include/wintab.h`, `include/pktdef.h` (WTPACKET, LOGCONTEXTW, AXIS, WTI_*).

### Status
- **Usable SAI: DONE** — SAI Ver.2 64-bit, ACL-patched server, no freeze.
- **Pen pressure: IN PROGRESS** — build unblocked; writing the winemac tablet→wintab32 bridge.
