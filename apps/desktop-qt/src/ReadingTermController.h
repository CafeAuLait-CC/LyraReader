#pragma once
#include "lyra_reader_desktop.h"
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>
#include <memory>
class ReaderController;

// Ephemeral presentation only; the native handle owns the frozen revision and transport.
class ReadingTermController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
public:
    explicit ReadingTermController(ReaderController *owner);
    ~ReadingTermController() override;
    QVariantMap state()const{return m_state;}
    Q_INVOKABLE bool prepare(const QVariantMap &request);
    bool canStart(const QVariantMap &expectedPlan)const;
    bool start(const QString &credential,const QVariantMap &expectedPlan);
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void dismiss();
signals:
    void changed();
private:
    bool current(quint64 epoch)const;
    void poll();
    void observe(const QVariantMap &result);
    void fail(const QString &message);
    QPointer<ReaderController> m_owner;
    std::weak_ptr<LyraReaderDesktopDocument> m_document;
    std::shared_ptr<LyraReaderDesktopTerm> m_handle;
    QVariantMap m_state;
    QTimer m_poll;
    quint64 m_epoch=0,m_generation=0;
    int m_part=-1;
    bool m_polling=false,m_terminal=false;
};
