#pragma once
#include <QQuickItem>
#include <QVariantList>
#include <QPointer>
#include <atomic>
class PageItem;
Q_MOC_INCLUDE("PageItem.h")

// Geometry stays in PDF view points. Qt owns the backend-specific GPU nodes and clipping.
class AnnotationOverlay : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QVariantList annotations READ annotations WRITE setAnnotations NOTIFY annotationsChanged)
    Q_PROPERTY(double zoom READ zoom WRITE setZoom NOTIFY zoomChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY paperAppearanceChanged)
    Q_PROPERTY(QString selectedId READ selectedId WRITE setSelectedId NOTIFY selectedIdChanged)
    Q_PROPERTY(PageItem *paperMap READ paperMap WRITE setPaperMap NOTIFY paperMapChanged)
    Q_PROPERTY(qulonglong geometryBuildCount READ geometryBuildCount NOTIFY geometryRebuilt)
public:
    explicit AnnotationOverlay(QQuickItem *parent=nullptr):QQuickItem(parent){setFlag(ItemHasContents,true);}
    QVariantList annotations()const{return m_annotations;}
    double zoom()const{return m_zoom;}
    QString paperAppearance()const{return m_paperAppearance;}
    void setPaperAppearance(const QString &mode){if(m_paperAppearance==mode)return;m_paperAppearance=mode;++m_contentEpoch;update();emit paperAppearanceChanged();}
    QString selectedId()const{return m_selected;}
    void setAnnotations(const QVariantList &annotations){m_annotations=annotations;++m_contentEpoch;update();emit annotationsChanged();}
    void setZoom(double zoom){if(qFuzzyCompare(m_zoom,zoom))return;m_zoom=zoom;++m_contentEpoch;update();emit zoomChanged();}
    void setSelectedId(const QString &id){if(m_selected==id)return;m_selected=id;++m_contentEpoch;update();emit selectedIdChanged();}
    PageItem *paperMap()const;
    void setPaperMap(PageItem *page);
    qulonglong geometryBuildCount()const{return m_geometryBuilds.load();}
signals:
    void annotationsChanged();void zoomChanged();void selectedIdChanged();void paperAppearanceChanged();
    void paperMapChanged();void geometryRebuilt();
protected:
    QSGNode *updatePaintNode(QSGNode *,UpdatePaintNodeData *)override;
private:
    QVariantList m_annotations;
    double m_zoom=1;
    QString m_selected;
    QString m_paperAppearance=QStringLiteral("original");
    QPointer<PageItem> m_paperMap;
    QVector<QMetaObject::Connection> m_paperConnections;
    quint64 m_contentEpoch=0;
    std::atomic<qulonglong> m_geometryBuilds{0};
};
