#include "WindowGeometryActivity.h"

WindowGeometryActivity::WindowGeometryActivity(QObject *parent)
    : QObject(parent), m_settle(this) {
    m_settle.setSingleShot(true);
    m_settle.setInterval(150);
    connect(&m_settle, &QTimer::timeout, this, [this] { setActive(false); });
}

void WindowGeometryActivity::setWindow(QWindow *window) {
    if (m_window == window) return;
    if (m_window) disconnect(m_window, nullptr, this, nullptr);
    m_settle.stop();
    m_window = window;
    m_lastSize = window ? window->size() : QSize{};
    if (window) {
        connect(window, &QWindow::widthChanged, this, &WindowGeometryActivity::sizeChanged);
        connect(window, &QWindow::heightChanged, this, &WindowGeometryActivity::sizeChanged);
        connect(window, &QObject::destroyed, this, [this] {
            m_settle.stop();
            m_window.clear();
            m_lastSize = {};
            QPointer<WindowGeometryActivity> alive(this);
            setActive(false);
            if (alive) emit windowChanged();
        });
    }
    // Wire the new target before notifying consumers, which can resize it
    // synchronously in response to an activity change.
    QPointer<WindowGeometryActivity> alive(this);
    setActive(false);
    if (alive) emit windowChanged();
}

void WindowGeometryActivity::sizeChanged() {
    if (!m_window || m_window->size() == m_lastSize) return;
    m_lastSize = m_window->size();
    m_settle.start();
    // A consumer can rebind/destroy the window while handling this signal.
    // Its cleanup must stop the timer we have already started.
    setActive(true);
}

void WindowGeometryActivity::setActive(bool active) {
    if (m_active == active) return;
    m_active = active;
    emit activeChanged();
}
