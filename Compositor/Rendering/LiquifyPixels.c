#include "LiquifyPixels.h"
#include <math.h>
static float clampf(float x, float lo, float hi) { return fminf(hi, fmaxf(lo, x)); }
static LiquifyNode sample(const LiquifyNode *n, int w, int h, float x, float y) {
    x = clampf(x, 0, w - 1); y = clampf(y, 0, h - 1);
    int a = (int)x, b = (int)y, c = a + 1 < w ? a + 1 : a, d = b + 1 < h ? b + 1 : b;
    float fx = x - a, fy = y - b;
    LiquifyNode p = {0};
    p.dx = (n[b*w+a].dx*(1-fx)+n[b*w+c].dx*fx)*(1-fy)+(n[d*w+a].dx*(1-fx)+n[d*w+c].dx*fx)*fy;
    p.dy = (n[b*w+a].dy*(1-fx)+n[b*w+c].dy*fx)*(1-fy)+(n[d*w+a].dy*(1-fx)+n[d*w+c].dy*fx)*fy;
    p.frozen = (n[b*w+a].frozen*(1-fx)+n[b*w+c].frozen*fx)*(1-fy)+(n[d*w+a].frozen*(1-fx)+n[d*w+c].frozen*fx)*fy;
    return p;
}
void liquify_dab(LiquifyNode *n, const LiquifyNode *old, int gw, int gh, float step,
                 int width, int height, float cx, float cy, float mx, float my, float radius,
                 float hardness, float amount, int tool, int fixed_edges) {
    int x0 = (int)fmaxf(0, floorf((cx-radius)/step)), x1 = (int)fminf(gw-1, ceilf((cx+radius)/step));
    int y0 = (int)fmaxf(0, floorf((cy-radius)/step)), y1 = (int)fminf(gh-1, ceilf((cy+radius)/step));
    for (int y=y0; y<=y1; y++) for (int x=x0; x<=x1; x++) {
        float px = fminf(width-1, x*step), py = fminf(height-1, y*step);
        float dx=px-cx, dy=py-cy, u=hypotf(dx,dy)/radius;
        if (u>=1) continue;
        float w=u<=hardness?1:clampf((1-u)/(1-hardness),0,1);
        w=w*w*(3-2*w);
        int i=y*gw+x;
        if (tool==7 || tool==8) {
            float f=clampf(w*amount,0,1);
            n[i].frozen=tool==7 ? old[i].frozen+(1-old[i].frozen)*f : old[i].frozen*(1-f);
            continue;
        }
        w*=1-old[i].frozen;
        if (fixed_edges) w*=clampf(fminf(fminf(px,py),fminf(width-1-px,height-1-py))/radius,0,1);
        if (w<=0) continue;
        float k=w*amount, sx=px, sy=py;
        if (tool==5) { n[i].dx=old[i].dx*(1-k); n[i].dy=old[i].dy*(1-k); continue; }
        if (tool==0) { sx-=mx*k; sy-=my*k; }
        if (tool==1) { float angle=-k, c=cosf(angle), s=sinf(angle); sx=cx+c*dx-s*dy; sy=cy+s*dx+c*dy; }
        if (tool==2 || tool==3) { float scale=expf((tool==2?1:-1)*k); sx=cx+dx*scale; sy=cy+dy*scale; }
        LiquifyNode offset=sample(old,gw,gh,sx/step,sy/step);
        n[i].dx=clampf(sx-px+offset.dx,-width,width);
        n[i].dy=clampf(sy-py+offset.dy,-height,height);
    }
}
void liquify_render(const uint8_t *src, int w, int h, int stride, const LiquifyNode *n, int gw, int gh,
                    float step, const uint8_t *coverage, int cs, int keep_alpha,
                    uint8_t *out, int ow, int oh, int os, int first, int end) {
    for(int y=first;y<end;y++) for(int x=0;x<ow;x++) {
        float px=(x+.5f)*w/ow-.5f, py=(y+.5f)*h/oh-.5f;
        LiquifyNode d=sample(n,gw,gh,px/step,py/step);
        float sx=clampf(px+d.dx,0,w-1), sy=clampf(py+d.dy,0,h-1);
        int ix=(int)sx, iy=(int)sy, jx=ix+1<w?ix+1:ix, jy=iy+1<h?iy+1:iy;
        float fx=sx-ix,fy=sy-iy;
        int ox=(int)clampf(roundf(px),0,w-1), oy=(int)clampf(roundf(py),0,h-1);
        float selected=coverage ? coverage[oy*cs+ox]/255.f : 1;
        for(int c=0;c<4;c++) {
            float a=src[iy*stride+ix*4+c]*(1-fx)+src[iy*stride+jx*4+c]*fx;
            float b=src[jy*stride+ix*4+c]*(1-fx)+src[jy*stride+jx*4+c]*fx;
            out[y*os+x*4+c]=(uint8_t)clampf(roundf((a*(1-fy)+b*fy)*selected+src[oy*stride+ox*4+c]*(1-selected)),0,255);
        }
        if (keep_alpha) {
            uint8_t *p=out+y*os+x*4;
            unsigned alpha=p[3], kept=src[oy*stride+ox*4+3];
            for(int c=0;c<3;c++) p[c]=(uint8_t)fminf(kept,alpha?(p[c]*kept+alpha/2)/alpha:src[oy*stride+ox*4+c]);
            p[3]=(uint8_t)kept;
        }
    }
}
void liquify_overlay(const LiquifyNode *n,int gw,int gh,float step,int w,int h,uint8_t *out,int ow,int oh,int stride) {
    for(int y=0;y<oh;y++) for(int x=0;x<ow;x++) {
        float f=sample(n,gw,gh,(x+.5f)*w/ow/step,(y+.5f)*h/oh/step).frozen;
        uint8_t a=(uint8_t)clampf(roundf(f*110),0,110);uint8_t *p=out+y*stride+x*4;
        p[0]=a;p[1]=0;p[2]=0;p[3]=a;
    }
}
