# Getting PaintTool SAI 1.2.5 to run under Whisky/Wine on Apple Silicon (M3)

A running log of the investigation and the custom Wine patches built to fix it.

## Goal

1. Get **PaintTool SAI 1.2.5** to launch and run under **Whisky** (Wine wrapper) on **macOS / Apple Silicon (M3)**.
2. Get **pen pressure** working (tablet / WinTab).

## Environment

- **Machine:** MacBook Pro, Apple M3, macOS (Darwin 25.x), arm64.
- **Whisky** `2.5.0`, bundling **WhiskyWine = CrossOver 22.1.1 Wine 7.7** + Apple GPTK, plus **esync + msync** (marzent's `msync-cx22.patch`). Server protocol version **762**.
- **Bottle used:** `8B587661-05A9-4D5F-9101-AD181A74ACA2` ("XP Bottle SAI2", `winxp64` / reports "Windows Server 2003 SP2", UAC=0).
- SAI installed at `C:\PaintToolSAI\sai.exe` (real install done inside the bottle).

---

## Problem 1 — SAI would not launch at all ("Directory not have access rights") ✅ SOLVED

### Symptom
SAI exited immediately at startup. Its own `errlog.txt`:

```
win_main.c(18256): Error - Directory not have access rights. [C:\ProgramData\SYSTEMAX Software Development\SAI]
win_main.c(18268): Error - Directory not have access rights. [C:\ProgramData\SYSTEMAX Software Development\SAI\thumbnail]
```

### Root cause (found via `WINEDEBUG=+security` trace)
SAI does **not** just check read/write permissions. It runs a **set-then-read-back self-test**:

1. Builds an ACL granting *Everyone* (S-1-1-0) full control (`0x001f01ff`).
2. `SetFileSecurityW` → `NtSetSecurityObject` on the folder (writes the security descriptor).
3. Immediately `NtQuerySecurityObject` / `RtlGetDaclSecurityDescriptor` to **read the ACL straight back and verify it matches**.
4. Repeats for the `thumbnail` subfolder.

Under Wine on macOS (APFS has no NTFS ACLs), the server reconstructs the security descriptor **lossily** from POSIX mode bits (`mode_to_sd()`), so the read-back never byte-matches what SAI wrote → SAI concludes "no access rights" and quits.

Ruled out beforehand (all confirmed *not* the cause): POSIX perms (777), parent folder perms, macOS quarantine/xattr, path/registry redirect, missing folders, raw file open, macOS-native ACLs, DOS attributes, UAC/OS-version.

### The fix — custom `wineserver`
Wine's `wineserver` (single binary compiled from `server/*.c`) is the only thing that needed rebuilding — the client DLLs are untouched. We used the **exact matching source**:

- **CrossOver 22.1.1 GPL source** (`https://media.codeweavers.com/pub/crossover/source/crossover-sources-22.1.1.tar.gz`) — free, GPL-required. `sources/wine`, `VERSION` = "Wine 7.7".
- Applied **`marzent/wine-msync` → `msync-cx22.patch`** to match Whisky's client protocol version **762** (vanilla CX 22.1.1 is 755; msync adds server requests bumping it to 762). Without this, the rebuilt server refused to talk to the installed client DLLs (`version mismatch 755/762`).

Patches applied to the server:

1. **`server/file.c` (`file_set_sd` / `file_get_sd`)** and
2. **`server/change.c` (`dir_set_sd` / `dir_get_sd`)** — the directory version was the one that actually mattered for SAI, since it sets security on *folders*.

The fix: when an app writes a security descriptor, **cache the exact bytes** and return them verbatim on the next query instead of reconstructing from mode bits. To survive across *separate* opens (SAI's `SetFileSecurityW` and `GetFileSecurityW` use different handles), the exact SD blob is also persisted to a **macOS extended attribute** (`user.wine.sd`) via `fsetxattr` / `fgetxattr`.

### Result
SAI passes its self-test, `user.wine.sd` appears on both folders, no new errlog entry, and **SAI launches to a full working UI** ("Create a New Canvas" dialog, all menus, tools, color wheel).

### Build recipe (server only)
```
# configure (x86_64 via Rosetta toolchain; server-only, most features disabled)
CC="clang -arch x86_64 -mmacosx-version-min=10.13" \
  ../configure --host=x86_64-apple-darwin --disable-tests --enable-win64 \
  --without-freetype --without-fontconfig ... (many --without-*)
# needs Homebrew bison 3.8 on PATH (system bison 2.3 too old)
# needs a stub programs/winedbg/distversion.h
make -j server/wineserver
# install into Whisky (back up first!):
cp server/wineserver "~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wineserver"
```
Original backed up as `wineserver.orig-backup` (631888 bytes). Revert = copy it back.

**⚠️ If Whisky offers to update Wine, decline it — an update overwrites the patched `wineserver`.**

---

## Problem 2 — SAI freezes 3–5s after launch / on opening a menu ⏳ IN PROGRESS

### Symptom
SAI opens fully, then goes unresponsive within a few seconds — especially when opening the **File** menu or the **New Canvas** dialog. Clean idle (0% CPU on the process snapshot), rest of the Mac fine.

### What it is NOT (ruled out)
- **Not** msync vs esync (freezes identically with both).
- **Not** the ACL/xattr patch (server sample shows it healthy in `main_loop`, not in `getxattr`).
- **Not** a general server-build problem — **Notepad runs perfectly** on the same patched server (menus, typing, everything).
- **Not** the WinTab error alone, and **not** fixed by virtual-desktop mode (`explorer /desktop=`).
- **Not** the window hierarchy — virtual desktop didn't change it.

### Root cause (found via `WINEDEBUG=+server` histogram)
One SAI thread spins **`get_window_children`** (the server side of `EnumWindows`/`EnumChildWindows`) in a berserk tight loop:

```
831,604 get_window_children(  (92% of ALL server calls in 12s — ~70,000/sec)
 15,464 get_window_property(   (checking _SFLWININFO_ / _SFLWINAPR_ — SAI's own window props)
```

Loop body is pure back-to-back `get_window_children( parent=0 )` returning the **same 17 windows** every time. SAI is busy-waiting on a window-set condition that never resolves under Wine, **without pumping messages**. This saturates the single-threaded `wineserver`, starving the real UI thread's winemac event round-trips → frozen UI.

`errlog.txt` also shows on every run:
```
wintab.c(655): Error - WTInfo( WTI_INTERFACE, IFC_SPECVERSION, ... )
```
so SAI's tablet/WinTab init fails too (relevant to Goal 2).

### Fix being tried — server-side throttle (custom `wineserver`, patch #3)
`server/window.c` `DECL_HANDLER(get_window_children)`: detect the *same thread* asking for the *identical* enumeration 64+ times back-to-back, and `usleep(250)` to cap the rate. This de-saturates the server so the UI thread's events flow again. Tightly gated so no normal app is affected.

- **If it unfreezes** → confirmed a starvation livelock, fixed.
- **If not** → the loop waits on something unsatisfiable; next step is a `+relay` trace to see SAI's exact WinAPI calls (winedbg crashes with SIGFPE in this build, so relay is our "debugger").

---

## Key debugging commands

```bash
WINE_BIN="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin"
export WINEPREFIX="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles/8B587661-05A9-4D5F-9101-AD181A74ACA2"
export PATH="$WINE_BIN:$PATH"

# launch
"$WINE_BIN/wineserver" -k; sleep 1; "$WINE_BIN/wine64" "C:\\PaintToolSAI\\sai.exe"

# server request histogram (find busy loops)
WINEDEBUG=+server "$WINE_BIN/wine64" "C:\\PaintToolSAI\\sai.exe" >~/Desktop/s.log 2>&1 &
sleep 12; pkill -f sai.exe
grep -aoE "^[0-9a-f]+: [a-z_0-9]+\(" ~/Desktop/s.log | awk '{print $2}' | sort | uniq -c | sort -rn | head

# native thread sample of frozen process
sample $(pgrep -f sai.exe) 3 -mayDie

# revert to stock wineserver
cp "$WINE_BIN/wineserver.orig-backup" "$WINE_BIN/wineserver"
```

## Status

- **Goal 1 (launch): DONE** — novel ACL set/read-back fix (`file.c` + `change.c` + xattr), protocol matched via msync-cx22.
- **Goal 2 (freeze then pen pressure): IN PROGRESS** — throttle patch under test; WinTab/pressure still to do.
