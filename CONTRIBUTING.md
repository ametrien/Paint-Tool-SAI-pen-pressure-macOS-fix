# Contributing

This is a small project maintained by one person. **Issues are welcome; pull requests are not
accepted.** If you have a fix or an idea, describe it in an issue. That is the most useful way
to help, and the change itself is made here.

Please write issues **in English**. A machine translation is fine, and you are welcome to paste
your original text underneath it.

## Reports that help most

- **Other tablets and Macs.** Only a Wacom Intuos on Apple Silicon is verified so far. Your
  tablet model, how it is connected (USB or Bluetooth), your Mac and chip, your macOS version,
  and whether pressure, hover and the mouse all work: that is worth a lot, even when everything
  works.
- **Bugs.** Press **Copy problem report** on the app's **Setup** tab and paste the result into the
  issue. It collects your Mac and chip, macOS and Wine versions, your tablet and how it is
  connected, whether Wine is loading the pressure bridge, what SAI last received, and the tail
  of the log. That is almost everything anyone would otherwise have to ask you for.
- **Pressure problems.** **Pen → Test pen** shows two bars: what the app sends, and what actually
  arrives inside Wine. Saying which of the two moved tells which half of the bridge to look at.
- **Ideas.** Open an issue saying what you would like and what problem it solves for you.

## Building it yourself

The code is MIT-licensed, so you are free to build, change and run your own copy. You need
**Wine** (Gcenx Staging in `/Applications`), your own copy of SAI2, a tablet, `mingw-w64` for the
DLL, and the Xcode command-line tools for the helper.

```bash
# the Windows-side bridge DLL
cd wintab-src
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode
cd ..

# the whole app, helper included
bash make-app.sh

# the tests (no tablet needed)
bash tests/run-tests.sh
```

Never add SAI itself, its installers or its key files to anything you share. The `.gitignore`
blocks them for a reason.
