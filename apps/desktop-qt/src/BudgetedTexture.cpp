#include "BudgetedTexture.h"
#include "PaperAppearance.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <QQuickItem>

void BudgetedTexture::clear(){if(m_child){removeChildNode(m_child);delete m_child;m_child=nullptr;}m_texture.reset();m_source={};}
BudgetedTexture::~BudgetedTexture(){QObject::disconnect(m_stopConnection);clear();}
bool BudgetedTexture::setImage(QQuickWindow *window,const ResidentImage &image,int appearance) {
    if(image.isNull())return false;
    if(!m_stopConnection)m_stopConnection=QObject::connect(window,&QQuickWindow::sceneGraphAboutToStop,m_owner,[this] {
        clear();QMetaObject::invokeMethod(m_owner,[owner=m_owner]{owner->update();},Qt::QueuedConnection);
    },Qt::DirectConnection);
    const bool software=window->rendererInterface()->graphicsApi()==QSGRendererInterface::Software;
    if(m_child && m_source.pixels.cacheKey()==image.pixels.cacheKey() && (!software || m_appearance==appearance)) {
        m_appearance=appearance;return true;
    }
    auto lease=RenderBudget::reserve(RenderBudget::Kind::Texture,qint64(image.pixels.width())*image.pixels.height()*4);
    if(!lease)return false;
    QSGNode *replacement=nullptr;
    if(software) {
        auto *node=window->createImageNode();
        if(node) {
            auto *texture=window->createTextureFromImage(PaperAppearance::displayImage(image.pixels,appearance));
            if(texture){node->setTexture(texture);node->setOwnsTexture(true);node->setFiltering(QSGTexture::Linear);replacement=node;}
            else delete node;
        }
    }else replacement=PaperAppearance::createNode(window,image.pixels,appearance);
    if(!replacement)return false;
    if(m_child){removeChildNode(m_child);delete m_child;}
    m_texture=std::move(lease);m_source=image;m_child=replacement;m_appearance=appearance;m_software=software;
    appendChildNode(m_child);return true;
}
void BudgetedTexture::setRect(const QRectF &target,const QRectF &source) {
    if(!m_child)return;
    if(m_software) {
        auto *node=static_cast<QSGImageNode *>(m_child);const auto &image=m_source.pixels;
        node->setRect(target);node->setSourceRect(QRectF(source.x()*image.width(),source.y()*image.height(),source.width()*image.width(),source.height()*image.height()));
    }else PaperAppearance::updateNode(m_child,target,m_appearance,source);
}
