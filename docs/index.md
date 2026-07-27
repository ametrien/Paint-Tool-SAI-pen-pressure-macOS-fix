---
title: SAI Pen Pressure for macOS
---

PaintTool SAI Ver.2 runs on macOS under Wine. It launches, it draws, it looks right — and every
stroke comes out the same width, because the pressure never arrives.

The reason is narrower than it sounds. SAI asks Windows for pen data through **WinTab**, an API
from 1991 that expects a tablet driver to be present. Under Wine there is no such driver: your
Wacom talks to macOS, macOS knows the pressure perfectly well, and nothing carries it across the
boundary. SAI isn't broken and neither is your tablet. There is simply a missing translator.

This project is that translator.

[**Download the latest release →**](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)

## Where to go

- [**Install**](install.md) — from nothing to drawing. Roughly fifteen minutes, most of it waiting on downloads.
- [**Troubleshooting**](troubleshooting.md) — organised by *how to tell which problem you have*, because the symptoms overlap badly.
- [**How it works**](how-it-works.md) — the architecture, and the file-layout question that trips up nearly everyone.
- [**Engineering notes**](notes.md) — decisions, mistakes, and the reasoning behind both.

## What you need

| | |
|---|---|
| A tablet, with its macOS driver installed | Wacom, Huion, XP-Pen — anything macOS itself recognises |
| [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds/releases) | the app will install it for you, with a progress bar |
| [PaintTool SAI Ver.2](https://www.systemax.jp/en/sai/devdept.html) | the free technical preview |
| A SAI licence | **only to save.** You can draw, and test pressure, without one |

That last row matters more than it looks. You can verify this whole project works before
spending anything.

## What this is not

It does not include SAI, and it cannot supply, generate or activate a licence. PaintTool SAI is
commercial software by SYSTEMAX; this project has no affiliation with them and does exactly one
thing with licences — copies a certificate **you already own** into the folder SAI reads, because
that folder is not where anyone would guess.

The MIT licence in this repository covers the bridge code. Nothing else.

## Why not just run a virtual machine?

That is what most people have done, and it works. It is also heavy for what you get.

| | Virtual machine | This project |
|---|---|---|
| Windows licence | required | none |
| Disk | tens of gigabytes | ~300 MB (Wine) + SAI itself, a few MB |
| Memory | a whole second OS, running alongside macOS | a translation layer, only while SAI is open |
| Your tablet | forwarded over virtual USB into the guest | stays on macOS, using the driver you already installed |
| Pen pressure | depends on USB passthrough and the guest's tablet driver | read natively on macOS and handed to SAI |
| Starting SAI | boot the VM, wait, then launch SAI | double-click |

The tablet row is the one that decides it. In a VM your pen has to survive being forwarded
through virtual USB and picked up again by a Windows driver inside the guest — which is precisely
where pressure tends to be lost, or arrive late enough to feel wrong. Latency you can tolerate in
a spreadsheet is intolerable in a brush stroke.

Wine takes the opposite approach: there is no guest operating system. SAI's Windows calls are
translated as they happen, and the pen never leaves macOS — it is read by the driver you already
have, and delivered straight into SAI. Nothing is emulated, so nothing is slowed down.

The honest trade-off: a VM runs *real Windows*, so if something misbehaves it is SAI's fault, not
the translation layer's. Here, some rough edges belong to Wine — the
[known issues](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues) are
explicit about which. In exchange you get no Windows licence, a fraction of the disk and memory,
and a pen that behaves like a pen.

## An honest word about scope

This is a compatibility shim between two systems that were never meant to meet, sitting on top of
Wine, which is itself an enormous act of reverse engineering. Some problems here are ours and get
fixed. Some belong to Wine's macOS driver, or to SAI, and can only be worked around.

The [known issues](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues) say
which is which, including the ones still unsolved. That seemed more useful than pretending.
