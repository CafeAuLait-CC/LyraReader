#include "PaperAppearance.h"
#include <QQuickWindow>
#include <QSGGeometryNode>
#include <QSGMaterialShader>
#include <QSGTextureMaterial>
#include <array>
#include <cmath>
#include <cstring>

namespace {
double linear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }
double srgb(double c) { return c <= 0.0031308 ? c * 12.92 : 1.055 * std::pow(c, 1.0 / 2.4) - 0.055; }
const std::array<double, 256> &linearChannels() {
    static const auto values = [] { std::array<double, 256> v{}; for (int i=0; i<256; ++i) v[i]=linear(i/255.0); return v; }();
    return values;
}
std::array<double, 3> convert(double r, double g, double b, int mode) {
    const std::array<double, 3> channels{r,g,b};
    const std::array<double, 3> paper = mode == 1 ? std::array<double,3>{252,247,237} : std::array<double,3>{36,34,30};
    const std::array<double, 3> ink = mode == 1 ? std::array<double,3>{48,43,37} : std::array<double,3>{201,197,189};
    const double lightness = r*.2126+g*.7152+b*.0722;
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

int PaperAppearance::mode(const QString &name) { return name==QStringLiteral("warm") ? 1 : name==QStringLiteral("night") ? 2 : 0; }
QColor PaperAppearance::displayColor(const QColor &source,int mode) {
    if (!mode) return source;
    const auto channels=convert(linear(source.redF()),linear(source.greenF()),linear(source.blueF()),mode);
    return QColor::fromRgbF(channels[0],channels[1],channels[2],source.alphaF());
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
        const auto c=convert(double(i)/4096,double(i)/4096,double(i)/4096,mode);
        night[i]=qRgb(qRound(c[0]*255),qRound(c[1]*255),qRound(c[2]*255));
    }
    for(int y=0;y<result.height();++y) {
        auto *row=reinterpret_cast<QRgb *>(result.scanLine(y));
        for(int x=0;x<result.width();++x) {
            const QRgb p=row[x];
            if(mode==1) row[x]=qRgba(warm[0][qRed(p)],warm[1][qGreen(p)],warm[2][qBlue(p)],qAlpha(p));
            else row[x]=(night[qBound(0,qRound((table[qRed(p)]*.2126+table[qGreen(p)]*.7152+table[qBlue(p)]*.0722)*4096),4096)]&0xffffffu)|(quint32(qAlpha(p))<<24);
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
void PaperAppearance::updateNode(QSGNode *base,const QRectF &bounds,int mode) {
    auto *node=static_cast<PaperNode *>(base);
    QSGGeometry::updateTexturedRectGeometry(&node->vertices,bounds,QRectF(0,0,1,1));
    node->markDirty(QSGNode::DirtyGeometry);
    if(node->paint.appearance!=mode) {
        node->paint.appearance=mode;
        node->markDirty(QSGNode::DirtyMaterial);
    }
}
