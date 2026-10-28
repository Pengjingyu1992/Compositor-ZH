"""Independent C float references, from the published native Swift equations.
The fixtures do not claim to reproduce proprietary Core Image morphology/blur.
"""
import ctypes,json,pathlib,subprocess,tempfile,hashlib
root=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='comp-edge-reference-') as tmp:
 lib=pathlib.Path(tmp)/'edge.so';subprocess.run(['cc','-shared','-fPIC','-O2','-ffp-contract=off',str(pathlib.Path(__file__).with_name('edge-refinement-reference.c')),'-lm','-o',str(lib)],check=True)
 c=ctypes.CDLL(str(lib));fp=ctypes.POINTER(ctypes.c_float);c.edge_guided.argtypes=[fp,fp,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_float,fp];c.edge_dab.argtypes=[fp,fp,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_double,ctypes.c_double,ctypes.c_int,ctypes.c_double,ctypes.c_double]
 w,h=9,7;n=w*h;array=ctypes.c_float*n;cases=[]
 for name,radius,kind in [('flat-guide',8,0),('color-edge',8,1),('fine-radius',1,1),('mask-gradient',3,2)]:
  mask=[(x/(w-1) if kind==2 else 1 if x<5 else 0) for y in range(h) for x in range(w)];guide=[(.4 if kind==0 else (.1 if x<4 else .9)+y*.005) for y in range(h) for x in range(w)];out=array();c.edge_guided(array(*mask),array(*guide),w,h,radius,.001,out);cases.append(dict(name=name,width=w,height=h,radius=radius,mask=mask,guide=guide,expected=list(out)))
 guided=array(*cases[1]['expected']);brushes=[]
 for mode in range(3):
  levels=array(*([.5]*n));c.edge_dab(levels,guided,w,h,w,8,.6,mode,4.25,3.5);brushes.append(dict(mode=['refine','reveal','hide'][mode],expected=list(levels)))
 rgba=[component for y in range(h) for x in range(w) for component in ([25+x*13,40+y*19,180-x*9,[0,32,128,255][x%4]])];coverage=[255 if x<3 else 128 if x<7 else 0 for y in range(h) for x in range(w)];byte=ctypes.c_ubyte;c.edge_clean.argtypes=[ctypes.POINTER(byte),ctypes.POINTER(byte),ctypes.c_int,ctypes.c_int,ctypes.c_double,ctypes.POINTER(byte)];clean=[]
 for amount in [.2,1]:
  output=(byte*(n*4))();c.edge_clean((byte*(n*4))(*rgba),(byte*n)(*coverage),w,h,amount,output);clean.append(dict(amount=amount,rgba=rgba,mask=coverage,expected=list(output)))
 data=dict(reference='macOS f8b1457 Swift equations; independent C float, no Core Image',width=w,height=h,cases=cases,brushes=brushes,clean=clean)
 (root/'tests/golden/edge-refinement.json').write_text(json.dumps(data,separators=(',',':'))+'\n')
