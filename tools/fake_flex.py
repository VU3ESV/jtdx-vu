#!/usr/bin/env python3
"""JTDX-VU: a fake FlexRadio for the VITA-49 rig type, no radio needed.

Speaks enough of the SmartSDR API (TCP, default 4992) for FlexTransceiver's
start-up - V/H greeting, C<seq>| commands answered R<seq>|0|, slice status
lines, "client gui", "client udpport", "slice create/tune/set", "dax audio
set", "stream create type=dax_rx/dax_tx", "xmit" - and then plays the band
as tools/ft2_tci_sim.py does: Gaussian noise plus a scripted FT2 QSO at the
SNRs asked for, as DAX RX VITA-49 packets (type 3, class 0x534C03E3, 24 kHz
stereo float32 BE, 128 frames = 1052 bytes) to the port the client named.
DAX TX packets (type 1, class 0x534C0123, 128 mono int16 BE) arriving on UDP
4991 are counted and kept as 12 kHz wavs, one per transmission, so ft2dec can
check what JTDX-VU sent.

FAKE_GUI_SLICE=1 hands a new GUI client a slice at 14.100 USB, as the 6600 does.
Several clients may connect at once, each with its own handle; "client gui" is
refused (F3000001) past FAKE_GUI_LIMIT (default 2, the multiFLEX limit of every
FLEX-6000) and a non-GUI client may "client bind" to a GUI client's station.
FAKE_STATION_TX=1 behaves like a real radio with DAX TX: one dax_tx stream per station
(a GUI client and the non-GUI clients bound to it). A second "stream create type=dax_tx"
from the same station is refused, dax_tx streams are reported to every client (as
"sub dax all" asks) with "stream 0x... removed" when they go, and TX packets on a stream
id the radio does not have are dropped, as a real radio ignores them (KK4CDK, 2026-10-18).
FAKE_NO_ECHO=1 answers "slice tune" / "slice set" OK but never reports the
change in the slice status (seen on the FLEX-6600, 2026-10-07).
FAKE_TUNE_DELAY=0.8 delays the status echo of "slice tune", as a real radio
does on a band change (the 2026-10-07 hang needed it).
FAKE_DISCOVERY=1 also sends the radio's discovery packet (VITA-49 header + key=value
text, as the 6600 broadcasts on UDP 4992) once a second, so Settings > Radio > Discover
can be tested without a radio. It goes to 127.0.0.1 unless FAKE_DISCOVERY_TO names
another address (255.255.255.255 = the whole LAN - other Flex clients there would see
"FakeFlex" too); FAKE_DISCOVERY_IP is the address it advertises (default 127.0.0.1).
usage: fake_flex.py --sig DIR --snr -10,-14 [--repeats 2] [--port 4992] [--log fake_flex.txt]
                    [--wait 25] [--noise 0.05] [--txdir DIR] [--freq 14074000]
"""
import argparse, array, math, operator, os, random, socket, struct, sys, threading, time, wave
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tci_player import load_signals, PERIOD

RATE = 24000
FPP = 128
HANDLE = 0x5A4B3C2D
OUI = 0x00001C2D
RX_CLASS, TX_CLASS = 0x534C03E3, 0x534C0123
log = None
lock = threading.Lock()
state = {"clients": {}, "next_handle": HANDLE, "slices": {}, "next_slice": 0, "xmit": 0, "xmit_missed": 0,
         "tx": {"rfpower": 50, "tunepower": 10, "max_power_level": 100, "hwalc_enabled": 0},
         "atu": {"status": "TUNE_BYPASS", "atu_enabled": 1, "memories_enabled": 0, "using_mem": 0}}
# meters: id -> (src, num, name, unit) - what the panel and the S-meter read
METERS = {1: ("TX-", 1, "FWDPWR", "dBm"), 2: ("TX-", 2, "REFPWR", "dBm"), 3: ("TX-", 3, "SWR", "SWR"),
          4: ("SLC", 0, "LEVEL", "dBm"), 5: ("TX-", 4, "ALC", "dBFS"), 6: ("RAD", 1, "PATEMP", "degC"),
          7: ("RAD", 2, "+13.8A", "Volts")}
def tx_line(): return "transmit " + " ".join("%s=%s" % kv for kv in state["tx"].items())
def atu_line(): return "atu " + " ".join("%s=%s" % kv for kv in state["atu"].items())

def logw(s):
    log.write("%.3f %s\n" % (time.time(), s)); log.flush()

SOCK_H = {}                                               # socket -> that client's handle
GUI_LIMIT = int(os.environ.get("FAKE_GUI_LIMIT", "2"))     # multiFLEX: GUI clients per radio, every model
STATION_TX = bool(os.environ.get("FAKE_STATION_TX"))       # one dax_tx stream per station, as a real radio

def status(sock, text, h=None):
    sock.sendall(("S%08X|%s\n" % (h if h is not None else SOCK_H.get(sock, 0), text)).encode())

def broadcast(text, h=0):
    for cl in list(state["clients"].values()):
        if cl.get("frozen"): continue
        try: status(cl["sock"], text, h)
        except OSError: pass

def client_line(h):
    cl = state["clients"][h]
    return ("client 0x%08X connected client_id=%s program=%s station=%s local_ptt=1"
            % (h, cl["client_id"], cl["program"] or "none", cl["station"] or "none"))

def tx_stream_line(h):
    return "stream 0x%08X type=dax_tx client_handle=0x%08X tx=1" % (state["clients"][h]["tx_stream"], h)

def slice_line(n):
    s = state["slices"][n]
    owner = s["owner"]
    mine = sorted(k for k, v in state["slices"].items() if v["owner"] == owner)
    letter = chr(ord('A') + mine.index(n))                # index_letter is numbered per station
    return ("slice %d in_use=1 sample_rate=24000 RF_frequency=%.6f client_handle=0x%08X index_letter=%s rxant=%s "
            "mode=%s wide=0 txant=%s dax=%d tx=%d active=1 ant_list=ANT1,ANT2,RX_A,XVTA mode_list=LSB,USB,DIGU,DIGL,CW "
            "tx_ant_list=ANT1,ANT2,XVTA"
            % (n, s["freq"] / 1e6, owner, letter, s.get("rxant", "ANT1"), s["mode"], s.get("txant", "ANT1"), s["dax"], s["tx"]))

def new_slice(owner, f, mode):
    n = state["next_slice"]; state["next_slice"] += 1
    state["slices"][n] = {"freq": f, "mode": mode, "dax": 0, "tx": 1, "owner": owner}
    return n

# One connection = one client with its own handle. "client gui" is refused with
# F3000001 past GUI_LIMIT (what KK4CDK's 6700 answered a third JTDX-VU); a
# non-GUI client can "client bind client_id=" to a GUI client and then shares
# its station: slices it creates carry that client's handle.
def serve(c, a):
    with lock:
        h = state["next_handle"]; state["next_handle"] += 1
        cl = state["clients"][h] = {"sock": c, "gui": False, "client_id": None, "bound": 0, "program": "", "station": "",
                                    "udpport": 0, "peer": c.getpeername()[0], "rx_stream": 0, "tx_stream": 0,
                                    "frozen": False, "kill": threading.Event()}
        SOCK_H[c] = h
    c.sendall(b"V1.4.0.0\n" + ("H%08X\n" % h).encode())
    logw("client 0x%08X connected" % h)
    buf = b""
    try:
        while True:
            d = c.recv(4096)
            if not d: break
            # FAKE_FREEZE_KEYED=1: the first client to key becomes a dead peer, as when
            # the computer's address changed mid-over (2026-10-21): nothing it sends
            # arrives (its unkey is lost), nothing reaches it, and its close is never
            # seen - the radio holds the session, keyed, until "client disconnect"
            if cl["frozen"]:
                logw("dropped from frozen 0x%08X: %s" % (h, d.decode(errors="replace").strip()[:80])); continue
            buf += d
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.decode(errors="replace").strip()
                if not line.startswith("C"): continue
                seq, _, cmd = line[1:].partition("|")
                body, extra, code = "", [], "0"
                p = cmd.split()
                with lock:
                    owner = cl["bound"] or h                       # whose station our slices belong to
                    if p[0] == "client" and p[1] == "gui":
                        if sum(1 for x in state["clients"].values() if x["gui"]) >= GUI_LIMIT:
                            code = "F3000001"
                        else:
                            cl["gui"] = True; cl["client_id"] = p[2] if len(p) > 2 else "%08x-0000-fake" % h
                            extra.append(client_line(h))
                            if os.environ.get("FAKE_GUI_SLICE"):
                                # like the 6600: a new GUI client is handed a slice at the radio's default
                                extra.append(slice_line(new_slice(h, 14100000, "USB")))
                    elif p[0] == "client" and p[1] == "program":
                        cl["program"] = p[2] if len(p) > 2 else ""
                        if cl["gui"]: extra.append(client_line(h))
                    elif p[0] == "client" and p[1] == "station":
                        cl["station"] = p[2] if len(p) > 2 else ""
                        if cl["gui"]: extra.append(client_line(h))
                    elif p[0] == "client" and p[1] == "bind":
                        want = cmd.partition("client_id=")[2].strip()
                        gui = [k for k, x in state["clients"].items() if x["gui"] and x["client_id"] == want]
                        if gui and not cl["gui"]:
                            cl["bound"] = gui[0]
                            for n, s in state["slices"].items():
                                if s["owner"] == gui[0]: extra.append(slice_line(n))
                        else: code = "50000015"
                    elif p[0] == "client" and p[1] == "udpport": cl["udpport"] = int(p[2])
                    elif p[0] == "sub" and p[1] == "client":
                        for k, x in state["clients"].items():
                            if x["gui"]: extra.append(client_line(k))
                    elif p[0] == "sub" and p[1] == "slice":
                        for n in state["slices"]: extra.append(slice_line(n))
                    elif p[0] == "sub" and p[1] == "tx": extra.append(tx_line())
                    elif p[0] == "sub" and p[1] == "atu": extra.append(atu_line())
                    elif p[0] == "sub" and p[1] == "meter":
                        extra.append("meter " + "#".join("%d.src=%s#%d.num=%d#%d.nam=%s#%d.unit=%s" % (i, m[0], i, m[1], i, m[2], i, m[3]) for i, m in METERS.items()))
                    elif p[0] == "transmit" and p[1] == "set":
                        for kv in p[2:]:
                            k, _, v = kv.partition("=")
                            if k in state["tx"]: state["tx"][k] = int(v)
                        extra.append(tx_line())
                    elif p[0] == "atu":
                        if p[1] == "start":
                            state["atu"]["status"] = "TUNE_IN_PROGRESS"; extra.append(atu_line())
                            def done(c=c):
                                state["atu"]["status"] = "TUNE_SUCCESSFUL"; status(c, atu_line())
                            threading.Timer(1.0, done).start()
                        elif p[1] == "bypass": state["atu"]["status"] = "TUNE_MANUAL_BYPASS"; extra.append(atu_line())
                        elif p[1] == "set":
                            for kv in p[2:]:
                                k, _, v = kv.partition("=")
                                if k in state["atu"]: state["atu"][k] = int(v)
                            extra.append(atu_line())
                    elif p[0] == "mixer":
                        logw("< %s" % cmd); c.sendall(("R%s|500000B7|\n" % seq).encode()); continue   # a 6600 has no front speaker
                    elif p[0] == "info": body = 'model="FLEX-6600",chassis_serial="FAKE",software_ver=3.8.19,atu_present=1'
                    elif p[0] == "slice" and p[1] == "create":
                        f = a.freq
                        for kv in p[2:]:
                            if kv.startswith("freq="): f = int(round(float(kv[5:]) * 1e6))
                        n = new_slice(owner, f, "DIGU")
                        body = str(n); extra.append(slice_line(n))
                    elif p[0] == "slice" and p[1] == "tune":
                        n = int(p[2]); f_new = int(round(float(p[3]) * 1e6))
                        # FAKE_BAND_MODE=1: like a real Flex, a band change brings back that
                        # band's last mode - LSB below 10 MHz, USB above (a fresh radio)
                        if os.environ.get("FAKE_BAND_MODE") and (f_new < 10e6) != (state["slices"][n]["freq"] < 10e6):
                            state["slices"][n]["mode"] = "LSB" if f_new < 10e6 else "USB"
                        state["slices"][n]["freq"] = f_new
                        d = float(os.environ.get("FAKE_TUNE_DELAY", "0"))   # a real radio confirms a band change late
                        if os.environ.get("FAKE_NO_ECHO"): pass              # accept, never report it (what the 6600 seemed to do)
                        elif d > 0:
                            line_ = slice_line(n)
                            threading.Timer(d, lambda l=line_: broadcast(l)).start()
                        else: extra.append(slice_line(n))
                    elif p[0] == "slice" and p[1] in ("set", "s"):
                        n = int(p[2])
                        for kv in p[3:]:
                            k, _, v = kv.partition("=")
                            if k == "mode": state["slices"][n]["mode"] = v.upper()
                            elif k == "tx":
                                state["slices"][n]["tx"] = int(v)
                                if int(v):                                   # one transmitter: the others lose tx
                                    for m_, s_ in state["slices"].items():
                                        if m_ != n and s_["tx"]: s_["tx"] = 0; extra.append(slice_line(m_))
                            elif k in ("rxant", "txant"): state["slices"][n][k] = v
                        if not os.environ.get("FAKE_NO_ECHO"): extra.append(slice_line(n))
                    elif p[0] == "slice" and p[1] == "remove":
                        n = int(p[2]); state["slices"].pop(n, None); extra.append("slice %d in_use=0" % n)
                    elif p[0] == "dax" and p[1] == "audio" and p[2] == "set":
                        which = [int(kv[6:]) for kv in p[4:] if kv.startswith("slice=")]
                        for n in (which or list(state["slices"])):
                            if n in state["slices"]: state["slices"][n]["dax"] = int(p[3])
                    elif p[0] == "stream" and p[1] == "create":
                        if "type=dax_rx" in cmd:
                            cl["rx_stream"] = 0x04000000 | (h & 0xFFFF); body = "0x%08X" % cl["rx_stream"]
                            extra.append("stream 0x%08X type=dax_rx dax_channel=1 client_handle=0x%08X ip=%s port=%d"
                                         % (cl["rx_stream"], h, cl["peer"], cl["udpport"]))
                        elif STATION_TX and any(x["tx_stream"] for k, x in state["clients"].items() if (x["bound"] or k) == owner):
                            code = "50000016"                       # the station has its stream (the code is a guess)
                        else:
                            cl["tx_stream"] = 0x84000000 | (h & 0xFFFF); body = "0x%08X" % cl["tx_stream"]
                            extra.append(tx_stream_line(h))
                    elif p[0] == "sub" and p[1] == "dax":
                        for k, x in state["clients"].items():
                            if x["tx_stream"]: extra.append(tx_stream_line(k))
                    elif p[0] == "stream" and p[1] == "remove":
                        sid = int(p[2], 16)
                        if sid == cl["rx_stream"]: cl["rx_stream"] = 0
                        if sid == cl["tx_stream"]:
                            cl["tx_stream"] = 0
                            if STATION_TX: extra.append("stream 0x%08X removed" % sid)
                    elif p[0] == "client" and p[1] == "disconnect":
                        t = int(p[2], 16) if len(p) > 2 else 0
                        if t in state["clients"] and t != h:
                            state["clients"][t]["kill"].set()
                            try: state["clients"][t]["sock"].shutdown(socket.SHUT_RDWR)
                            except OSError: pass
                            logw("client 0x%08X disconnected by 0x%08X" % (t, h))
                        else: code = "50000016"
                    elif p[0] == "xmit":
                        # FAKE_XMIT_MISS=N: the first N key-ups are never answered and do not
                        # key (the 6600 left one unanswered for over 1 s, 2026-10-21)
                        if int(p[1]) and state["xmit_missed"] < int(os.environ.get("FAKE_XMIT_MISS", "0")):
                            state["xmit_missed"] += 1; logw("< %s  [0x%08X]  (not answered, miss %d)" % (cmd, h, state["xmit_missed"])); continue
                        state["xmit"] = int(p[1]); extra.append("interlock state=%s" % ("TRANSMITTING" if state["xmit"] else "READY"))
                        if state["xmit"]:
                            state["xmit_owner"] = h
                            if os.environ.get("FAKE_FREEZE_KEYED") and not state.get("froze"):
                                state["froze"] = True; cl["frozen"] = True
                                logw("< %s  [0x%08X]" % (cmd, h)); c.sendall(("R%s|0|\n" % seq).encode())
                                logw("client 0x%08X frozen while keyed" % h); continue
                logw("< %s  [0x%08X]" % (cmd, h))
                c.sendall(("R%s|%s|%s\n" % (seq, code, body)).encode())
                for e in extra:
                    if e.startswith(("slice ", "client ", "interlock ")) or (STATION_TX and e.startswith("stream 0x8")): broadcast(e, h)
                    else: status(c, e, h)
    except OSError:
        pass
    if cl["frozen"] and not cl["kill"].wait(120): logw("frozen 0x%08X timed out" % h)
    with lock:
        if state.get("xmit_owner") == h and state["xmit"]:
            state["xmit"] = 0; logw("TX released: 0x%08X gone" % h)
        state["clients"].pop(h, None); SOCK_H.pop(c, None)
        gone = [n for n, s in state["slices"].items() if s["owner"] == h]   # a station closes with its GUI client
        for n in gone: state["slices"].pop(n)
        for x in state["clients"].values():
            if x["bound"] == h: x["bound"] = 0
        if not state["clients"]: state["xmit"] = 0
    for n in gone: broadcast("slice %d in_use=0" % n, h)
    if STATION_TX and cl["tx_stream"]: broadcast("stream 0x%08X removed" % cl["tx_stream"], h)
    if cl["gui"]: broadcast("client 0x%08X disconnected" % h, h)
    logw("client 0x%08X closed" % h)

def tx_listener(a):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 4991))
    cur = None; n = 0; last = 0; idx = 0; sid = 0; dropped = set()
    while True:
        s.settimeout(1.0)
        try:
            d, _ = s.recvfrom(4096)
        except socket.timeout:
            if cur is not None and time.time() - last > 1.0:
                f = os.path.join(a.txdir, "tx%02d.wav" % idx); idx += 1
                w = wave.open(f, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(12000)
                w.writeframes(cur.tobytes()); w.close()
                logw("TX transmission ended: %d packets, %.2f s on stream 0x%08X -> %s" % (n, len(cur) / 12000.0, sid, f))
                cur = None; n = 0
            continue
        if len(d) < 28 or struct.unpack(">I", d[12:16])[0] != TX_CLASS: continue
        sid = struct.unpack(">I", d[4:8])[0]
        if STATION_TX:
            with lock: live = {x["tx_stream"] for x in state["clients"].values() if x["tx_stream"]}
            if sid not in live:
                if sid not in dropped: dropped.add(sid); logw("TX packets on unknown stream 0x%08X dropped" % sid)
                continue
        if cur is None: cur = array.array("h"); n = 0; logw("TX transmission started on stream 0x%08X" % sid)
        samples = struct.unpack(">%dh" % ((len(d) - 28) // 2), d[28:])
        for i in range(0, len(samples) - 1, 2): cur.append(int((samples[i] + samples[i + 1]) / 2))   # 24 -> 12 kHz
        n += 1; last = time.time()

def discovery(a):
    to = os.environ.get("FAKE_DISCOVERY_TO", "127.0.0.1")
    ip = os.environ.get("FAKE_DISCOVERY_IP", "127.0.0.1")
    text = ("discovery_protocol_version=3.1.0.2 model=FLEX-6600 serial=0000-0000-0000-0000 version=4.1.5.39794 "
            f"nickname=FakeFlex callsign=VU2CPL ip={ip} port={a.port} status=Available inuse_ip= inuse_host= "
            "max_licensed_version=v4 radio_license_id=00-00-00-00-00-00 requires_additional_license=0 "
            "fpc_mac= wan_connected=0 licensed_clients=2 available_clients=2 max_panadapters=4 "
            "available_panadapters=4 max_slices=4 available_slices=4").encode()
    text += bytes(-len(text) % 4)
    words = 7 + len(text) // 4
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    count = 0
    while True:
        hdr = struct.pack(">IIIIIII", 0x38520000 | ((count & 0x0f) << 16) | words, 0x00000800, OUI, 0x534CFFFF,
                          int(time.time()), 0, 0)
        try: udp.sendto(hdr + text, (to, 4992))
        except OSError as e: logw(f"discovery send failed: {e}")
        count += 1
        time.sleep(1)

def main():
    global log
    ap = argparse.ArgumentParser()
    ap.add_argument("--sig", default=None); ap.add_argument("--snr", default="-10"); ap.add_argument("--repeats", type=int, default=2)
    ap.add_argument("--port", type=int, default=4992); ap.add_argument("--log", default="fake_flex.txt")
    ap.add_argument("--wait", type=float, default=25.0); ap.add_argument("--noise", type=float, default=0.05)
    ap.add_argument("--txdir", default="."); ap.add_argument("--freq", type=int, default=14074000)
    ap.add_argument("--forever", action="store_true", help="keep streaming noise after the plan")
    a = ap.parse_args()
    log = open(a.log, "a", buffering=1)
    os.makedirs(a.txdir, exist_ok=True)
    sigma = a.noise
    # 24 kHz stream (12 kHz Nyquist): noise RMS sigma per sample is 10*log10(0.5*12000/2500) = 3.8 dB
    # under a full-scale tone in 2500 Hz - not the 6.8 of the 48 kHz TCI sim
    levels = [(sigma * 10 ** ((float(v) - 3.8) / 20), float(v)) for v in filter(None, a.snr.split(","))]
    sigs48 = load_signals(a.sig) if a.sig else {}
    rendered = {}
    for g, _ in levels:
        for k, sig in sigs48.items():
            rendered[(k, g)] = array.array("f", [sig[i] * g for i in range(0, len(sig), 2)])   # 24 kHz mono
    rnd = random.Random(2)
    noise = array.array("f", [rnd.gauss(0.0, sigma) for _ in range(RATE * 12)])
    NB = len(noise) - FPP - 1
    t = math.ceil((time.time() + a.wait) / 15) * 15
    plan = []
    for g, snr in (levels if sigs48 else []):        # no --sig: noise only, nothing to schedule
        for r in range(a.repeats):
            log.write(f"{t:.3f} {time.strftime('%Y%m%d_%H%M%S', time.gmtime(t))} level {g:.6f} rep {r} snr {snr:.1f}\n")
            for k in range(6): plan.append((t + k * PERIOD, k + 1, g))
            t += 8 * PERIOD
    t_end = t + 5
    if plan: print(f"{len(plan)} periods, first at {time.strftime('%H:%M:%S', time.gmtime(plan[0][0]))} UTC, ends {time.strftime('%H:%M:%S', time.gmtime(t_end))}", flush=True)

    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("0.0.0.0", a.port)); srv.listen(5)
    def acceptor():
        while True:
            c, _ = srv.accept(); threading.Thread(target=serve, args=(c, a), daemon=True).start()
    threading.Thread(target=acceptor, daemon=True).start()
    threading.Thread(target=tx_listener, args=(a,), daemon=True).start()
    if os.environ.get("FAKE_DISCOVERY"): threading.Thread(target=discovery, args=(a,), daemon=True).start()

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dt = FPP / RATE
    t0 = time.time(); n = 0; sent = 0; count = 0
    while a.forever or time.time() < t_end:
        bt = t0 + n * dt
        delay = bt - time.time()
        if delay > 0: time.sleep(delay)
        with lock: targets = [(x["rx_stream"], x["udpport"], x["peer"]) for x in state["clients"].values() if x["rx_stream"] and x["udpport"] and not x["frozen"]]
        # FAKE_NO_AUDIO: control works, no VITA-49 ever arrives - a firewall or a
        # VPN dropping the radio's UDP (KK4CDK, VU2OY, 2026-10-10)
        if targets and not os.environ.get("FAKE_NO_AUDIO"):
            off = rnd.randrange(0, NB)
            block = noise[off:off + FPP]
            for (ts, k, g) in plan:
                if ts + PERIOD < bt or ts > bt + dt: continue
                sig = rendered[(k, g)]
                so = int(round((bt - ts) * RATE))
                lo, hi = max(0, -so), min(FPP, len(sig) - so)
                if hi <= lo: continue
                mixed = array.array("f", block)
                mixed[lo:hi] = array.array("f", map(operator.add, mixed[lo:hi], sig[so + lo:so + hi]))
                block = mixed
            # stereo L == R, big-endian floats
            st = array.array("f", bytes(8 * FPP)); st[0::2] = block; st[1::2] = block
            if sys.byteorder == "little": st.byteswap()
            for sid, port, peer in targets:
                hdr = struct.pack(">IIIIII", 0x38500107 | ((count & 0x0f) << 16), sid, OUI, RX_CLASS, int(bt), 0) + struct.pack(">I", 0)
                udp.sendto(hdr + st.tobytes(), (peer, port))
            count += 1; sent += len(targets)
            if n % 19 == 0:                                       # meters, about 10 a second
                with lock: keyed = state["xmit"]; rf = state["tx"]["rfpower"]
                watts = 100.0 * rf / 100.0 if keyed else 0.0
                fwd_dbm = 10 * math.log10(watts * 1000) if watts > 0 else -150
                vals = {1: fwd_dbm, 2: (fwd_dbm - 20 if watts > 0 else -150), 3: 1.2, 4: -85.0, 5: -10.0, 6: 35.5, 7: 13.8}
                div = {"dBm": 128, "SWR": 128, "dBFS": 128, "degC": 64, "Volts": 256}
                pl = b"".join(struct.pack(">hh", i, max(-32768, min(32767, int(round(v * div[METERS[i][3]]))))) for i, v in vals.items())
                mh = struct.pack(">IIIII", 0x38500000 | ((7 + len(pl) // 4) & 0xffff), 0x00000700, OUI, 0x534C8002, 0) + struct.pack(">II", 0, 0)
                for sid, port, peer in targets: udp.sendto(mh + pl, (peer, port))
        n += 1
    print(f"done: {sent} RX packets", flush=True)

if __name__ == "__main__":
    main()
