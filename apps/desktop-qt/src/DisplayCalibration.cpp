#include "DisplayCalibration.h"
#include <QDebug>
#include <QSignalBlocker>
#include <cmath>

DisplayCalibration::Result DisplayCalibration::resolve(double width, double mm) {
    if (!std::isfinite(width) || width <= 0)
        return {1, QStringLiteral("Display has no usable logical width")};
    if (!std::isfinite(mm) || mm < 25 || mm > 3000)
        return {1, QStringLiteral("Display physical width is missing or implausible")};
    const double factor = width / (mm / 25.4) / 72;
    if (!std::isfinite(factor) || factor < .25 || factor > 4)
        return {1, QStringLiteral("Display density is outside the supported calibration range")};
    return {factor, {}};
}
void DisplayCalibration::setWindow(QWindow *window) {
    if (m_window == window) return;
    if (m_window) disconnect(m_window, nullptr, this, nullptr);
    m_window = window;
    if (window) {
        connect(window, &QWindow::screenChanged, this, &DisplayCalibration::bindScreen);
        connect(window, &QObject::destroyed, this, [this] {
            // The QML window is already being destroyed. Reset the surviving helper without
            // calling handlers that could navigate or rasterize through its dying canvas.
            const QSignalBlocker blocker(this);
            bindScreen(nullptr);
        });
    }
    bindScreen(window ? window->screen() : nullptr);
    emit windowChanged();
}
void DisplayCalibration::bindScreen(QScreen *screen) {
    if (m_screen) disconnect(m_screen, nullptr, this, nullptr);
    m_screen = screen;
    if (screen) {
        connect(screen, &QScreen::geometryChanged, this, &DisplayCalibration::refresh);
        connect(screen, &QScreen::physicalSizeChanged, this, &DisplayCalibration::refresh);
        connect(screen, &QScreen::physicalDotsPerInchChanged, this, &DisplayCalibration::refresh);
        connect(screen, &QObject::destroyed, this, [this] { refresh(); });
    }
    refresh();
}
void DisplayCalibration::refresh() {
    const auto next = m_screen ? resolve(m_screen->geometry().width(), m_screen->physicalSize().width())
                               : Result{1, QStringLiteral("No display is attached to the window")};
    if (next.factor == m_result.factor && next.fallbackReason == m_result.fallbackReason) return;
    m_result = next;
    qInfo() << "lyra-reader-calibration:" << m_result.factor << m_result.fallbackReason;
    emit calibrationChanged();
}
