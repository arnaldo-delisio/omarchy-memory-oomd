#!/usr/bin/env bash
# scripts/oomd-config: defaults versus parsed thresholds.
source "$(dirname "$0")/lib.sh"
new_tmp
echo "oomd-config"

run() { MEMORY_OOMD_ROOT=$1 MEMORY_OOMD_HOME=$TMP/home "$SCRIPTS_DIR/oomd-config"; }

# No config files at all: built-in defaults.
R=$TMP/empty; mkdir -p "$R"
out=$(run "$R")
assert_json_valid "absent config emits valid JSON" "$out"
assert_json "defaults are swap 90, pressure 50, 20s" "$out" '[.swapLimitPercent,.pressureLimitPercent,.pressureDurationSec]' '[90,50,20]'
assert_json "defaults are labelled as such" "$out" '.sources' '{"swap":"default","pressure":"default","duration":"default"}'

# The Omarchy layout: only pressure and duration are set, swap stays default.
R=$TMP/omarchy
put "$R/etc/systemd/oomd.conf" "# commented out
#[OOM]
#SwapUsedLimit=90%"
put "$R/etc/systemd/oomd.conf.d/10-omarchy.conf" "# comment
[OOM]
DefaultMemoryPressureDurationSec=20s
DefaultMemoryPressureLimit=60%"
out=$(run "$R")
assert_json "drop-in values are parsed" "$out" '[.swapLimitPercent,.pressureLimitPercent,.pressureDurationSec]' '[90,60,20]'
assert_json "sources name the drop-in, relative to the root" "$out" '.sources' '{"swap":"default","pressure":"/etc/systemd/oomd.conf.d/10-omarchy.conf","duration":"/etc/systemd/oomd.conf.d/10-omarchy.conf"}'

# Main file, then drop-ins in name order; /etc replaces /usr/lib for the same name.
R=$TMP/layers
put "$R/etc/systemd/oomd.conf" "[OOM]
SwapUsedLimit=80%
DefaultMemoryPressureLimit=40%
DefaultMemoryPressureDurationSec=15"
put "$R/usr/lib/systemd/oomd.conf.d/20-vendor.conf" "[OOM]
SwapUsedLimit=70%"
put "$R/etc/systemd/oomd.conf.d/20-vendor.conf" "[OOM]
SwapUsedLimit=85%"
put "$R/etc/systemd/oomd.conf.d/30-late.conf" "[OOM]
DefaultMemoryPressureDurationSec=1min 30s"
put "$R/etc/systemd/oomd.conf.d/05-early.conf" "[OOM]
DefaultMemoryPressureLimit=10%"
out=$(run "$R")
assert_json "swap: /etc drop-in beats /usr/lib of the same name and the main file" "$out" .swapLimitPercent 85
assert_json "pressure: drop-in 05-early is applied after the main file" "$out" .pressureLimitPercent 10
assert_json "duration: '1min 30s' is 90 seconds" "$out" .pressureDurationSec 90

# Other units and notations, invalid values, wrong section.
R=$TMP/notation
put "$R/etc/systemd/oomd.conf" "[OOM]
SwapUsedLimit=500‰
DefaultMemoryPressureLimit=37.5%
DefaultMemoryPressureDurationSec=2min"
out=$(run "$R")
assert_json "permille is converted" "$out" .swapLimitPercent 50
assert_json "fractional percent is kept" "$out" .pressureLimitPercent 37.5
assert_json "minutes are converted" "$out" .pressureDurationSec 120

R=$TMP/invalid
put "$R/etc/systemd/oomd.conf" "[OOM]
SwapUsedLimit=lots
DefaultMemoryPressureLimit=50
DefaultMemoryPressureDurationSec=soon
[Other]
SwapUsedLimit=10%"
out=$(run "$R")
assert_json "invalid and out-of-section values leave the defaults" "$out" '[.swapLimitPercent,.pressureLimitPercent,.pressureDurationSec]' '[90,50,20]'

# app.slice drop-in overrides the global pressure limit.
R=$TMP/slice
put "$R/etc/systemd/oomd.conf.d/10-omarchy.conf" "[OOM]
DefaultMemoryPressureLimit=50%
DefaultMemoryPressureDurationSec=20s"
put "$R/usr/lib/systemd/user/app.slice.d/10-oomd.conf" "[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMSwap=kill"
put "$TMP/home/.config/systemd/user/app.slice.d/50-mine.conf" "[Slice]
ManagedOOMMemoryPressureLimit=65%"
out=$(run "$R")
assert_json "app.slice ManagedOOMMemoryPressureLimit overrides the default" "$out" '[.pressureLimitPercent,.pressureDurationSec]' '[65,20]'
assert_json "override source is the user drop-in" "$out" '.sources.pressure' "\"$TMP/home/.config/systemd/user/app.slice.d/50-mine.conf\""

# The real machine, whatever it has, must give a sane answer.
out=$("$SCRIPTS_DIR/oomd-config")
assert_json_valid "real config is valid JSON" "$out"
assert_json "real thresholds are positive" "$out" '[.swapLimitPercent,.pressureLimitPercent,.pressureDurationSec] | all(. > 0)' true

finish
