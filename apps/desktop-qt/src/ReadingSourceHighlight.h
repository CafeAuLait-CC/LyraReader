#pragma once
#include "NativeRaster.h"
#include "ReaderController.h"
#include <QElapsedTimer>
#include <QPointer>
#include <QTimer>
#include <optional>

// Ephemeral native presentation. Matching stays in the shared Rust engine, on
// an immutable working revision; this object never changes PDF/AI/cache state.
class ReadingSourceHighlight : public QObject {
    Q_OBJECT
    Q_PROPERTY(ReaderController *reader READ reader WRITE setReader NOTIFY readerChanged)
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
public:
    explicit ReadingSourceHighlight(QObject *parent = nullptr);
    ~ReadingSourceHighlight() override;
    ReaderController *reader() const { return m_reader; }
    void setReader(ReaderController *reader);
    QVariantMap state() const { return m_state; }
    Q_INVOKABLE void locate(int page, const QString &text);
    Q_INVOKABLE void show(int page, const QVariantList &rects);
    Q_INVOKABLE void cancelLookup();
    Q_INVOKABLE void clear();
signals:
    void readerChanged();
    void stateChanged();
    void revealed(int page, double y);
    void failed(const QString &message);
private:
    struct Request {
        quint64 epoch;
        QPointer<ReaderController> reader;
        qulonglong generation;
        std::shared_ptr<NativeRasterSource> source;
        int page;
        QString text;
    };
    bool reset();
    bool clearFlash();
    bool ready(int page) const;
    void startPending();
    void present(int page, const QVariantList &rects);
    void advance();
    QPointer<ReaderController> m_reader;
    QMetaObject::Connection m_documentConnection, m_destroyedConnection;
    QVariantMap m_state;
    QTimer m_timer;
    QElapsedTimer m_clock;
    quint64 m_epoch = 0;
    qulonglong m_generation = 0;
    std::weak_ptr<NativeRasterSource> m_identity;
    NativeRasterSource::Cancellation m_cancel;
    std::optional<Request> m_pending;
    bool m_running = false;
};
