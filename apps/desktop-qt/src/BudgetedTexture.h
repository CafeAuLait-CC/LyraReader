#pragma once
#include "RenderBudget.h"
#include "PaperAppearance.h"
#include <QSGTransformNode>
#include <array>
class QQuickWindow;
class QQuickItem;

// Render-thread object. The source lease covers upload staging until the node
// dies; the texture lease is released only after destroying the owned texture.
class BudgetedTexture final:public QSGTransformNode {
public:
    explicit BudgetedTexture(QQuickItem *owner):m_owner(owner){}
    ~BudgetedTexture()override;
    bool setImage(QQuickWindow *window,const ResidentImage &image,int appearance);
    void setRect(const QRectF &target,const QRectF &source=QRectF(0,0,1,1));
    bool setRects(const PaperAppearance::Quad *quads,int count);
    bool empty()const{return !m_child;}
    void setTraceSource(const QString &source){m_traceSource=source;}
    const QString &traceSource()const{return m_traceSource;}
    int traceQuadCount()const{return m_quadCount;}
    const std::array<PaperAppearance::Quad,2> &traceQuads()const{return m_quads;}
    // Admission of the last requested image/rect update, not a GPU completion fence.
    bool traceUpdateCurrent()const{return m_traceCurrent;}
private:
    void clear();
    QQuickItem *m_owner;
    QMetaObject::Connection m_stopConnection;
    ResidentImage m_source;
    RenderBudget::Lease m_texture;
    QSGNode *m_child=nullptr;
    bool m_software=false;
    int m_appearance=-1;
    // Mirror only successfully committed rects. Failed admission keeps the previous source.
    std::array<PaperAppearance::Quad,2> m_quads;
    int m_quadCount=0;
    QString m_traceSource;
    bool m_traceCurrent=false;
};
