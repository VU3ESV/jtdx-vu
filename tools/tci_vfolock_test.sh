#!/bin/bash
# JTDX-VU: a TCI server that refuses frequency changes (AetherSDR with the
# IC-705's dial lock on, 2026-10-19). With Split = Fake It every over moves the
# vfo, the server answers with the frequency it keeps, and JTDX-VU used to call
# that "TCI failed set rxfreq" and drop the connection 0.2 s into each over.
# Runs a throwaway "-r vfolocktest" copy on tools/fake_tci.py with
# FAKE_VFO_LOCK=1, calls CQ for HOLD s (default 50) and prints the connects and
# the overs. Tx at 2500 Hz so Fake It moves the dial each over.
# Broken: a new connect every over; fixed: 1 connect, every over sent.
# usage: [BIN=.../jtdx] [HOLD=50] tools/tci_vfolock_test.sh
set -u
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; mkdir -p "$S"; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
INI="$HOME/Library/Preferences/JTDX-VU - vfolocktest.ini"
APP="$HOME/Library/Application Support/JTDX-VU - vfolocktest"
PORT=50094
[ -e "$INI" ] && { echo "vfolocktest ini exists - stopped"; exit 1; }
FAKE_VFO_LOCK=1 python3 "$J/tools/fake_tci.py" "$S/fake.log" $PORT > /dev/null 2>&1 &
SIM=$!
sleep 2
cat > "$INI" <<INI
[Common]
Mode=FT8
RxFreq=2500
TxFreq=2500
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=TCI Client RX1
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:$PORT
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2269
UDP2ServerPort=2268
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
SplitMode=@Variant(\\0\\0\\0\\x7f\\0\\0\\0\\x1eTransceiverFactory::SplitMode\\0\\0\\0\\0\\x13split_mode_emulate\\0)
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r vfolocktest > "$S/app.log" 2>&1 &
P=$!
sleep 15
python3 "$J/tools/udp_ctl.py" 2269 cq sleep=${HOLD:-50} halt > "$S/udp.txt" 2>&1
sleep 3
kill $P; sleep 3; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - vfolocktest"); do kill $q; done
kill $SIM 2>/dev/null
sleep 1
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
rm -f "$INI"; rm -rf "$APP"
grep -E " connected$|TX over" "$S/fake.log"
echo "vfo refusals: $(grep -c '< vfo:0,0,' "$S/fake.log")"
echo "logs in $S"
