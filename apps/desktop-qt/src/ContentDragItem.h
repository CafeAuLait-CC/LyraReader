#pragma once
#include "RenderBudget.h"
#include "RasterJobs.h"
#include <QQuickItem>
#include <QPointer>
#include <QTimer>
#include <QUrl>
class ReaderController;
class PageItem;
class NativeRasterSource;
Q_MOC_INCLUDE("ReaderController.h")
Q_MOC_INCLUDE("PageItem.h")

// One gesture owns one detached source and one bounded bitmap pair. Pointer motion
// only updates scene geometry; this item survives virtual page delegate replacement.
class ContentDragItem:public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(ReaderController *controller READ controller WRITE setController NOTIFY stateChanged)
    Q_PROPERTY(PageItem *paperMap READ paperMap WRITE setPaperMap NOTIFY mappingChanged)
    Q_PROPERTY(int page READ page NOTIFY stateChanged)
    Q_PROPERTY(bool active READ active NOTIFY stateChanged)
    Q_PROPERTY(bool holding READ holding NOTIFY stateChanged)
    Q_PROPERTY(int status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString error READ error NOTIFY stateChanged)
    Q_PROPERTY(QPointF offset READ offset WRITE setOffset NOTIFY offsetChanged)
    Q_PROPERTY(double zoom READ zoom WRITE setZoom NOTIFY mappingChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY mappingChanged)
    Q_PROPERTY(qulonglong requests READ requests NOTIFY stateChanged)
    Q_PROPERTY(qint64 residentBytes READ residentBytes NOTIFY stateChanged)
public:
    explicit ContentDragItem(QQuickItem *parent=nullptr);
    ~ContentDragItem()override;
    ReaderController *controller()const;void setController(ReaderController *value);
    PageItem *paperMap()const;void setPaperMap(PageItem *value);
    int page()const{return m_page;}bool active()const{return m_active;}bool holding()const{return m_commit!=0;}int status()const{return m_status;}
    QString error()const{return m_error;}QPointF offset()const{return m_offset;}void setOffset(const QPointF &value);
    double zoom()const{return m_zoom;}void setZoom(double value);
    QString paperAppearance()const{return m_paper;}void setPaperAppearance(const QString &value);
    qulonglong requests()const{return m_requests;}
    qint64 residentBytes()const{return m_background.pixels.sizeInBytes()+m_foreground.pixels.sizeInBytes();}
    Q_INVOKABLE void prepare(int page,const QString &target,const QString &revision,const QRectF &bounds);
    Q_INVOKABLE void attachOwner(QObject *owner){if(owner && owner!=this)QObject::setParent(owner);}
    Q_INVOKABLE void hold(qulonglong command);
    Q_INVOKABLE void cancel();
signals:
    void stateChanged();void mappingChanged();void offsetChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *,UpdatePaintNodeData *)override;
    void itemChange(ItemChange,const ItemChangeData &)override;
private:
    void fail(const QString &message);void finishWhenPainted();void windowVisibilityChanged();
    QPointer<ReaderController> m_controller;QPointer<PageItem> m_map;
    QVector<QMetaObject::Connection> m_connections,m_mapConnections;
    QVector<QMetaObject::Connection> m_windowConnections;
    QUrl m_ownerUrl;
    std::shared_ptr<NativeRasterSource> m_source;
    ResidentImage m_background,m_foreground;
    RasterJobs::Handle m_job;
    QRectF m_region;QPointF m_offset;
    double m_zoom=1;QString m_paper=QStringLiteral("original"),m_error;
    quint64 m_epoch=0,m_generation=0,m_requests=0,m_commit=0;
    int m_page=-1,m_status=0;bool m_active=false,m_committed=false;
    QTimer m_textureRetry;
};
