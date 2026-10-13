#!/bin/bash
# JTDX-VU: three copies on one fake FlexRadio (tools/fake_flex.py, 2-GUI-client limit):
# flexa (Slice A) and flexb (Slice A) become GUI clients, flexc (Slice B) is refused
# and must join flexa's station ("joined GUI client" in its flex_trace.txt).
# Throwaway -r flexa/flexb/flexc profiles, removed afterwards with their shm.
# usage: [BIN=.../jtdx] [GUI_SLICE=1] [HOLD=45] tools/flex_multicopy_test.sh
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
for n in flexa flexb flexc; do [ -e "$HOME/Library/Preferences/JTDX-VU - $n.ini" ] && { echo "$n ini exists"; exit 1; }; done
pgrep -f "fake_flex.py --port 4993" >/dev/null && { echo "fake running"; exit 1; }
rm -f $S/ff_multi.log; (cd $S && ${GUI_SLICE:+FAKE_GUI_SLICE=1} python3 $J/tools/fake_flex.py --port 4993 --log $S/ff_multi.log --wait 1 --forever > $S/ff_multi.out 2>&1 &); sleep 2
ipcs -m | awk '$5=="manoj"{print $2}' | sort > $S/multi_shm_before
for spec in "flexa:A:2299:2298" "flexb:A:2297:2296" "flexc:B:2295:2294"; do IFS=: read n L u1 u2 <<< "$spec"
cat > "$HOME/Library/Preferences/JTDX-VU - $n.ini" <<INI
[Common]
Mode=FT8
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=FlexRadio VITA-49 Slice $L
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:4993
TCIAudio=true
UDPServerPort=$u1
UDP2ServerPort=$u2
AcceptUDPRequests=false
CheckForUpdates=false
INI
("$BIN" -r $n > $S/app_$n.log 2>&1 &); sleep 6; done
sleep ${HOLD:-40}
for n in flexa flexb flexc; do echo "== $n"; grep -h -E "======== start|refused|joined GUI client|no GUI client|start failed|took|slice .*created|using slice|no audio|TCI:" "$HOME/Library/Application Support/JTDX-VU - $n/flex_trace.txt" 2>/dev/null | tail -8 | cut -c1-150; done
echo "== fake"; grep -E "client gui|client bind|slice create|closed|connected|F3000001" $S/ff_multi.log | cut -c1-110; tail -3 $S/ff_multi.out
for n in flexa flexb flexc; do P=$(pgrep -f "MacOS/jtdx -r $n"); [ -n "$P" ] && kill $P; done; sleep 4; pkill -9 -f "MacOS/jtdx -r flex[abc]" 2>/dev/null; for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - flex"); do kill $q; done; pkill -f "[f]ake_flex.py --port 4993"; sleep 1
for m in $(comm -13 $S/multi_shm_before <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m && echo "removed shm $m"; done
for n in flexa flexb flexc; do cp "$HOME/Library/Application Support/JTDX-VU - $n/flex_trace.txt" $S/trace_$n.txt 2>/dev/null; rm -f "$HOME/Library/Preferences/JTDX-VU - $n.ini"; rm -rf "$HOME/Library/Application Support/JTDX-VU - $n"; done; pgrep -lf "flex[abc]|fake_flex" || echo clean
