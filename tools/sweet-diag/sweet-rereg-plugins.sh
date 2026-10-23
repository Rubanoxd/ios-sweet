#!/bin/sh
# Re-registers every /Applications app with extensions (uicache -p), so LaunchServices gets their plug-ins.
# installd can block lsd's enumeration for many minutes: a registration still running after 20 s gets installd restarted.
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
log=/var/tmp/rereg.log
: > $log
for a in /Applications/*.app; do
	[ -d "$a/PlugIns" ] || continue
	ls "$a/PlugIns" | grep -q appex || continue
	uicache -p "$a" > /dev/null 2>&1 &
	pid=$!
	t=0; kills=0
	while kill -0 $pid 2>/dev/null; do
		sleep 1; t=$((t+1))
		if [ $t -ge 20 ]; then killall -9 installd 2>/dev/null; kills=$((kills+1)); t=0; fi
		[ $kills -ge 6 ] && { kill -9 $pid; echo "GAVE UP $a" >> $log; break; }
	done
	wait $pid 2>/dev/null
	echo "$(date +%T) $a installd-restarts=$kills" >> $log
done
echo DONE >> $log
