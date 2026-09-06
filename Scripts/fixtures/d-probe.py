import os, termios, time
fd = 0
r = termios.tcgetattr(fd)
r[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
termios.tcsetattr(fd, termios.TCSANOW, r)
os.write(1, b"\x1b[?2004h")
time.sleep(20)
