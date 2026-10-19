#pragma once
#include <QQuickItem>
#include <QVariantList>

// Geometry stays in PDF view points. Qt owns the backend-specific GPU nodes and clipping.
class AnnotationOverlay : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QVariantList annotations READ annotations WRITE setAnnotations NOTIFY annotationsChanged)
    Q_PROPERTY(double zoom READ zoom WRITE setZoom NOTIFY zoomChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY paperAppearanceChanged)
    Q_PROPERTY(QString selectedId READ selectedId WRITE setSelectedId NOTIFY selectedIdChanged)
public:
    explicit AnnotationOverlay(QQuickItem *parent=nullptr):QQuickItem(parent){setFlag(ItemHasContents,true);}
    QVariantList annotations()const{return m_annotations;}
    double zoom()const{return m_zoom;}
    QString paperAppearance()const{return m_paperAppearance;}
    void setPaperAppearance(const QString &mode){if(m_paperAppearance==mode)return;m_paperAppearance=mode;update();emit paperAppearanceChanged();}
    QString selectedId()const{return m_selected;}
    void setAnnotations(const QVariantList &annotations){m_annotations=annotations;update();emit annotationsChanged();}
    void setZoom(double zoom){if(qFuzzyCompare(m_zoom,zoom))return;m_zoom=zoom;update();emit zoomChanged();}
    void setSelectedId(const QString &id){if(m_selected==id)return;m_selected=id;update();emit selectedIdChanged();}
signals:
    void annotationsChanged();void zoomChanged();void selectedIdChanged();void paperAppearanceChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *,UpdatePaintNodeData *)override;
private:
    QVariantList m_annotations;
    double m_zoom=1;
    QString m_selected;
    QString m_paperAppearance=QStringLiteral("original");
};
