#include "BudgetedTexture.h"
#include "PaperAppearance.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <QQuickItem>

namespace {
// The software renderer needs one image node per rect, but both borrow exactly one texture.
// Destroy every borrowing node before its texture, and keep the existing one payload lease.
// An explicit transform root preserves the parent's offset for both software image siblings.
class SoftwarePaperNode final:public QSGTransformNode {
public:
    SoftwarePaperNode(QQuickWindow *window,QSGImageNode *first,QSGTexture *texture)
        :m_window(window),m_texture(texture),m_first(first) {
        configure(first);appendChildNode(first);
    }
    ~SoftwarePaperNode()override {
        while(auto *child=firstChild()){removeChildNode(child);delete child;}
        delete m_texture;
    }
    bool setRects(const PaperAppearance::Quad *quads,int count,const QSize &pixels) {
        if(count==2 && !m_second) {
            m_second=m_window->createImageNode();if(!m_second)return false;
            configure(m_second);appendChildNode(m_second);
        }else if(count==1 && m_second){removeChildNode(m_second);delete m_second;m_second=nullptr;}
        for(int i=0;i<count;++i) {
            auto *node=i?m_second:m_first;const auto &r=quads[i].source;
            node->setRect(quads[i].target);
            node->setSourceRect(QRectF(r.x()*pixels.width(),r.y()*pixels.height(),r.width()*pixels.width(),r.height()*pixels.height()));
        }
        return true;
    }
private:
    void configure(QSGImageNode *node){node->setTexture(m_texture);node->setOwnsTexture(false);node->setFiltering(QSGTexture::Linear);}
    QQuickWindow *m_window;
    QSGTexture *m_texture;
    QSGImageNode *m_first,*m_second=nullptr;
};
}

void BudgetedTexture::clear(){if(m_child){removeChildNode(m_child);delete m_child;m_child=nullptr;}m_texture.reset();m_source={};m_quadCount=0;m_traceSource.clear();m_traceCurrent=false;}
BudgetedTexture::~BudgetedTexture(){QObject::disconnect(m_stopConnection);clear();}
bool BudgetedTexture::setImage(QQuickWindow *window,const ResidentImage &image,int appearance) {
    m_traceCurrent=false;
    if(image.isNull())return false;
    if(!m_stopConnection)m_stopConnection=QObject::connect(window,&QQuickWindow::sceneGraphAboutToStop,m_owner,[this] {
        clear();QMetaObject::invokeMethod(m_owner,[owner=m_owner]{owner->update();},Qt::QueuedConnection);
    },Qt::DirectConnection);
    const bool software=window->rendererInterface()->graphicsApi()==QSGRendererInterface::Software;
    if(m_child && m_source.pixels.cacheKey()==image.pixels.cacheKey() && (!software || m_appearance==appearance)) {
        m_appearance=appearance;m_traceCurrent=true;return true;
    }
    auto lease=RenderBudget::reserve(RenderBudget::Kind::Texture,qint64(image.pixels.width())*image.pixels.height()*4);
    if(!lease)return false;
    QSGNode *replacement=nullptr;
    if(software) {
        auto *node=window->createImageNode();
        if(node) {
            auto *texture=window->createTextureFromImage(PaperAppearance::displayImage(image.pixels,appearance));
            if(texture)replacement=new SoftwarePaperNode(window,node,texture);
            else delete node;
        }
    }else replacement=PaperAppearance::createNode(window,image.pixels,appearance);
    if(!replacement)return false;
    if(m_child){removeChildNode(m_child);delete m_child;}
    m_texture=std::move(lease);m_source=image;m_child=replacement;m_appearance=appearance;m_software=software;m_quadCount=0;m_traceSource.clear();
    appendChildNode(m_child);m_traceCurrent=true;return true;
}
void BudgetedTexture::setRect(const QRectF &target,const QRectF &source) {
    const PaperAppearance::Quad quad{target,source};setRects(&quad,1);
}
bool BudgetedTexture::setRects(const PaperAppearance::Quad *quads,int count) {
    if(!m_child || !quads || (count!=1 && count!=2)){m_traceCurrent=false;return false;}
    if(m_software && !static_cast<SoftwarePaperNode *>(m_child)->setRects(quads,count,m_source.pixels.size())){m_traceCurrent=false;return false;}
    if(!m_software)PaperAppearance::updateNodeQuads(m_child,quads,count,m_appearance);
    for(int i=0;i<count;++i)m_quads[i]=quads[i];m_quadCount=count;return true;
}
