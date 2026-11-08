#include "AnnotationOverlay.h"
#include "PaperAppearance.h"
#include "PageItem.h"
#include <QSGClipNode>
#include <QSGGeometryNode>
#include <QSGTransformNode>
#include <QSGFlatColorMaterial>
#include <QSGMaterialShader>
#include <QVector4D>
#include <QSGRenderNode>
#include <QPainter>
#include <QPainterPath>
#include <QQuickWindow>
#include <cmath>
#include <cstring>

namespace {
class AnnotationScene final:public QSGTransformNode {
public:
    quint64 contentEpoch=0;
    double width=0,paperHeight=0,split=0;
    bool torn=false;
    QSGNode *upper=nullptr;
    QSGTransformNode *lower=nullptr;
};
QSGClipNode *paperClip(const QRectF &rect) {
    auto *node=new QSGClipNode;
    // Rectangular scissoring is only a hint. Keep real geometry for stencil clipping when
    // an ancestor transform is not axis aligned, as required by QSGClipNode's contract.
    auto *geometry=new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(),4);
    geometry->setDrawingMode(QSGGeometry::DrawTriangleStrip);QSGGeometry::updateRectGeometry(geometry,rect);
    node->setGeometry(geometry);node->setFlag(QSGNode::OwnsGeometry,true);
    node->setIsRectangular(true);node->setClipRect(rect);return node;
}
class SoftwareNode final:public QSGRenderNode {
public:
    QQuickWindow *window=nullptr;
    QRectF bounds;
    QVector<QPointF> vertices;
    QColor color;
    bool multiply=false;
    RenderingFlags flags()const override{return BoundedRectRendering;}
    QRectF rect()const override{return bounds;}
    void render(const RenderState *state)override {
        auto *painter=static_cast<QPainter *>(window->rendererInterface()->getResource(window,QSGRendererInterface::PainterResource));
        if(!painter)return;
        painter->save();
        // Qt supplies dirty + ancestor clips in window coordinates. Apply them
        // before the item transform; otherwise a partial update multiplies old
        // backing-store pixels again, including when this node's dirty region is empty.
        painter->resetTransform();
        if(const auto *clip=state->clipRegion())painter->setClipRegion(*clip,Qt::ReplaceClip);
        painter->setWorldTransform(matrix()->toTransform());painter->setClipRect(bounds,Qt::IntersectClip);
        painter->setRenderHint(QPainter::Antialiasing,true);painter->setOpacity(inheritedOpacity());
        painter->setCompositionMode(multiply?QPainter::CompositionMode_Multiply:QPainter::CompositionMode_SourceOver);
        QPainterPath path;path.setFillRule(Qt::WindingFill);
        for(qsizetype i=0;i+2<vertices.size();i+=3){path.moveTo(vertices.at(i));path.lineTo(vertices.at(i+1));path.lineTo(vertices.at(i+2));path.closeSubpath();}
        painter->fillPath(path,color);painter->restore();
    }
};
class MultiplyShader;
class MultiplyMaterial final:public QSGMaterial {
public:
    QColor tint;
    explicit MultiplyMaterial(QColor color):tint(color){setFlag(Blending,true);}
    QSGMaterialType *type()const override{static QSGMaterialType type;return &type;}
    QSGMaterialShader *createShader(QSGRendererInterface::RenderMode)const override;
    int compare(const QSGMaterial *other)const override{
        const auto a=tint.rgba64(),b=static_cast<const MultiplyMaterial *>(other)->tint.rgba64();
        return a==b ? 0 : quint64(a)<quint64(b) ? -1 : 1;
    }
};
class MultiplyShader final:public QSGMaterialShader {
public:
    MultiplyShader(){setShaderFileName(VertexStage,QStringLiteral(":/shaders/annotation.vert.qsb"));setShaderFileName(FragmentStage,QStringLiteral(":/shaders/annotation.frag.qsb"));setFlag(UpdatesGraphicsPipelineState,true);}
    bool updateUniformData(RenderState &state,QSGMaterial *material,QSGMaterial *)override{
        auto *buffer=state.uniformData();
        if(state.isMatrixDirty())std::memcpy(buffer->data(),state.combinedMatrix().constData(),64);
        const auto color=static_cast<MultiplyMaterial *>(material)->tint;
        const float opacity=state.opacity();
        const QVector4D tint(1.0f+(float(color.redF())-1.0f)*opacity,1.0f+(float(color.greenF())-1.0f)*opacity,1.0f+(float(color.blueF())-1.0f)*opacity,1.0f);
        std::memcpy(buffer->data()+64,&tint,16);
        return true;
    }
    bool updateGraphicsPipelineState(RenderState &,GraphicsPipelineState *state,QSGMaterial *,QSGMaterial *)override{
        state->blendEnable=true;state->srcColor=GraphicsPipelineState::DstColor;state->dstColor=GraphicsPipelineState::Zero;
        state->separateBlendFactors=true;state->srcAlpha=GraphicsPipelineState::Zero;state->dstAlpha=GraphicsPipelineState::One;
        return true;
    }
};
QSGMaterialShader *MultiplyMaterial::createShader(QSGRendererInterface::RenderMode)const{return new MultiplyShader;}
QColor rgba(const QVariant &value){
    const auto s=value.toString();
    if(s.size()==9 && s.startsWith('#'))return QColor(s.mid(1,2).toInt(nullptr,16),s.mid(3,2).toInt(nullptr,16),s.mid(5,2).toInt(nullptr,16),s.mid(7,2).toInt(nullptr,16));
    const auto color=value.value<QColor>();return color.isValid()?color:QColor(232,188,85,82);
}
QPointF point(const QVariantMap &p){return {p.value(QStringLiteral("x")).toDouble(),p.value(QStringLiteral("y")).toDouble()};}
QRectF rectangle(const QVariantMap &r){return {r.value(QStringLiteral("x")).toDouble(),r.value(QStringLiteral("y")).toDouble(),r.value(QStringLiteral("width")).toDouble(),r.value(QStringLiteral("height")).toDouble()};}
void quad(QVector<QPointF> &vertices,const QRectF &r){vertices<<r.topLeft()<<r.topRight()<<r.bottomLeft()<<r.bottomLeft()<<r.topRight()<<r.bottomRight();}
void stroke(QVector<QPointF>&vertices,const QList<QPointF>&points,double width){
    for(qsizetype i=1;i<points.size();++i){
        const auto a=points.at(i-1),b=points.at(i),delta=b-a;
        const double length=std::hypot(delta.x(),delta.y());if(length<0.001)continue;
        const QPointF n(-delta.y()/length*width/2,delta.x()/length*width/2);
        vertices<<a+n<<a-n<<b+n<<b+n<<a-n<<b-n;
    }
}
void append(QSGNode *root,const QVector<QPointF>&vertices,const QColor &color,bool multiply,double zoom,QQuickWindow *window,const QRectF &bounds){
    if(vertices.isEmpty())return;
    if(window->rendererInterface()->graphicsApi()==QSGRendererInterface::Software){
        auto *node=new SoftwareNode;node->window=window;node->bounds=bounds;node->color=color;node->multiply=multiply;
        for(const auto &p:vertices)node->vertices.append(p*zoom);
        root->appendChildNode(node);return;
    }
    auto *geometry=new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(),int(vertices.size()));
    geometry->setDrawingMode(QSGGeometry::DrawTriangles);
    auto *data=geometry->vertexDataAsPoint2D();
    for(qsizetype i=0;i<vertices.size();++i)data[i].set(float(vertices.at(i).x()*zoom),float(vertices.at(i).y()*zoom));
    auto *node=new QSGGeometryNode;node->setGeometry(geometry);node->setFlag(QSGNode::OwnsGeometry,true);
    if(multiply){
        // PDF opacity is mixed in its stored sRGB colour space before multiplication.
        const double a=color.alphaF();
        node->setMaterial(new MultiplyMaterial(QColor::fromRgbF(1+(color.redF()-1)*a,1+(color.greenF()-1)*a,1+(color.blueF()-1)*a)));
    }else{auto *material=new QSGFlatColorMaterial;material->setColor(color);node->setMaterial(material);}
    node->setFlag(QSGNode::OwnsMaterial,true);root->appendChildNode(node);
}
}
PageItem *AnnotationOverlay::paperMap()const{return m_paperMap;}
void AnnotationOverlay::setPaperMap(PageItem *page) {
    if(m_paperMap==page)return;
    for(const auto &connection:m_paperConnections)QObject::disconnect(connection);m_paperConnections.clear();m_paperMap=page;
    if(page) {
        m_paperConnections.append(connect(page,&PageItem::paperGeometryChanged,this,[this]{update();}));
        m_paperConnections.append(connect(page,&QObject::destroyed,this,[this]{++m_contentEpoch;update();emit paperMapChanged();}));
    }
    ++m_contentEpoch;update();emit paperMapChanged();
}
QSGNode *AnnotationOverlay::updatePaintNode(QSGNode *old,UpdatePaintNodeData *){
    auto *root=static_cast<AnnotationScene *>(old);
    if(width()<=0 || height()<=0 || !std::isfinite(m_zoom) || m_zoom<=0){delete root;return nullptr;}
    const auto layout=m_paperMap?m_paperMap->paperLayout():std::optional<LyraReaderPaperLayout>{};
    double originalHeight=height(),split=0,gap=0;bool torn=false;
    if(layout) {
        const LyraReaderPaperQuad input{{0,0,width()/m_zoom,layout->height},{0,0,1,1}};
        LyraReaderPaperQuadPair output{};LyraReaderBuffer error{};
        if(!lyra_reader_desktop_paper_quads(*layout,&input,1,&output,&error)) {
            qWarning("Paper annotation geometry could not be mapped.");lyra_reader_desktop_buffer_free(error);delete root;return nullptr;
        }
        originalHeight=layout->height*m_zoom;torn=output.count==2;
        if(torn){split=output.pieces[0].target.height*m_zoom;gap=layout->gap*m_zoom;}
    }
    const auto shiftLower=[&] {
        if(root->lower){QMatrix4x4 move;move.translate(0,float(gap));root->lower->setMatrix(move);}
    };
    if(root && root->contentEpoch==m_contentEpoch && root->width==width()
            && root->paperHeight==originalHeight && root->split==split && root->torn==torn) {
        // Gap-only animation keeps every triangle/material. Native clips and one transform
        // move them; no vertex rebuild, source query, tile plan or raster request is involved.
        shiftLower();return root;
    }
    delete root;root=new AnnotationScene;
    root->contentEpoch=m_contentEpoch;root->width=width();root->paperHeight=originalHeight;root->split=split;root->torn=torn;
    if(torn) {
        auto *upper=paperClip(QRectF(0,0,width(),split));
        // Explicit transform roots also preserve software sibling clips and parent offsets.
        auto *upperRoot=new QSGTransformNode;upperRoot->appendChildNode(upper);root->appendChildNode(upperRoot);root->upper=upper;
        root->lower=new QSGTransformNode;auto *lower=paperClip(QRectF(0,split,width(),originalHeight-split));
        root->lower->appendChildNode(lower);root->appendChildNode(root->lower);shiftLower();
    }else root->upper=root;
    ++m_geometryBuilds;QMetaObject::invokeMethod(this,[this]{emit geometryRebuilt();},Qt::QueuedConnection);
    const auto draw=[&](const QVector<QPointF> &vertices,const QColor &color,bool multiply) {
        const QRectF bounds(0,0,width(),originalHeight);
        append(root->upper,vertices,color,multiply,m_zoom,window(),bounds);
        if(root->lower)append(root->lower->firstChild(),vertices,color,multiply,m_zoom,window(),bounds);
    };
    for(const auto &entry:m_annotations){
        const auto a=entry.toMap();if(a.value(QStringLiteral("visible"),true).toBool()==false)continue;
        const auto kind=a.value(QStringLiteral("kind")).toString();
        const auto color=PaperAppearance::displayColor(rgba(a.value(QStringLiteral("color"))),PaperAppearance::mode(m_paperAppearance));
        const double width=qMax(0.5,a.value(QStringLiteral("strokeWidth"),2.0).toDouble());
        QVector<QPointF> vertices;
        bool multiply=false;
        QRectF bounds=rectangle(a.value(QStringLiteral("rect")).toMap());
        if(kind==QStringLiteral("highlight")||kind==QStringLiteral("underline")||kind==QStringLiteral("strikeout")){
            multiply=a.value(QStringLiteral("blend"),QStringLiteral("multiply")).toString()==QStringLiteral("multiply");
            for(const auto &q:a.value(QStringLiteral("quads")).toList()){
                auto r=rectangle(q.toMap());bounds=bounds.isEmpty()?r:bounds.united(r);
                if(kind==QStringLiteral("underline")){r.setTop(r.bottom()-qMax(0.8,r.height()*0.055));}
                else if(kind==QStringLiteral("strikeout")){const double y=r.center().y();r.setTop(y-0.45);r.setBottom(y+0.45);}
                quad(vertices,r);
            }
        }else if(kind==QStringLiteral("ink")){
            for(const auto &path:a.value(QStringLiteral("paths")).toList()){
                QList<QPointF> points;for(const auto &p:path.toList()){const auto v=point(p.toMap());points<<v;bounds=bounds.isEmpty()?QRectF(v,QSizeF(0.01,0.01)):bounds.united(QRectF(v,QSizeF(0.01,0.01)));}
                stroke(vertices,points,width);
            }
        }else if(kind==QStringLiteral("line")||kind==QStringLiteral("arrow")){
            const auto start=point(a.value(QStringLiteral("lineStart")).toMap()),end=point(a.value(QStringLiteral("lineEnd")).toMap());
            stroke(vertices,{start,end},width);bounds=QRectF(start,end).normalized();
            if(kind==QStringLiteral("arrow")){
                const auto d=end-start;const double l=std::hypot(d.x(),d.y());
                if(l>0){const QPointF u=d/l,n(-u.y(),u.x());const double size=qMax(7.0,width*3);stroke(vertices,{end-u*size+n*size*.45,end,end-u*size-n*size*.45},width);}
            }
        }else if(kind==QStringLiteral("square"))stroke(vertices,{bounds.topLeft(),bounds.topRight(),bounds.bottomRight(),bounds.bottomLeft(),bounds.topLeft()},width);
        else if(kind==QStringLiteral("circle")){
            QList<QPointF> points;for(int i=0;i<=64;++i){const double angle=double(i)/64*6.283185307179586;points<<bounds.center()+QPointF(std::cos(angle)*bounds.width()/2,std::sin(angle)*bounds.height()/2);}
            stroke(vertices,points,width);
        }
        draw(vertices,color,multiply);
        if(a.value(QStringLiteral("id")).toString()==m_selected && !bounds.isEmpty()){
            QVector<QPointF> frame;const auto r=bounds.adjusted(-2,-2,2,2);
            stroke(frame,{r.topLeft(),r.topRight(),r.bottomRight(),r.bottomLeft(),r.topLeft()},1.0/m_zoom);
            draw(frame,QColor(154,106,25),false);
        }
    }
    return root;
}
