#!/usr/bin/env python3
# Small always-on-top "终端" button for the minimal Kasm desktop.
# Why: the image has no panel, no menu and no window decorations, and the
# Ctrl+Alt+T shortcut depends on xbindkeys + the VNC client forwarding the
# keys, which has already failed twice. A clickable button needs none of
# that: tap it and a terminal opens. It is tiny, sits in the top-right
# corner, and stays above Chrome and above the terminal.
# Stdlib only (tkinter). Started in the background by terminal_launcher.sh
# after Chrome is up. Click = open xfce4-terminal (same size/position as
# the auto-launched one). Right-click = hide the button for 60 seconds,
# in case it ever covers something you need to tap.
import subprocess
import sys
import time
import tkinter as tk


def open_terminal():
    try:
        subprocess.Popen(
            ["xfce4-terminal", "--geometry=100x28+40+40"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        subprocess.Popen(
            ["xterm", "-geometry", "100x28+40+40"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def main():
    root = None
    last_err = None
    for _ in range(30):
        try:
            root = tk.Tk()
            break
        except Exception as e:  # X not ready yet; retry
            last_err = e
            time.sleep(2)
    if root is None:
        print(f"term-button: could not open Tk window: {last_err}", file=sys.stderr)
        return 1

    root.title("term-button")
    # No title bar / decorations: without a working window manager the
    # button must draw itself, and it must stay above everything else.
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    try:
        root.attributes("-alpha", 0.92)
    except Exception:
        pass
    w, h = 92, 46
    try:
        x = root.winfo_screenwidth() - w - 12
    except Exception:
        x = 100
    root.geometry(f"{w}x{h}+{x}+12")

    def hide_for_a_while(event=None):
        root.withdraw()
        root.after(60000, root.deiconify)

    btn = tk.Button(
        root,
        text="终端",
        font=("sans", 15, "bold"),
        bg="#2d2d2d",
        fg="white",
        activebackground="#4a4a4a",
        activeforeground="white",
        relief="raised",
        borderwidth=2,
        command=open_terminal,
    )
    btn.pack(fill="both", expand=True)
    btn.bind("<Button-3>", hide_for_a_while)
    # Re-assert on top every few seconds: Chrome/terminal can cover it
    # after a resize or a raise.
    def keep_on_top():
        try:
            root.lift()
            root.attributes("-topmost", True)
        except Exception:
            pass
        root.after(3000, keep_on_top)

    root.after(3000, keep_on_top)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
