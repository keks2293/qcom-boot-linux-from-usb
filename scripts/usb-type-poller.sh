#!/bin/sh
# usb-type-poller: sample the USB classification state and log every change
# with kernel uptime (same clock base as `journalctl -b -k -o short-monotonic`),
# so T(Unknown -> SDP) can be lined up against the charger_pd PDR / xhci lines.
# Only *stable* fields trigger a log line; V/uA wobble and are carried along.
set -u

OUT=/var/tmp/usb-type-poller.log
[ -s "$OUT" ] && mv -f "$OUT" "$OUT.prev"

PS=/sys/class/power_supply
B=$PS/qcom-battmgr-usb
S=$PS/ucsi-source-psy-pmic_glink.ucsi.01
TC=/sys/class/typec/port0

V=
get() {
	V='?'
	[ -r "$1" ] || return 0
	IFS= read -r V < "$1" || V='?'
}

build() {
	get "$B/usb_type";               b_type=$V
	get "$B/online";                 b_on=$V
	get "$B/voltage_now";            b_v=$V
	get "$B/current_now";            b_i=$V
	get "$S/usb_type";               s_type=$V
	get "$S/online";                 s_on=$V
	get "$TC/power_role";            p_role=$V
	get "$TC/data_role";             d_role=$V
	get "$TC/power_operation_mode";  opm=$V
	if [ -e "$TC/port0-partner" ]; then partner=yes; else partner=no; fi
	roles=
	for f in /sys/class/usb_role/*/role; do
		[ -e "$f" ] || continue
		get "$f"; roles="$roles$V,"
	done
	[ -n "$roles" ] || roles='-,'
	key="usb_type=$b_type online=$b_on src_type=$s_type src_online=$s_on power=$p_role data=$d_role opmode=$opm partner=$partner role=$roles usbs=$usbs"
	cur="[$b_type] online=$b_on V=$b_v uA=$b_i | src=[$s_type] on=$s_on | power=$p_role data=$d_role opmode=$opm partner=$partner role=$roles usbs=$usbs"
}

usbs=-
n=0
read -r up _ < /proc/uptime
printf '[%s] start pid=%s\n' "$up" "$$" >> "$OUT"
prev=
while :; do
	n=$((n + 1))
	if [ $((n % 40)) -eq 0 ]; then
		list=
		for d in /sys/block/sd*; do
			[ -e "$d" ] || continue
			case "$(readlink -f "$d" 2>/dev/null)" in
			*usb*) list="$list${d##*/}," ;;
			esac
		done
		if [ -n "$list" ]; then usbs=$list; else usbs=-; fi
	fi
	build
	read -r up _ < /proc/uptime
	if [ "$key" != "$prev" ]; then
		printf '[%s] CHANGE %s\n' "$up" "$cur" >> "$OUT"
		prev=$key
		n=0
	elif [ $((n % 200)) -eq 0 ]; then
		printf '[%s] steady %s\n' "$up" "$cur" >> "$OUT"
	fi
	sleep 0.05
done
