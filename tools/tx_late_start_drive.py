# JTDX-VU test driver (2026-10-15, late Tx start cutoff): learn the client id from
# JTDX-VU's UDP heartbeat, then at each given offset (seconds into the 15/45 Tx period)
# send TriggerCQ (enables Tx) and HaltTx 40 s later. Pair with tools/fake_tci.py and
# read PTT times from its log (trx:0,true). Run on the bundle, a throwaway -r instance.
# usage: tx_late_start_drive.py <udp port> <offset> [offset...]   e.g. 2399 1.0 3.5 6.0
import socket, struct, sys, time
port = int(sys.argv[1]); offs = [float(x) for x in sys.argv[2:]]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", port)); s.settimeout(60)
data, addr = s.recvfrom(65536)
magic, schema, typ, n = struct.unpack(">IIII", data[:16]); cid = data[16:16+n]
def msg(t, p=b""): return struct.pack(">III", 0xadbccbda, schema, t) + struct.pack(">I", len(cid)) + cid + p
def qba(b): return struct.pack(">I", len(b)) + b
def wait_until_offset(off):          # next time with (t-15) mod 30 == off
    while True:
        t = time.time(); ph = (t - 15) % 30
        d = (off - ph) % 30
        if d < 0.05 or d > 29.95: return
        time.sleep(min(d, 0.02) if d < 0.5 else d - 0.4)
for off in offs:
    wait_until_offset(off)
    s.sendto(msg(51, qba(b"") + b"\x01"), addr); print("%.3f enable at +%.1f" % (time.time(), off), flush=True)
    time.sleep(40)                    # covers the next Tx period
    s.sendto(msg(8, b"\x00"), addr); print("%.3f halt" % time.time(), flush=True)
    time.sleep(3)
