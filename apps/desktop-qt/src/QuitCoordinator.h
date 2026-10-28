#pragma once
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QWindow>
#include "ReaderController.h"
class WorkspaceController;

// Application/window ownership only. PDF writing, draft retirement and recovery stay in Rust.
class QuitCoordinator : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString phase READ phase NOTIFY changed)
    Q_PROPERTY(QObject *owner READ owner NOTIFY changed)
    Q_PROPERTY(QVariantList documents READ documents NOTIFY changed)
    Q_PROPERTY(QString message READ message NOTIFY changed)
public:
    explicit QuitCoordinator(QObject *parent=nullptr);
    static QuitCoordinator *instance();
    bool busy()const{return m_phase!=QStringLiteral("idle");}
    QString phase()const{return m_phase;}
    QObject *owner()const;
    QVariantList documents()const;
    QString message()const{return m_message;}
    void request(WorkspaceController *owner);
    Q_INVOKABLE void decide(const QString &decision);
    Q_INVOKABLE void chooseCopy(const QUrl &destination);
    Q_INVOKABLE void cancel();
signals:
    void changed();
    void copyRequested(const QUrl &suggestion,const QString &title);
    void finished(bool accepted,const QString &error);
    void accepted();
protected:
    bool eventFilter(QObject *,QEvent *)override;
private:
    struct Window {
        QPointer<WorkspaceController> workspace;
        QPointer<QWindow> window;
        bool enabled=true;
        QList<QPointer<ReaderController>> readers;
    };
    struct Document {
        QPointer<ReaderController> reader;
        std::shared_ptr<LyraReaderDesktopDocument> handle;
        QUrl source,destination;
        QVariantMap drafts,notes;
        quint64 revision=0;
        bool copy=false;
        QString summary;
    };
    void advance();
    void collect();
    void askNextCopy();
    bool preflightCopies();
    bool unchanged(const Document &)const;
    void startCommand(Document &,const QString &operation);
    void finishCommand(quint64,const QString &,const QVariant &,const QString &);
    void abort(const QString &error);
    void finish();
    void restoreWindows();
    QPointer<WorkspaceController> m_owner;
    QList<Window> m_windows;
    QList<Document> m_documents;
    QTimer m_timer;
    QString m_phase=QStringLiteral("idle"),m_message,m_decision,m_operation;
    int m_index=0,m_copyIndex=0,m_completed=0;
    quint64 m_command=0;
    quint64 m_epoch=0;
    bool m_draining=false,m_accepting=false;
    QList<QMetaObject::Connection> m_connections;
};
