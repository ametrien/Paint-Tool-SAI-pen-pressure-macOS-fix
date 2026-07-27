---
title: SAI Pen Pressure for macOS
---

PaintTool SAI Ver.2 runs on macOS under Wine, but arrives with **no pen pressure** — every
stroke comes out the same width. This project supplies the missing piece: a small WinTab
bridge plus a native macOS helper that reads your tablet and streams it to SAI.

[**Download the latest release →**](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)

## Start here

- [**Install**](install.md) — from nothing to drawing, about 15 minutes
- [**Troubleshooting**](troubleshooting.md) — no pressure, can't save, two cursors, permissions
- [**How it works**](how-it-works.md) — what actually happens, and where your files go

## What you need

| | |
|---|---|
| A drawing tablet with its macOS driver installed | Wacom, Huion, XP-Pen … |
| [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds/releases) | the app can install it for you |
| [PaintTool SAI Ver.2](https://www.systemax.jp/en/sai/devdept.html) | free technical preview |
| A SAI licence | only to **save** — you can draw and test pressure without one |

## What this project is not

It does not include SAI, and it cannot supply, generate or activate a licence. PaintTool SAI is
commercial software by SYSTEMAX; this project is an unaffiliated compatibility fix and only
copies a certificate **you already own** into the folder SAI reads. The MIT licence here covers
the bridge code, nothing else.
