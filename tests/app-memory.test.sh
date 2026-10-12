#!/usr/bin/env bash
# scripts/app-memory against a fixture cgroup tree with fake /proc/<pid>/comm.
source "$(dirname "$0")/lib.sh"
new_tmp
echo "app-memory"

UID_FIX=1234
export MEMORY_OOMD_UID=$UID_FIX
export MEMORY_OOMD_MIN_BYTES=104857600   # 100 MiB
R=$TMP/root
APP=$R/sys/fs/cgroup/user.slice/user-$UID_FIX.slice/user@$UID_FIX.service/app.slice
MiB=1048576
GiB=1073741824

# unit <dir under app.slice> <mem> <swap> <max|-> <high|-> <swapmax|-> <some> <full> <pid:comm[:rss]>...
unit() {
  local dir="$APP/$1" mem=$2 swap=$3 max=$4 high=$5 smax=$6 some=$7 full=$8; shift 8
  mkdir -p "$dir"
  put "$dir/memory.current" "$mem"
  put "$dir/memory.swap.current" "$swap"
  put "$dir/memory.max" "$([[ $max == - ]] && echo max || echo "$max")"
  put "$dir/memory.high" "$([[ $high == - ]] && echo max || echo "$high")"
  put "$dir/memory.swap.max" "$([[ $smax == - ]] && echo max || echo "$smax")"
  put "$dir/memory.pressure" "some avg10=$some avg60=0.00 avg300=0.00 total=0
full avg10=$full avg60=0.00 avg300=0.00 total=0"
  : > "$dir/cgroup.procs"
  local spec pid comm rss
  for spec in "$@"; do
    IFS=: read -r pid comm rss <<<"$spec"
    echo "$pid" >> "$dir/cgroup.procs"
    put "$R/proc/$pid/comm" "$comm"
    [[ -n $rss ]] && put "$R/proc/$pid/statm" "1000 $rss 10 1 0 1 0"
  done
}

G='app-graphical.slice'
T='app-Hyprland-xdg\x2dterminal\x2dexec'
OMIT_LIST=$TMP/omit.list
: > "$OMIT_LIST"

# Terminals: capped like the real machine (MemoryHigh 6G, MemoryMax 9G, MemorySwapMax 4G).
unit "$G/$T-aaaa1111.scope" $((3 * GiB)) $((1 * GiB)) $((9 * GiB)) $((6 * GiB)) $((4 * GiB)) 0.00 0.00 \
  101:foot 102:bash 103:claude 104:node:9999
unit "$G/$T-bbbb2222.scope" $((300 * MiB)) $((3 * GiB)) $((9 * GiB)) $((6 * GiB)) $((4 * GiB)) 20.00 15.00 \
  201:foot 202:bash 203:nvim 204:python:5000
unit "$G/$T-cccc3333.scope" $((100 * MiB)) 0 $((9 * GiB)) $((6 * GiB)) $((4 * GiB)) 0.00 0.00 \
  301:foot 302:bash
unit "$G/$T-dddd4444.scope" $((600 * MiB)) $((500 * MiB)) $((9 * GiB)) $((6 * GiB)) $((4 * GiB)) 1.00 0.50 \
  401:foot 402:bash 403:claude
unit "$G/$T-eeee5555.scope" $((200 * MiB)) 0 $((9 * GiB)) $((6 * GiB)) $((4 * GiB)) 0.00 0.00 \
  501:foot 502:someprog:8000 503:other:100 504:sleep:90000
# A browser started through gtk-launch is not protected from oomd.
unit "$G/app-Hyprland-gtk\x2dlaunch-ffff6666.scope" $((2 * GiB)) $((1 * GiB)) - - - 0.00 0.00 \
  601:brave 602:brave 603:chrome_crashpad
unit "$G/app-Hyprland-hypridle-77777777.scope" $((5 * MiB)) 0 - - - 0.00 0.00 701:hypridle
# Browser scopes at depth 1, two of them marked user.oomd_omit.
unit "app-org.chromium.Chromium-1111.scope" $((1 * GiB)) $((100 * MiB)) - - - 0.00 0.00 801:brave 802:brave
unit "app-org.chromium.Chromium-2222.scope" $((200 * MiB)) 0 - - - 0.00 0.00 901:chromium
unit "app-org.chromium.Chromium-3333.scope" $((24 * MiB)) $((10 * MiB)) - - - 0.00 0.00 951:xdg-open 952:nvim
printf '%s\n' "$APP/app-org.chromium.Chromium-1111.scope" "$APP/app-org.chromium.Chromium-2222.scope" \
  "$APP/app-org.chromium.Chromium-3333.scope" > "$OMIT_LIST"
# dbus slices (small one skipped, large one listed) and plain services.
unit 'app-dbus\x2d:1.1\x2dorg.gnome.Nautilus.slice' $((10 * MiB)) 0 - - - 0.00 0.00
unit 'app-dbus\x2d:1.9\x2dorg.gnome.Evince.slice' $((300 * MiB)) 0 - - - 0.00 0.00
unit 'bt-agent.service' $((3 * MiB)) 0 - - - 0.00 0.00
unit 'big\x2dthing.service' $((400 * MiB)) $((50 * MiB)) - - - 0.00 0.00
# A second container slice: depth 2 below something other than app-graphical.
unit 'custom.slice/app-flatpak-org.mozilla.firefox-12345.scope' $((700 * MiB)) 0 - - - 0.00 0.00 1001:firefox 1002:firefox

# A stand-in for getfattr that answers from the omit list, in getfattr's format.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/getfattr" <<STUB
#!/usr/bin/env bash
while [[ \$# -gt 0 && \$1 != -- ]]; do shift; done
shift
for path in "\$@"; do
  if grep -qxF -- "\$path" "$OMIT_LIST"; then
    escaped=\${path//\\\\/\\\\134}
    printf '# file: %s\nuser.oomd_omit="1"\n\n' "\$escaped"
  else
    echo "getfattr: \$path: No such attribute" >&2
  fi
done
STUB
chmod +x "$TMP/bin/getfattr"

run() { PATH="$TMP/bin:$PATH" MEMORY_OOMD_ROOT=$R "$SCRIPTS_DIR/app-memory" "$@"; }

out=$(run --top 50)
assert_json_valid "fixture emits valid JSON" "$out"
assert_json "scan is available and omit info is known" "$out" '[.available,.omitKnown]' '[true,true]'
assert_json "names, in order of RAM plus swap" "$out" '[.apps[].name]' \
  '["terminal (claude)","Brave","terminal (nvim)","Firefox","big-thing","Evince","Chromium","terminal (someprog)","terminal (bash)","hypridle"]'
assert_json "small dbus slices and small services are skipped (appCount)" "$out" .appCount 10
assert_json "\\x2d is unescaped in service names" "$out" '.apps[] | select(.name == "big-thing") | .ramBytes' "$((400 * MiB))"
assert_json "reverse-DNS dbus slice is shortened" "$out" '[.apps[].name | select(. == "Evince")] | length' 1

# Duplicates are summed.
assert_json "two claude terminals are one row" "$out" '.apps[0] | [.name, .unitCount]' '["terminal (claude)",2]'
assert_json "terminal RAM is summed" "$out" '.apps[0].ramBytes' "$((3 * GiB + 600 * MiB))"
assert_json "terminal swap is summed" "$out" '.apps[0].swapBytes' "$((1 * GiB + 500 * MiB))"
assert_json "totalBytes is RAM plus swap" "$out" '.apps[0].totalBytes' "$((3 * GiB + 600 * MiB + 1 * GiB + 500 * MiB))"
assert_json "gtk-launch scope resolves to Brave and joins the chromium scope" "$out" '.apps[1] | [.name, .unitCount, .ramBytes]' "[\"Brave\",2,$((3 * GiB))]"

# Terminal naming prefers real work over shells and helpers.
assert_json "nvim beats python and shells" "$out" '[.apps[] | select(.name == "terminal (nvim)")] | length' 1
assert_json "only a shell inside: terminal (bash)" "$out" '[.apps[] | select(.name == "terminal (bash)")] | length' 1
assert_json "no preferred program: biggest non-helper process wins (sleep ignored)" "$out" '[.apps[] | select(.name == "terminal (someprog)")] | length' 1
assert_json "the terminal emulator never names a scope" "$out" '[.apps[].name | select(test("foot"))] | length' 0

# Browsers: named by process, with a fallback when no browser runs inside.
assert_json "chromium scopes without a browser process fall back to Chromium" "$out" '.apps[] | select(.name == "Chromium") | [.unitCount, .ramBytes]' "[2,$((224 * MiB))]"
assert_json "depth 2 flatpak scope under another slice is found and named" "$out" '.apps[] | select(.name == "Firefox") | .ramBytes' "$((700 * MiB))"

# Caps.
assert_json "capBytes is memory.max" "$out" '.apps[0].capBytes' "$((9 * GiB))"
assert_json "capPercent is the fullest unit, not the sum" "$out" '.apps[0].capPercent | . * 100 | round' "$(( 3 * 1024 * 100 * 100 / (9 * 1024) ))"
assert_json "swapCapPercent uses memory.swap.max" "$out" '.apps[] | select(.name == "terminal (nvim)") | .swapCapPercent' 75
assert_json "highBytes is memory.high" "$out" '.apps[0].highBytes' "$((6 * GiB))"
assert_json "uncapped app has null caps" "$out" '.apps[] | select(.name == "Brave") | [.capBytes, .capPercent, .swapCapBytes, .swapCapPercent]' '[null,null,null,null]'

# oomd_omit.
assert_json "all-omitted app is protected" "$out" '.apps[] | select(.name == "Chromium") | .oomdOmit' true
assert_json "app with one unprotected unit is a candidate" "$out" '.apps[] | select(.name == "Brave") | .oomdOmit' false
assert_json "terminals are candidates" "$out" '.apps[0].oomdOmit' false

# Pressure.
assert_json "highest per-cgroup pressure is reported" "$out" '.maxPressure' '{"name":"terminal (nvim)","fullAvg10":15,"someAvg10":20}'
assert_json "per-app pressure fields" "$out" '.apps[] | select(.name == "terminal (nvim)") | [.pressureSomeAvg10, .pressureFullAvg10]' '[20,15]'

# Top N.
out=$(run --top 3)
assert_json "--top 3 keeps the three biggest" "$out" '[.apps[].name]' '["terminal (claude)","Brave","terminal (nvim)"]'
assert_json "--top does not change appCount" "$out" .appCount 10
out=$(run --top=1)
assert_json "--top=1 form" "$out" '.apps | length' 1

# Without getfattr the scan still works and says omit is unknown.
mkdir -p "$TMP/nobin"
for tool in bash jq date cat; do ln -sf "$(command -v $tool)" "$TMP/nobin/$tool"; done
out=$(PATH="$TMP/nobin" MEMORY_OOMD_ROOT=$R "$SCRIPTS_DIR/app-memory" --top 2)
assert_json_valid "no getfattr: still valid JSON" "$out"
assert_json "no getfattr: omitKnown false, nothing marked omitted" "$out" '[.omitKnown, (.apps | map(.oomdOmit) | any)]' '[false,false]'

# No app.slice at all.
out=$(MEMORY_OOMD_ROOT=$TMP/none "$SCRIPTS_DIR/app-memory")
assert_json "missing app.slice is reported, not an error" "$out" '[.available, .apps]' '[false,[]]'

# The real machine: valid JSON, sorted, each app has a name.
out=$("$SCRIPTS_DIR/app-memory" --top 20)
assert_json_valid "real cgroups: valid JSON" "$out"
assert_json "real cgroups: sorted by RAM plus swap" "$out" '[.apps[].totalBytes] as $t | $t == ($t | sort | reverse)' true
assert_json "real cgroups: every app has a name" "$out" '.apps | all(.name != "" and .name != null)' true

finish
