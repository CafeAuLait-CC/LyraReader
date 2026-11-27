#pragma once
#include <QObject>
#include <QPointer>
#include <QSize>
#include <QTimer>
#include <QWindow>

// Portable logical-size activity, not an assertion that the OS is in a
// pointer-driven live resize. Native timers also settle hidden windows.
class WindowGeometryActivity : public QObject {
    Q_OBJECT
    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
public:
    explicit WindowGeometryActivity(QObject *parent = nullptr);
    QWindow *window() const { return m_window.data(); }
    void setWindow(QWindow *window);
    bool active() const { return m_active; }
signals:
    void windowChanged();
    void activeChanged();
private:
    void sizeChanged();
    void setActive(bool active);
    QPointer<QWindow> m_window;
    QSize m_lastSize;
    QTimer m_settle;
    bool m_active = false;
};
