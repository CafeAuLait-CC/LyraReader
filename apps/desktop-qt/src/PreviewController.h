#pragma once
#include "ReaderController.h"
#include "NativeRaster.h"
#include <QPointer>
#include <QRectF>

// One movable preview per reader window. Parsing/raster work uses an immutable document snapshot.
class PreviewController : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool visible READ visible NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(bool pinned READ pinned NOTIFY changed)
    Q_PROPERTY(QVariantMap model READ model NOTIFY changed)
    Q_PROPERTY(QRectF anchor READ anchor NOTIFY changed)
public:
    explicit PreviewController(QObject *parent=nullptr) : QObject(parent) {}
    ~PreviewController() override;
    bool visible() const { return !m_model.isEmpty(); }
    bool loading() const { return m_loading; }
    bool pinned() const { return m_pinned; }
    QVariantMap model() const { return m_model; }
    QRectF anchor() const { return m_anchor; }
    Q_INVOKABLE void openAt(ReaderController *reader,int page,double x,double y,double sceneX,double sceneY,double zoom);
    Q_INVOKABLE void close();
    Q_INVOKABLE void togglePin();
    Q_INVOKABLE void showEntry(int index);
    Q_INVOKABLE void showFullPage();
    Q_INVOKABLE void showText();
    Q_INVOKABLE QVariantList imageSegments(double width,double deviceScale,const QString &paper) const;
    Q_INVOKABLE QUrl imageUrl(double width,double deviceScale,const QString &paper) const;
    Q_INVOKABLE void jump();
    Q_INVOKABLE void openWindow();
signals:
    void changed();
    void statusMessage(const QString &message);
    void navigateRequested(int page,double y);
    void newWindowRequested(const QUrl &url,int page);
    void externalRequested(const QUrl &url);
private:
    void imageRegion(int page,const QVariantMap &region,const QVariantList &fragments = {});
    quint64 m_epoch=0;
    bool m_loading=false,m_pinned=false;
    QVariantMap m_model,m_textModel;
    QVariantList m_sizes;
    QRectF m_anchor;
    QUrl m_url;
    QPointer<ReaderController> m_reader;
    QMetaObject::Connection m_resetConnection;
    QString m_sourceKey;
    std::shared_ptr<NativeRasterSource> m_source;
};
