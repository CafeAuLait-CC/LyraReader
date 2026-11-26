#pragma once
#include "ReaderController.h"
#include <QObject>
#include <QQuickItem>
#include <QPointer>
#include <QPointF>
#include <QTimer>
#include <QVector>

class ReaderController;
class QQuickItem;
class QQuickWindow;

// Ephemeral native presentation only; never part of a reading request or cache file.
class ReadingScrollMemory : public QObject {
    Q_OBJECT
    Q_PROPERTY(ReaderController *reader READ reader WRITE setReader NOTIFY readerChanged)
    Q_PROPERTY(QQuickItem *viewport READ viewport WRITE setViewport NOTIFY viewportChanged)
    Q_PROPERTY(QString key READ key WRITE setKey NOTIFY keyChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(bool ready READ ready WRITE setReady NOTIFY readyChanged)
public:
    explicit ReadingScrollMemory(QObject *parent = nullptr);
    ~ReadingScrollMemory() override;
    ReaderController *reader() const;
    QQuickItem *viewport() const;
    QString key() const { return m_key; }
    bool active() const { return m_active; }
    bool ready() const { return m_ready; }
    void setReader(ReaderController *);
    void setViewport(QQuickItem *);
    void setKey(const QString &);
    void setActive(bool);
    void setReady(bool);
    Q_INVOKABLE void userIntent();
    Q_INVOKABLE void capturePosition();
    Q_INVOKABLE void completeUserScroll();
    Q_INVOKABLE void resetPosition(ReaderController *expectedReader, qulonglong generation, const QString &key);
signals:
    void readerChanged();
    void viewportChanged();
    void keyChanged();
    void activeChanged();
    void readyChanged();
private slots:
    void geometryChanged();
    void positionChanged();
    void movementStarted() { userIntent(); }
private:
    struct Geometry { QPointF origin, position, offset, maximum; };
    bool eventFilter(QObject *, QEvent *) override;
    bool eligible(bool requireReady = true) const;
    bool geometry(Geometry &) const;
    void rebind();
    void update();
    void restore(bool clamp);
    void remember();
    void flush();
    void bindWindow();
    void trace(const char *) const;
    QPointer<ReaderController> m_reader, m_boundReader, m_inputReader;
    QPointer<QQuickItem> m_viewport, m_inputViewport;
    QPointer<QQuickWindow> m_window;
    QString m_key, m_boundKey, m_inputKey;
    quint64 m_generation = 0, m_epoch = 0, m_clampEpoch = 0;
    quint64 m_inputGeneration = 0;
    QPointF m_target, m_last;
    bool m_active = false, m_ready = true, m_restoring = true;
    bool m_lastValid = false, m_setting = false, m_userOverride = false;
    QTimer m_update, m_clamp;
    QVector<QMetaObject::Connection> m_readerConnections, m_viewConnections;
};
