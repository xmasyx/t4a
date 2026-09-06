#!/usr/bin/python3
"""Capture one bracketed paste from the real T4A pty, byte for byte."""

import os
import select
import sys
import termios
import time

START = b"\x1b[200~"
END = b"\x1b[201~"


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in ("paste", "submit"):
        print("usage: paste-capture.py OUTPUT paste|submit", file=sys.stderr)
        return 2
    output, mode = sys.argv[1:]
    fd = sys.stdin.fileno()
    previous = termios.tcgetattr(fd)
    raw = termios.tcgetattr(fd)
    raw[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
    # ICRNL translates the CR that a terminal Return really is into LF before
    # this reader sees it; measured 31/08 21:05 (frame arrived right, then 0x0a
    # where PasteFraming.submit writes 0x0d). Byte-true capture needs it off.
    raw[0] &= ~termios.ICRNL
    raw[6][termios.VMIN] = 1
    raw[6][termios.VTIME] = 0
    data = bytearray()
    try:
        termios.tcsetattr(fd, termios.TCSANOW, raw)
        os.write(sys.stdout.fileno(), b"\x1b[?2004h")
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.2)
            if not readable:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data.extend(chunk)
            end = data.find(END)
            if end < 0:
                continue
            after = end + len(END)
            if mode == "paste" or b"\r" in data[after:]:
                break
    finally:
        os.write(sys.stdout.fileno(), b"\x1b[?2004l")
        termios.tcsetattr(fd, termios.TCSANOW, previous)
    with open(output, "wb") as handle:
        handle.write(data)
    return 0 if data.startswith(START) and END in data else 1


if __name__ == "__main__":
    raise SystemExit(main())
