#pragma once
#include <QObject>
#include <QPointer>
#include <QWindow>
#include <QScreen>

// PDF points are 1/72 inch; Qt window coordinates already account for DPR.
class DisplayCalibration : public QObject {
    Q_OBJECT
    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(double factor READ factor NOTIFY calibrationChanged)
    Q_PROPERTY(QString fallbackReason READ fallbackReason NOTIFY calibrationChanged)
public:
    struct Result { double factor = 1; QString fallbackReason; };
    explicit DisplayCalibration(QObject *parent = nullptr) : QObject(parent) {}
    QWindow *window() const { return m_window; }
    void setWindow(QWindow *window);
    double factor() const { return m_result.factor; }
    QString fallbackReason() const { return m_result.fallbackReason; }
    static Result resolve(double logicalWidth, double physicalWidthMm);
signals:
    void windowChanged();
    void calibrationChanged();
private:
    void bindScreen(QScreen *screen);
    void refresh();
    QPointer<QWindow> m_window;
    QPointer<QScreen> m_screen;
    Result m_result;
};
