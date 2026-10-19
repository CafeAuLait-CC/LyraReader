#version 440
layout(location=0) in vec2 uv;
layout(location=0) out vec4 fragColor;
layout(std140,binding=0) uniform buf { mat4 matrix; float opacity; int appearance; } ub;
layout(binding=1) uniform sampler2D source;
vec3 linearRgb(vec3 c) { return mix(c/12.92,pow((c+0.055)/1.055,vec3(2.4)),greaterThan(c,vec3(0.04045))); }
vec3 srgb(vec3 c) { return mix(c*12.92,1.055*pow(max(c,vec3(0)),vec3(1.0/2.4))-0.055,greaterThan(c,vec3(0.0031308))); }
void main() {
    vec4 pixel=texture(source,uv);
    if(ub.appearance!=0) {
        vec3 c=linearRgb(pixel.rgb/max(pixel.a,0.00001));
        vec3 paper=linearRgb((ub.appearance==1 ? vec3(252,247,237) : vec3(36,34,30))/255.0);
        vec3 ink=linearRgb((ub.appearance==1 ? vec3(48,43,37) : vec3(201,197,189))/255.0);
        if(ub.appearance==2) c=vec3(dot(c,vec3(0.2126,0.7152,0.0722)));
        pixel.rgb=srgb(ink+(paper-ink)*c)*pixel.a;
    }
    fragColor=pixel*ub.opacity;
}
