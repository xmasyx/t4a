import os, select, termios, time
fd = 0
r = termios.tcgetattr(fd)
r[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
r[6][termios.VMIN] = 1
r[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, r)
os.write(1, b"\x1b[?2004h")
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    readable, _, _ = select.select([fd], [], [], 0.2)
    if readable:
        os.read(fd, 65536)
