# usage: mkedid.py <scratch dir> <out.bin> <hz:hblank:vblank> x3  (three extra 2560x1440 timings)
import sys
S,out,specs=sys.argv[1],sys.argv[2],sys.argv[3:6]
b=bytearray(open(S+"/xg27.orig.bin","rb").read())
e=256; t=e+8  # DisplayID block 2: 5-byte header + 3-byte Type 1 data block header, then 5x20-byte timings
tim=[bytes(b[t+20*k:t+20*k+20]) for k in range(5)]
def mk(spec):
    hz,hb,vb=map(float,spec.split(':')); hb,vb=int(hb),int(vb)
    d=bytearray(tim[1])  # monitor's own 1440p@180 timing: Hfp 48, Hsw 32, Vfp 3, Vsw 5
    pc=round((2560+hb)*(1440+vb)*hz/10000)-1
    d[0:3]=pc.to_bytes(3,'little'); d[3]&=0x7f
    d[6:8]=(hb-1).to_bytes(2,'little'); d[14:16]=(vb-1).to_bytes(2,'little')
    if hb<160: d[8:10]=((8-1)|0x8000).to_bytes(2,'little')  # CVT-RBv2 style: Hfp 8, keep Hsw 32
    return bytes(d)
# note: keep monitor's 180 and 360, swap 144 and the two 1080p entries for new 1440p rates
for k,d in enumerate([mk(specs[0]),tim[1],tim[2],mk(specs[1]),mk(specs[2])]): b[t+20*k:t+20*k+20]=d
ln=b[e+2]; b[e+5+ln]=(-sum(b[e+1:e+5+ln]))&0xff; b[e+127]=(-sum(b[e:e+127]))&0xff
assert sum(b[e+1:e+6+ln])%256==0 and sum(b[e:e+128])%256==0
open(out,"wb").write(b)
