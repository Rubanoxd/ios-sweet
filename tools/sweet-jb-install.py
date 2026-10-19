#!/usr/bin/env python3
"""Add a Procursus rootless bootstrap, SSH and .deb packages (e.g. Sileo) to
an iOS root image made by tools/mkiosroot.sh / mkiosroot-macos.sh.

  sudo sweet-jb-install.py MOUNTED_ROOT --bootstrap bootstrap-ssh-iphoneos-arm64.tar.zst
                           [--deb PKG.deb ...] [--authorized-key KEY.pub]

The bootstrap is Procursus' iOS 16 one (suite 1900,
https://apt.procurs.us/bootstraps/1900/), unpacked to /var/jb like on a
rootless jailbreak. This port runs with permissive code signing and sandbox,
so nothing is exploited here: the files are just placed on the root volume.

On iOS, launchd reads its jobs from the /System/Library/xpc/launchd.plist
cache (launchd_unsecure_cache=1), not from LaunchDaemons directories, and
only for entries keyed under the system directories, so these are added as
/System/Library/LaunchDaemons jobs:
  com.openssh.sshd   Procursus' socket-activated sshd (ports 22 and 2222),
                     host keys made on the first connection
  es.sweet.jb-firstboot  runs /var/jb/var/sweet/firstboot.sh once per boot
                     until it has finished: prep_bootstrap.sh (no password
                     prompt), `dpkg -i` of the --deb packages, then uicache,
                     logging to /var/jb/var/sweet/firstboot.log and the console
  es.sweet.netconfig with --netconfig BIN (tools/sweet-netconfig): installed
                     as /var/jb/usr/bin/sweet-netconfig, run at load and every
                     60 s, so configd routes and resolves through the Mac
                     (sudo tools/sweet-nat-macos.sh on the Mac side)
--authorized-key installs a public key for root and mobile (both home
directories: the system one and the bootstrap's /var/jb/var/...).
Run as root (owners and modes are preserved). Idempotent.
"""
import argparse, os, plistlib, shutil, subprocess, sys

FIRSTBOOT = r'''#!/var/jb/bin/sh
# Written by tools/sweet-jb-install.py. Runs at every boot until done.
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin
S=/var/jb/var/sweet
[ -e $S/firstboot.done ] && exit 0
exec >> $S/firstboot.log 2>&1
say() { echo "SWEET JB: $*"; echo "SWEET JB: $*" > /dev/console; }
say "first boot setup starting"
if [ -e /var/jb/prep_bootstrap.sh ]; then
	NO_PASSWORD_PROMPT=1 /var/jb/bin/sh /var/jb/prep_bootstrap.sh
	say "prep_bootstrap.sh exit $?"
fi
for d in $S/debs/*.deb; do
	[ -e "$d" ] || continue
	dpkg -i "$d" && rm -f "$d"
	say "dpkg -i ${d##*/} exit $?"
done
# SpringBoard and lsd are up by now on a normal boot; give a first boot time.
sleep 120
uicache -a
say "uicache exit $?"
touch $S/firstboot.done
say "first boot setup done"
'''


def run(*cmd, **kw):
    print('+', ' '.join(cmd))
    subprocess.run(cmd, check=True, **kw)


def install_key(root, key, home, uid, gid):
    d = os.path.join(root, home.lstrip('/'), '.ssh')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'authorized_keys')
    old = open(path).read() if os.path.exists(path) else ''
    if key.strip() not in old:
        with open(path, 'a') as f:
            f.write(key.strip() + '\n')
    for p, mode in ((os.path.dirname(d), None), (d, 0o700), (path, 0o600)):
        os.chown(p, uid, gid)
        if mode:
            os.chmod(p, mode)
    print('authorized key for', home)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('root')
    ap.add_argument('--bootstrap', required=True)
    ap.add_argument('--deb', action='append', default=[])
    ap.add_argument('--authorized-key')
    ap.add_argument('--netconfig', help='sweet-netconfig binary (tools/sweet-netconfig/build.sh)')
    a = ap.parse_args()
    root = a.root
    if os.geteuid() != 0 or not os.path.isdir(os.path.join(root, 'System/Library/xpc')):
        sys.exit(__doc__)
    jb = os.path.join(root, 'private/var/jb')

    if not os.path.exists(os.path.join(jb, 'usr/bin/dpkg')):
        # Paths in the archive are ./var/jb/...; /var is /private/var on iOS.
        zstd = subprocess.Popen(['zstd', '-dc', a.bootstrap], stdout=subprocess.PIPE)
        run('tar', '-xpf', '-', '--numeric-owner', '-C', os.path.join(root, 'private'), stdin=zstd.stdout)
        if zstd.wait():
            sys.exit('zstd failed')
    else:
        print('bootstrap already present')

    s = os.path.join(jb, 'var/sweet')
    os.makedirs(os.path.join(s, 'debs'), exist_ok=True)
    for deb in a.deb:
        shutil.copyfile(deb, os.path.join(s, 'debs', os.path.basename(deb)))
        print('queued', os.path.basename(deb))
    fb = os.path.join(s, 'firstboot.sh')
    with open(fb, 'w') as f:
        f.write(FIRSTBOOT)
    os.chmod(fb, 0o755)
    for p in (s, os.path.join(s, 'debs'), fb):
        os.chown(p, 0, 0)

    lp = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lp)
    with open(lp, 'rb') as f:
        plist = plistlib.load(f)
    with open(os.path.join(jb, 'Library/LaunchDaemons/com.openssh.sshd.plist'), 'rb') as f:
        sshd = plistlib.load(f)
    daemons = plist['LaunchDaemons']
    jobs = [('com.openssh.sshd', sshd)]
    firstboot = {
        'Label': 'es.sweet.jb-firstboot',
        'Program': '/var/jb/bin/sh',
        'ProgramArguments': ['/var/jb/bin/sh', '/var/jb/var/sweet/firstboot.sh'],
        'RunAtLoad': True,
        'LaunchOnlyOnce': True,
        'UserName': 'root',
        'POSIXSpawnType': 'Interactive',
        'StandardOutPath': '/dev/console',
        'StandardErrorPath': '/dev/console',
    }
    # launchd only loads cache entries keyed under the system directories
    # (a first boot with /var/jb/... keys started neither job), so register
    # them as /System/Library/LaunchDaemons files, which also exist on disk.
    sysld = os.path.join(root, 'System/Library/LaunchDaemons')
    jobs.append(('es.sweet.jb-firstboot', firstboot))
    if a.netconfig:
        nc = os.path.join(jb, 'usr/bin/sweet-netconfig')
        shutil.copyfile(a.netconfig, nc)
        os.chown(nc, 0, 0)
        os.chmod(nc, 0o755)
        jobs.append(('es.sweet.netconfig', {
            'Label': 'es.sweet.netconfig',
            'Program': '/var/jb/usr/bin/sweet-netconfig',
            'ProgramArguments': ['/var/jb/usr/bin/sweet-netconfig'],
            'RunAtLoad': True,
            'StartInterval': 60,   # again after a configd restart
            'UserName': 'root',
            'StandardOutPath': '/dev/null',
            'StandardErrorPath': '/dev/null',
        }))
    for name, job in jobs:
        daemons.pop('/var/jb/Library/LaunchDaemons/%s.plist' % name, None)
        daemons['/System/Library/LaunchDaemons/%s.plist' % name] = job
        path = os.path.join(sysld, name + '.plist')
        with open(path, 'wb') as f:
            plistlib.dump(job, f)
        os.chown(path, 0, 0)
        os.chmod(path, 0o644)
    with open(lp, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    os.chown(lp, st.st_uid, st.st_gid)
    os.chmod(lp, st.st_mode & 0o7777)
    print('launchd.plist: %s (as /System/Library/LaunchDaemons)' % ', '.join(n for n, _ in jobs))

    if a.authorized_key:
        key = open(a.authorized_key).read()
        for home, uid in (('/private/var/root', 0), ('/private/var/jb/var/root', 0),
                          ('/private/var/mobile', 501), ('/private/var/jb/var/mobile', 501)):
            install_key(root, key, home, uid, uid)


if __name__ == '__main__':
    main()
