#pragma once
#include <QObject>
#include <QVariantMap>

// Global metadata-only audit I/O. It never opens a PDF or prepares/sends an AI request.
class AuditController:public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    explicit AuditController(QObject *parent=nullptr):QObject(parent){}
    QVariantMap state()const{return m_state;}
    bool busy()const{return m_busy;}
    QString error()const{return m_error;}
    Q_INVOKABLE void reload();
    Q_INVOKABLE bool clear(const QString &fingerprint);
    Q_INVOKABLE QString metadata()const{return m_metadata;}
signals:
    void changed();
private:
    void request(const QString &operation,const QString &fingerprint={});
    QVariantMap m_state;
    bool m_busy=false;
    QString m_error,m_metadata;
};
