#!/bin/sh
# adsp-ulog-capture: read the PPM (ADSP) charger ULog from the AP, live.
#
# The kernel ships `pmic_pdcharger_ulog.ko` (no dependencies, no
# MODULE_DEVICE_TABLE — "loaded manually only", so it is *never* loaded on
# its own). It binds the rpmsg channel `PMIC_LOGS_ADSP_APPS`, polls
# GET_CHG_ULOG_REQ (opcode 0x18) once a second, and emits every ULog line
# through the tracepoint `pmic_pdcharger_ulog:pmic_pdcharger_ulog_msg`.
#
# This script loads it as early as possible, enables the tracepoint, and
# dumps the trace plus the kernel-boot markers to LOG so the PPM's own view
# of `charger_detection_inital_detection` / `ncp_stby_db` / `sm_state_loop`
# can be lined up against the `charger_pd` PDR.
#
# The dump loop runs in the *background* so the service (which is ordered
# before sysinit.target) returns immediately and does not delay boot.
#
# Ring-buffer caveat: the ADSP-side ULog is a ~8 KB drain buffer (each GET
# returns only the lines logged since the previous GET). Lines logged before
# the first GET (ADSP boot -> channel open, ~10.98 s -> ~11.03 s on this
# device) may be lost; everything from the first GET on is captured. The
# `charger_detection_inital_detection` event (~PDR + 55 ms) lands inside the
# first poll window.

LOG=${1:-/var/tmp/adsp-ulog-capture.log}
T=/sys/kernel/tracing
CAPTURE_S=${CAPTURE_S:-40}

# tracefs (already mounted by the OS; in an initramfs mount it here)
grep -qs " /sys/kernel/tracing tracefs" /proc/mounts || mount -t tracefs tracefs "$T" 2>/dev/null

# the reader: no deps; the rpmsg driver binds automatically when the ADSP
# announces PMIC_LOGS_ADSP_APPS at its boot (~10.98 s)
modprobe pmic_pdcharger_ulog || exit 1

E=$T/events/pmic_pdcharger_ulog/pmic_pdcharger_ulog_msg
if [ ! -d "$E" ]; then
	echo "adsp-ulog-capture: tracepoint $E missing" >&2
	exit 1
fi
echo 1 > "$E/enable"

# glink transport view of the same channel (for request/response timing)
G=$T/events/qcom_glink/qcom_glink_cmd_tx_data
if [ -d "$G" ]; then
	echo 1 > "$G/enable"
	echo 'channel ~ "PMIC_LOGS*"' > "$G/filter" 2>/dev/null
fi

echo > "$T/trace"
echo 65536 > "$T/buffer_size_kb" 2>/dev/null || true
echo 1 > "$T/tracing_on"

# background dump loop: CAPTURE_S seconds, then stop tracing
(
	end=$(( $(cut -d. -f1 /proc/uptime) + CAPTURE_S ))
	while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do sleep 1; done
	echo 0 > "$T/tracing_on"
	{
		echo "=== adsp-ulog-capture: kernel uptime $(cut -d. -f1 /proc/uptime)s, capture ${CAPTURE_S}s ==="
		echo "=== kmsg markers ==="
		dmesg 2>/dev/null | grep -E "powering up adsp|remote processor adsp is now up|PDR: Indication|PMIC_LOGS|pdcharger" || true
		echo "=== trace (tracepoint + glink) ==="
		grep -v "^#" "$T/trace"
	} > "$LOG"
) &

# leave the module loaded (harmless: 1 poll/s; unloading it destroys the
# rpmsg channel and it does not come back until an ADSP restart)
exit 0
