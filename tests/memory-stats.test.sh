#!/usr/bin/env bash
# scripts/memory-stats against fixture /proc and cgroup trees.
source "$(dirname "$0")/lib.sh"
new_tmp
echo "memory-stats"

UID_FIX=1234
export MEMORY_OOMD_UID=$UID_FIX
APP=sys/fs/cgroup/user.slice/user-$UID_FIX.slice/user@$UID_FIX.service/app.slice

make_proc() {  # <root>
  local r=$1
  put "$r/proc/meminfo" "MemTotal:       16000000 kB
MemFree:         2000000 kB
MemAvailable:    6000000 kB
Cached:          3000000 kB
SReclaimable:     500000 kB
Shmem:            400000 kB
AnonPages:       6000000 kB
SwapTotal:      10000000 kB
SwapFree:        2800000 kB"
  put "$r/proc/pressure/memory" "some avg10=3.50 avg60=1.00 avg300=0.50 total=100
full avg10=2.25 avg60=0.80 avg300=0.40 total=90"
}

# Full fixture: system PSI plus the app.slice cgroup.
R=$TMP/full
make_proc "$R"
put "$R/$APP/memory.pressure" "some avg10=12.00 avg60=5.00 avg300=1.00 total=10
full avg10=7.50 avg60=2.00 avg300=0.50 total=5"
out=$(MEMORY_OOMD_ROOT=$R "$SCRIPTS_DIR/memory-stats")
assert_json_valid "full fixture emits valid JSON" "$out"
assert_json "totalBytes from MemTotal" "$out" .totalBytes 16384000000
assert_json "usedBytes is total minus available" "$out" .usedBytes 10240000000
assert_json "swapUsedBytes is SwapTotal-SwapFree" "$out" .swapUsedBytes 7372800000
assert_json "swapUsedPercent is 72%" "$out" .swapUsedPercent 72
assert_json "system some avg10 stays the ring value" "$out" .pressurePercent 3.5
assert_json "system full avg10 is exposed" "$out" .pressureFullPercent 2.25
assert_json "app.slice pressure is available" "$out" .appSlicePressureAvailable true
assert_json "app.slice some avg10" "$out" .appSlicePressureSomeAvg10 12
assert_json "app.slice full avg10" "$out" .appSlicePressureFullAvg10 7.5

# No app.slice cgroup (not under systemd, or another uid).
R=$TMP/noapp
make_proc "$R"
out=$(MEMORY_OOMD_ROOT=$R "$SCRIPTS_DIR/memory-stats")
assert_json_valid "no app.slice still emits valid JSON" "$out"
assert_json "app.slice pressure reported unavailable" "$out" .appSlicePressureAvailable false
assert_json "app.slice pressure defaults to 0" "$out" '[.appSlicePressureSomeAvg10,.appSlicePressureFullAvg10]' '[0,0]'
assert_json "system PSI still read" "$out" .pressureFullPercent 2.25

# No PSI at all and no swap.
R=$TMP/nopsi
put "$R/proc/meminfo" "MemTotal: 1000 kB
MemFree: 500 kB
MemAvailable: 600 kB
SwapTotal: 0 kB
SwapFree: 0 kB"
out=$(MEMORY_OOMD_ROOT=$R "$SCRIPTS_DIR/memory-stats")
assert_json_valid "missing PSI files still emit valid JSON" "$out"
assert_json "no swap gives 0%" "$out" '[.swapTotalBytes,.swapUsedPercent]' '[0,0]'
assert_json "no PSI gives 0 pressure" "$out" '[.pressurePercent,.pressureFullPercent]' '[0,0]'

# Without MEMORY_OOMD_ROOT it reads the real machine.
out=$("$SCRIPTS_DIR/memory-stats")
assert_json_valid "real /proc is valid JSON" "$out"
assert_json "real /proc has a positive total" "$out" '.totalBytes > 0' true

finish
