#!/bin/sh
# Builds the diagnostic tools into OUT (default ./out), ad-hoc signed with their entitlements.
# sweet-oslog SECONDS [PREDICATE]  live unified log (LoggingSupport's OSLogEventLiveStream)
# sweet-stack PID                  user backtraces of every thread (frame pointers, dladdr)
# sweet-lsquery ID...              LaunchServices' view of an app or plug-in
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/out}
SDK=${SDK:-$here/../../../sdk/theos-sdks/iPhoneOS16.5.sdk}
cc="clang -target arm64-apple-ios16.0 -isysroot $SDK"
mkdir -p "$out"
$cc -fobjc-arc -framework Foundation "$here/sweet-oslog.m" -o "$out/sweet-oslog"
$cc "$here/sweet-stack.c" -o "$out/sweet-stack"
$cc -fobjc-arc -framework Foundation -framework MobileCoreServices "$here/sweet-lsquery.m" -o "$out/sweet-lsquery"
ldid -S"$here/ents-logging.plist" "$out/sweet-oslog"
ldid -S"$here/ents-taskport.plist" "$out/sweet-stack"
ldid -S"$here/ents-logging.plist" "$out/sweet-lsquery"
