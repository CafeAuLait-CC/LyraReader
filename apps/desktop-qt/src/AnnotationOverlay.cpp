#include "AnnotationOverlay.h"
#include "PaperAppearance.h"
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
class SoftwareNode final:public QSGRenderNode {
public:
    QQuickWindow *window=nullptr;
    QRectF bounds;
    QVector<QPointF> vertices;
    QColor color;
    bool multiply=false;
    // Multiply reads the backdrop. Qt's partial software updates can otherwise
    // composite it onto an already tinted backing store on successive frames.
    // Full redraw is confined to the software fallback; RHI uses its native blend.
    RenderingFlags flags()const override{return {};}
    QRectF rect()const override{return bounds;}
    void render(const RenderState *)override {
        auto *painter=static_cast<QPainter *>(window->rendererInterface()->getResource(window,QSGRendererInterface::PainterResource));
        if(!painter)return;
        painter->save();painter->setWorldTransform(matrix()->toTransform());painter->setClipRect(bounds,Qt::IntersectClip);
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
QSGNode *AnnotationOverlay::updatePaintNode(QSGNode *old,UpdatePaintNodeData *){
    delete old;
    auto *root=new QSGTransformNode;
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
        append(root,vertices,color,multiply,m_zoom,window(),boundingRect());
        if(a.value(QStringLiteral("id")).toString()==m_selected && !bounds.isEmpty()){
            QVector<QPointF> frame;const auto r=bounds.adjusted(-2,-2,2,2);
            stroke(frame,{r.topLeft(),r.topRight(),r.bottomRight(),r.bottomLeft(),r.topLeft()},1.0/m_zoom);
            append(root,frame,QColor(154,106,25),false,m_zoom,window(),boundingRect());
        }
    }
    return root;
}
