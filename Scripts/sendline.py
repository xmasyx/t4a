#!/usr/bin/env python3
"""Writes one line into T4A's test channel without blocking.

A plain `printf > fifo` waits forever when nothing is reading, which turns a
dead app into a hung test instead of a failed one. This gives up after five
seconds and says which of the two happened.
"""
import os
import sys
import time

path, line = sys.argv[1], sys.argv[2] + "\n"
deadline = time.time() + 5
while True:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, line.encode())
        os.close(fd)
        break
    except OSError:
        if time.time() > deadline:
            sys.stderr.write("T4A is not reading the test channel\n")
            sys.exit(1)
        time.sleep(0.1)
