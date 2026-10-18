#!/bin/bash
# JTDX-VU: TCI audio after an automatic reconnect (2026-10-18, AetherSDR dropped
# the client mid-over; every later over had PTT keyed but all-zero TX audio until
# a restart). Runs a throwaway "-r tcitxtest" copy on tools/fake_tci.py, calls CQ
# over UDP, drops the client 3 s into the first over (<log>.drop), lets it
# reconnect, calls CQ again and prints every over's TX audio peak.
# Broken (v0.7.5): peak=0.0000 on every over after the reconnect; fixed: 0.9990.
# usage: [BIN=.../jtdx] [HOLD=50] tools/tci_reconnect_tx_test.sh
set -u
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; mkdir -p "$S"; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
INI="$HOME/Library/Preferences/JTDX-VU - tcitxtest.ini"
APP="$HOME/Library/Application Support/JTDX-VU - tcitxtest"
PORT=50095
[ -e "$INI" ] && { echo "tcitxtest ini exists - stopped"; exit 1; }
python3 "$J/tools/fake_tci.py" "$S/fake.log" $PORT > /dev/null 2>&1 &
SIM=$!
sleep 2
cat > "$INI" <<INI
[Common]
Mode=FT8
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=TCI Client RX1
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:$PORT
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2279
UDP2ServerPort=2278
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r tcitxtest > "$S/app.log" 2>&1 &
P=$!
sleep 15
python3 "$J/tools/udp_ctl.py" 2279 cq > "$S/udp.txt" 2>&1
# drop the client 3 s into the first over
for i in $(seq 60); do grep -q "< trx:0,true" "$S/fake.log" && break; sleep 1; done
sleep 3; touch "$S/fake.log.drop"
# the failure halts Tx; once reconnected, call CQ again (as Manoj did by hand)
for i in $(seq 30); do [ $(grep -c " connected$" "$S/fake.log") -ge 2 ] && break; sleep 1; done
sleep 3
python3 "$J/tools/udp_ctl.py" 2279 cq sleep=${HOLD:-50} halt >> "$S/udp.txt" 2>&1
sleep 3
kill $P; sleep 3; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - tcitxtest"); do kill $q; done
kill $SIM 2>/dev/null
sleep 1
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
rm -f "$INI"; rm -rf "$APP"
grep -E " connected$|dropping client|TX over" "$S/fake.log"
echo "logs in $S"
