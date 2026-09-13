#!/bin/sh
# Reset Handoff's permission grants. Needed after changing bundle id, signing
# identity, or app path - TCC caches a code requirement per (service, client)
# and a stale one fails CLOSED and SILENTLY.
BUNDLE_ID="com.hackcmu.handoff"
pkill -x Handoff 2>/dev/null
tccutil reset Accessibility "$BUNDLE_ID"
# NB: the service is "ListenEvent", not "InputMonitoring".
tccutil reset ListenEvent   "$BUNDLE_ID"
echo "reset. If System Settings still shows a stale Handoff row, delete it with"
echo "the - button before re-granting, or it shadows the new one."
echo "relaunch with: make run"
