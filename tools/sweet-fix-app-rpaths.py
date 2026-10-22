#!/usr/bin/env python3
"""Rewrite @rpath loads and @-relative LC_RPATHs of the apps in DIR to
absolute /Applications/<App>.app/Frameworks paths and re-sign them ad hoc,
keeping their entitlements.

dyld refuses @ path expansion ("security policy does not allow @ path
expansion") for the system apps we ship in /Applications, so Music, Books and
Podcasts (the IPSW's staged apps with embedded frameworks) cannot load them.

    python3 tools/sweet-fix-app-rpaths.py DIR   # DIR holds Music.app etc.
"""
import os, subprocess, sys, re
root=sys.argv[1]
def run(*a): return subprocess.run(a,capture_output=True,text=True)
for app in sorted(os.listdir(root)):
    if not app.endswith('.app'): continue
    A=os.path.join(root,app); dest='/Applications/'+app+'/Frameworks'
    for d,_,fs in os.walk(A):
        for f in fs:
            p=os.path.join(d,f)
            if os.path.islink(p) or not os.access(p,os.X_OK): continue
            if 'Mach-O' not in run('file','-b',p).stdout: continue
            L=run('otool','-l',p).stdout
            loads=re.findall(r'cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD)_DYLIB\n\s+cmdsize \d+\n\s+name (@\S+)',L)
            rps=re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)',L)
            if not loads and not any(r.startswith('@') for r in rps): continue
            args=[]
            for l in loads:
                if l.startswith('@rpath/'):
                    tgt=dest+'/'+l[len('@rpath/'):]
                    if not os.path.exists(os.path.join(A,'Frameworks',l[len('@rpath/'):])):
                        print('  MISSING',l,'in',p); continue
                    args+=['-change',l,tgt]
            if args:
                r2=run('install_name_tool',*args,p)
                if r2.returncode: print('FAIL',p,r2.stderr.strip()[:300]); continue
            while True:
                rps=re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)',run('otool','-l',p).stdout)
                at=[r for r in rps if r.startswith('@')]
                if not at: break
                a2=['-delete_rpath',at[0]] if dest in rps else ['-rpath',at[0],dest]
                r2=run('install_name_tool',*a2,p)
                if r2.returncode: print('FAIL',p,r2.stderr.strip()[:300]); break
            ents=run('codesign','-d','--entitlements',':-',p).stdout
            ep=p+'.ents.plist'; open(ep,'w').write(ents)
            sa=['codesign','-f','-s','-']+(['--entitlements',ep] if ents.strip() else [])+[p]
            r3=run(*sa); os.remove(ep)
            print(('OK ' if r3.returncode==0 else 'SIGNFAIL ')+os.path.relpath(p,root), r3.stderr.strip()[-200:] if r3.returncode else '')
