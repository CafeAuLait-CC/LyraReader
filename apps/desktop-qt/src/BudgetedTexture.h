#pragma once
#include "RenderBudget.h"
#include <QSGTransformNode>
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
    bool empty()const{return !m_child;}
private:
    void clear();
    QQuickItem *m_owner;
    QMetaObject::Connection m_stopConnection;
    ResidentImage m_source;
    RenderBudget::Lease m_texture;
    QSGNode *m_child=nullptr;
    bool m_software=false;
    int m_appearance=-1;
};
