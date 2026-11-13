#include "PaperAppearance.h"
#include <QQuickWindow>
#include <QSGGeometryNode>
#include <QSGMaterialShader>
#include <QSGTextureMaterial>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
double linear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }
double srgb(double c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * std::pow(c, 1.0 / 2.4) - 0.055; }
const std::array<double, 256> &linearChannels() {
    static const auto values = [] { std::array<double, 256> v{}; for (int i=0; i<256; ++i) v[i]=linear(i/255.0); return v; }();
    return values;
}
double neutralAmount(double r,double g,double b) {
    const double maximum=std::max(r,std::max(g,b)),minimum=std::min(r,std::min(g,b));
    const double t=std::clamp((maximum-minimum)/std::max(maximum,0.000001)/.02,0.0,1.0);
    return 1-t*t*(3-2*t);
}
double nightLightness(double r,double g,double b,double encodedR,double encodedG,double encodedB) {
    const double linearLightness=r*.2126+g*.7152+b*.0722;
    return linearLightness+(.2126*encodedR+.7152*encodedG+.0722*encodedB-linearLightness)*neutralAmount(r,g,b)*.5;
}
std::array<double, 3> convert(double r, double g, double b, int mode,bool correctNeutral=true) {
    const std::array<double, 3> channels{r,g,b};
    const std::array<double, 3> paper = mode == 1 ? std::array<double,3>{252,247,237} : std::array<double,3>{36,34,30};
    const std::array<double, 3> ink = mode == 1 ? std::array<double,3>{48,43,37} : std::array<double,3>{201,197,189};
    const double lightness = mode==2 && correctNeutral ? nightLightness(r,g,b,srgb(r),srgb(g),srgb(b)) : r*.2126+g*.7152+b*.0722;
    std::array<double,3> output{};
    for (int i=0; i<3; ++i) {
        const double low=linear(ink[i]/255.0), high=linear(paper[i]/255.0);
        output[i]=srgb(low+(high-low)*(mode==2 ? lightness : channels[i]));
    }
    return output;
}
class PaperShader;
class PaperMaterial final : public QSGTextureMaterial {
public:
    int appearance=0;
    QSGMaterialType *type() const override { static QSGMaterialType type; return &type; }
    QSGMaterialShader *createShader(QSGRendererInterface::RenderMode) const override;
    int compare(const QSGMaterial *other) const override {
        const auto *b=static_cast<const PaperMaterial *>(other);
        if (appearance!=b->appearance) return appearance<b->appearance ? -1 : 1;
        return QSGTextureMaterial::compare(other);
    }
};
class PaperShader final : public QSGMaterialShader {
public:
    PaperShader() {
        setShaderFileName(VertexStage,QStringLiteral(":/shaders/paper.vert.qsb"));
        setShaderFileName(FragmentStage,QStringLiteral(":/shaders/paper.frag.qsb"));
    }
    bool updateUniformData(RenderState &state,QSGMaterial *material,QSGMaterial *) override {
        auto *bytes=state.uniformData();
        if(state.isMatrixDirty()) std::memcpy(bytes->data(),state.combinedMatrix().constData(),64);
        const float opacity=state.opacity();
        const int mode=static_cast<PaperMaterial *>(material)->appearance;
        std::memcpy(bytes->data()+64,&opacity,4);
        std::memcpy(bytes->data()+68,&mode,4);
        return true;
    }
    void updateSampledImage(RenderState &state,int binding,QSGTexture **texture,QSGMaterial *material,QSGMaterial *) override {
        if (binding!=1) return;
        *texture=static_cast<PaperMaterial *>(material)->texture();
        (*texture)->setFiltering(QSGTexture::Linear);
        (*texture)->commitTextureOperations(state.rhi(),state.resourceUpdateBatch());
    }
};
QSGMaterialShader *PaperMaterial::createShader(QSGRendererInterface::RenderMode) const { return new PaperShader; }
class PaperNode final : public QSGGeometryNode {
public:
    QSGGeometry vertices{QSGGeometry::defaultAttributes_TexturedPoint2D(),4};
    PaperMaterial paint;
    QSGTexture *pixels=nullptr;
    PaperNode() { vertices.setDrawingMode(QSGGeometry::DrawTriangleStrip); setGeometry(&vertices); setMaterial(&paint); }
    ~PaperNode() override { delete pixels; }
};
}

int PaperAppearance::mode(const QString &name) { if(name==QStringLiteral("dark-figure"))return 3; return name==QStringLiteral("warm") ? 1 : name==QStringLiteral("night") ? 2 : 0; }
QColor PaperAppearance::displayColor(const QColor &source,int mode) {
    if (!mode) return source;
    const double r=linear(source.redF()),g=linear(source.greenF()),b=linear(source.blueF());
    if(mode==3) {
        const double neutral=neutralAmount(r,g,b),lightness=r*.2126+g*.7152+b*.0722;
        // Match the shared GPU scientific-crop transfer. This changes display only.
        return QColor::fromRgbF(srgb(r+(linear(200.0/255)-r)*neutral),
            srgb(g+(linear(191.0/255)-g)*neutral),srgb(b+(linear(175.0/255)-b)*neutral),
            source.alphaF()*(1-lightness*neutral));
    }
    const auto channels=convert(r,g,b,mode);
    return QColor::fromRgbF(channels[0],channels[1],channels[2],source.alphaF());
}
namespace {
const std::array<QRgb,65536> &grayFigureColours() {
    // Freeze the existing scalar colour conversion, including QColor's alpha rounding.
    // One bounded 256 KiB table serves every software crop; uploaded source bytes stay raw.
    static const auto values=[] {
        std::array<QRgb,65536> result{};
        for(int alpha=0;alpha<256;++alpha)for(int gray=0;gray<256;++gray)
            result[alpha*256+gray]=PaperAppearance::displayColor(QColor(gray,gray,gray,alpha),3).rgba();
        return result;
    }();
    return values;
}
}
QImage PaperAppearance::displayImage(const QImage &source,int mode) {
    if(!mode) return source;
    auto result=source.convertToFormat(QImage::Format_ARGB32);
    result.detach();
    const auto &table=linearChannels();
    // Warm mode is channel-separable; precompute its LUT instead of pow() per pixel.
    std::array<std::array<int,256>,3> warm{};
    if(mode==1) for(int value=0;value<256;++value) {
        const auto c=convert(table[value],table[value],table[value],mode);
        for(int k=0;k<3;++k) warm[k][value]=qRound(c[k]*255);
    }
    // Night mode is monochrome. A fine luminance LUT keeps the software fallback responsive.
    std::array<QRgb,4097> night{};
    if(mode==2) for(int i=0;i<=4096;++i) {
        const auto c=convert(double(i)/4096,double(i)/4096,double(i)/4096,mode,false);
        night[i]=qRgb(qRound(c[0]*255),qRound(c[1]*255),qRound(c[2]*255));
    }
    const auto *grayFigure=mode==3 ? &grayFigureColours() : nullptr;
    for(int y=0;y<result.height();++y) {
        auto *row=reinterpret_cast<QRgb *>(result.scanLine(y));
        for(int x=0;x<result.width();++x) {
            const QRgb p=row[x];
            if(mode==1) row[x]=qRgba(warm[0][qRed(p)],warm[1][qGreen(p)],warm[2][qBlue(p)],qAlpha(p));
            else if(mode==2) row[x]=(night[qBound(0,qRound(nightLightness(table[qRed(p)],table[qGreen(p)],table[qBlue(p)],qRed(p)/255.0,qGreen(p)/255.0,qBlue(p)/255.0)*4096),4096)]&0xffffffu)|(quint32(qAlpha(p))<<24);
            else if(mode==3 && qRed(p)==qGreen(p) && qRed(p)==qBlue(p))
                row[x]=(*grayFigure)[qAlpha(p)*256+qRed(p)];
            else if(mode==3 && neutralAmount(table[qRed(p)],table[qGreen(p)],table[qBlue(p)])==0)
                row[x]=p; // Fully chromatic pixels are exactly unchanged by the transfer.
            else row[x]=displayColor(QColor::fromRgba(p),mode).rgba();
        }
    }
    return result;
}
QSGNode *PaperAppearance::createNode(QQuickWindow *window,const QImage &source,int mode) {
    auto *node=new PaperNode;
    node->pixels=window->createTextureFromImage(source);
    if(!node->pixels) { delete node; return nullptr; }
    node->paint.setTexture(node->pixels);
    node->paint.appearance=mode;
    node->paint.setFiltering(QSGTexture::Linear);
    return node;
}
void PaperAppearance::updateNode(QSGNode *base,const QRectF &bounds,int mode,const QRectF &sourceRect) {
    const Quad quad{bounds,sourceRect};updateNodeQuads(base,&quad,1,mode);
}
void PaperAppearance::updateNodeQuads(QSGNode *base,const Quad *quads,int count,int mode) {
    Q_ASSERT(count==1 || count==2);
    auto *node=static_cast<PaperNode *>(base);
    if(count==1) {
        if(node->vertices.vertexCount()!=4)node->vertices.allocate(4);
        node->vertices.setDrawingMode(QSGGeometry::DrawTriangleStrip);
        QSGGeometry::updateTexturedRectGeometry(&node->vertices,quads[0].target,quads[0].source);
    }else {
        if(node->vertices.vertexCount()!=12)node->vertices.allocate(12);
        node->vertices.setDrawingMode(QSGGeometry::DrawTriangles);
        auto *vertices=node->vertices.vertexDataAsTexturedPoint2D();
        for(int i=0;i<2;++i) {
            const auto &r=quads[i].target;const auto &uv=quads[i].source;
            const std::array<QPointF,6> positions{r.topLeft(),r.bottomLeft(),r.topRight(),r.topRight(),r.bottomLeft(),r.bottomRight()};
            const std::array<QPointF,6> sources{uv.topLeft(),uv.bottomLeft(),uv.topRight(),uv.topRight(),uv.bottomLeft(),uv.bottomRight()};
            for(int v=0;v<6;++v)vertices[i*6+v].set(float(positions[v].x()),float(positions[v].y()),float(sources[v].x()),float(sources[v].y()));
        }
    }
    node->markDirty(QSGNode::DirtyGeometry);
    if(node->paint.appearance!=mode) {
        node->paint.appearance=mode;
        node->markDirty(QSGNode::DirtyMaterial);
    }
}
