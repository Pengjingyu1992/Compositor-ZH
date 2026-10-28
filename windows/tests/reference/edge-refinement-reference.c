/* Independent float implementation of the equations in macOS f8b1457
 * GuidedMatte.swift and EdgeRefinement.swift; no Core Image implementation. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
static int bound(int x,int n){return x<0?0:x>=n?n-1:x;}
void edge_box(const float*s,int w,int h,int r,float*out){float*pass=calloc(w*h,sizeof(float)),span=r*2+1;for(int y=0;y<h;y++){float sum=0;for(int x=-r;x<=r;x++)sum+=s[y*w+bound(x,w)];for(int x=0;x<w;x++){pass[y*w+x]=sum/span;sum-=s[y*w+bound(x-r,w)];sum+=s[y*w+bound(x+r+1,w)];}}for(int x=0;x<w;x++){float sum=0;for(int y=-r;y<=r;y++)sum+=pass[bound(y,h)*w+x];for(int y=0;y<h;y++){out[y*w+x]=sum/span;sum-=pass[bound(y-r,h)*w+x];sum+=pass[bound(y+r+1,h)*w+x];}}free(pass);}
void edge_guided(const float*m,const float*g,int w,int h,int r,float e,float*out){int n=w*h;float*a=calloc(n*10,sizeof(float)),*mg=a,*mm=a+n,*s=a+2*n,*p=a+3*n,*ms=a+4*n,*mp=a+5*n,*slope=a+6*n,*off=a+7*n,*ma=a+8*n,*mb=a+9*n;edge_box(g,w,h,r,mg);edge_box(m,w,h,r,mm);for(int i=0;i<n;i++){s[i]=g[i]*g[i];p[i]=g[i]*m[i];}edge_box(s,w,h,r,ms);edge_box(p,w,h,r,mp);for(int i=0;i<n;i++){float v=ms[i]-mg[i]*mg[i],c=mp[i]-mg[i]*mm[i];slope[i]=c/(v+e);off[i]=mm[i]-slope[i]*mg[i];}edge_box(slope,w,h,r,ma);edge_box(off,w,h,r,mb);for(int i=0;i<n;i++)out[i]=fminf(1,fmaxf(0,ma[i]*g[i]+mb[i]));free(a);}
void edge_dab(float*levels,const float*guided,int w,int h,int sw,double diameter,double strength,int mode,double px,double py){double radius=fmax(1,diameter/2*w/sw);for(int y=0;y<h;y++)for(int x=0;x<w;x++){double d=hypot(x+.5-px,y+.5-py)/radius;if(d>=1)continue;int i=y*w+x;float amount=(1-d)*strength,target=mode==0?guided[i]:mode==1?1:0;levels[i]+=(target-levels[i])*amount;}}
void edge_clean(const unsigned char*rgba,const unsigned char*mask,int w,int h,double amount,unsigned char*out){
 int n=w*h;unsigned char*input=calloc(n*4,1);for(int i=0;i<n;i++){input[i*4+3]=rgba[i*4+3];for(int c=0;c<3;c++)input[i*4+c]=lround(rgba[i*4+c]*rgba[i*4+3]/255.0);}memcpy(out,input,n*4);
 const int dxs[]={-1,1,0,0,-1,1,-1,1},dys[]={0,0,-1,1,-1,1,1,-1},radii[]={1,2,4,8,16};
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){int i=y*w+x;float coverage=mask[i]/255.f;unsigned char*target=out+i*4;if(coverage<=.01f||coverage>=.98f||!target[3])continue;int done=0;
  for(int r=0;r<5&&!done;r++)for(int d=0;d<8;d++){int nx=x+dxs[d]*radii[r],ny=y+dys[d]*radii[r];if(nx<0||ny<0||nx>=w||ny>=h||mask[ny*w+nx]/255.f<=.98f)continue;const unsigned char*p=input+(ny*w+nx)*4;if(!p[3])continue;double blend=amount*(double)(1.f-coverage),alpha=target[3];for(int c=0;c<3;c++){double value=round(target[c]*(1-blend)+p[c]/(double)p[3]*alpha*blend);target[c]=fmin(alpha,fmax(0,value));}done=1;break;}}
 for(int i=0;i<n;i++)for(int c=0;c<3;c++)out[i*4+c]=out[i*4+3]?lround(out[i*4+c]*255.0/out[i*4+3]):0;free(input);
}
