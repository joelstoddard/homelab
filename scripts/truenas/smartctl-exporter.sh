#!/bin/sh
# TrueNAS CORE Post Init script: runs smartctl_exporter as root (smartctl
# needs it) under daemon(8), restarted if it dies. See
# docs/design/host-monitoring.md, "SMART on Voyager".
set -eu

EXPORTER=/mnt/Voyager/scripts/smartctl_exporter

[ -x "$EXPORTER" ] || { echo "smartctl-exporter: $EXPORTER missing" >&2; exit 1; }

pgrep -x smartctl_exporter >/dev/null && exit 0

exec daemon -f -r -R 10 -P /var/run/smartctl_exporter.supervisor.pid \
	-t smartctl_exporter -o /var/log/smartctl_exporter.log \
	"$EXPORTER" \
	--smartctl.path=/usr/local/sbin/smartctl \
	--web.listen-address=:9633
