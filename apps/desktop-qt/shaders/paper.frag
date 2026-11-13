#version 440
layout(location=0) in vec2 uv;
layout(location=0) out vec4 fragColor;
layout(std140,binding=0) uniform buf { mat4 matrix; float opacity; int appearance; } ub;
layout(binding=1) uniform sampler2D source;
vec3 linearRgb(vec3 c) { return mix(c/12.92,pow((c+0.055)/1.055,vec3(2.4)),greaterThan(c,vec3(0.04045))); }
vec3 srgb(vec3 c) { return mix(c*12.92,1.055*pow(max(c,vec3(0)),vec3(1.0/2.4))-0.055,greaterThan(c,vec3(0.0031308))); }
float neutralAmount(vec3 c) {
    float maximum=max(c.r,max(c.g,c.b));
    return 1.0-smoothstep(0.0,0.02,(maximum-min(c.r,min(c.g,c.b)))/max(maximum,0.000001));
}
void main() {
    vec4 pixel=texture(source,uv);
    if(ub.appearance!=0) {
        vec3 c=linearRgb(pixel.rgb/max(pixel.a,0.00001));
        vec3 paper=linearRgb((ub.appearance==1 ? vec3(252,247,237) : vec3(36,34,30))/255.0);
        vec3 ink=linearRgb((ub.appearance==1 ? vec3(48,43,37) : vec3(201,197,189))/255.0);
        if(ub.appearance==3) {
            float neutral=neutralAmount(c);
            vec4 figure=mix(vec4(c,pixel.a),vec4(linearRgb(vec3(200,191,175)/255.0),pixel.a*(1.0-dot(c,vec3(0.2126,0.7152,0.0722)))),neutral);
            pixel=vec4(srgb(figure.rgb)*figure.a,figure.a);
        }else {
            if(ub.appearance==2) {
                float luminance=dot(c,vec3(0.2126,0.7152,0.0722));
                float encoded=dot(pixel.rgb/max(pixel.a,0.00001),vec3(0.2126,0.7152,0.0722));
                c=vec3(mix(luminance,encoded,.5*neutralAmount(c)));
            }
            pixel.rgb=srgb(ink+(paper-ink)*c)*pixel.a;
        }
    }
    fragColor=pixel*ub.opacity;
}
