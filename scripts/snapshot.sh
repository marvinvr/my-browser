#!/bin/zsh
# Ask the running debug build to write a PNG of the main window.
# Usage: scripts/snapshot.sh <out.png>
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/snapshot.sh <out.png>" >&2
  exit 2
fi

out=$1
mkdir -p "$(dirname "$out")"
case $out in
  /*) ;;
  *) out="$PWD/$out" ;;
esac
rm -f "$out"

SNAPSHOT_PATH="$out" swift -e '
import Foundation
let path = ProcessInfo.processInfo.environment["SNAPSHOT_PATH"] ?? ""
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("ch.marvinvr.mybrowser.debug.snapshot"),
    object: nil,
    userInfo: ["path": path],
    deliverImmediately: true
)
'

for _ in {1..50}; do
  if [[ -s "$out" ]]; then
    exit 0
  fi
  sleep 0.2
done

echo "timed out waiting for $out" >&2
exit 1
