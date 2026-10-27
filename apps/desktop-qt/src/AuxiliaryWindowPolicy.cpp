#include "AuxiliaryWindowPolicy.h"
#include <QGuiApplication>
#include <QScreen>
#include <QTimer>
#include <cmath>

QSize AuxiliaryWindowPolicy::boundedSize(const QSizeF &requested,const QRect &available) {
    if(!available.isValid())return {};
    const auto limit=available.size()-QSize(qMin(32,available.width()-1),qMin(32,available.height()-1));
    auto dimension=[](double value,int fallback,int minimum,int maximum) {
        if(!std::isfinite(value) || value<=0 || value>32768)value=fallback;
        // Clamp before rounding/converting, including malformed saved local preferences.
        return qRound(qBound(double(qMin(minimum,maximum)),value,double(maximum)));
    };
    return {dimension(requested.width(),560,360,limit.width()),dimension(requested.height(),650,280,limit.height())};
}

bool AuxiliaryWindowPolicy::prepare(QWindow *window,QWindow *owner,const QVariantMap &saved,int width,int height) {
    if(!window || !owner || window==owner)return false;
    if(window->isVisible()){window->requestActivate();return true;}
    auto *screen=owner->screen();
    if(!screen || !screen->availableGeometry().isValid())return false;
    bool widthOk=false,heightOk=false;
    const double savedWidth=saved.value(QStringLiteral("width")).toDouble(&widthOk);
    const double savedHeight=saved.value(QStringLiteral("height")).toDouble(&heightOk);
    const auto size=boundedSize({widthOk ? savedWidth : double(width),heightOk ? savedHeight : double(height)},screen->availableGeometry());
    if(size.isEmpty())return false;
    disconnect(m_ownerVisibility);disconnect(m_ownerDestroyed);
    m_window=window;m_owner=owner;
    // Set the relationship and type before show/map, including on Wayland. No fixed size,
    // topmost/layer-shell hint or compositor-specific layout command is used.
    window->setFlags(Qt::Dialog|Qt::WindowTitleHint|Qt::WindowSystemMenuHint|Qt::WindowCloseButtonHint);
    window->setTransientParent(owner);
    window->setScreen(screen);
    window->setModality(Qt::NonModal);
    window->setMinimumSize({qMin(360,size.width()),qMin(280,size.height())});
    window->resize(size);
    if(!QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))) {
        const auto available=screen->availableGeometry();
        const auto centered=owner->geometry().center()-QPoint(size.width()/2,size.height()/2);
        bool xOk=false,yOk=false;
        const auto x=saved.value(QStringLiteral("x")).toDouble(&xOk),y=saved.value(QStringLiteral("y")).toDouble(&yOk);
        const auto bounded=[](double coordinate,int fallback,int low,int high,bool valid) {
            if(!valid || !std::isfinite(coordinate))coordinate=fallback;
            return qRound(qBound(double(low),coordinate,double(high)));
        };
        window->setPosition(bounded(x,centered.x(),available.left(),available.right()-size.width()+1,xOk),
                            bounded(y,centered.y(),available.top(),available.bottom()-size.height()+1,yOk));
    }
    m_ownerVisibility=connect(owner,&QWindow::visibleChanged,this,[this](bool visible){if(!visible && m_window)m_window->close();});
    m_ownerDestroyed=connect(owner,&QObject::destroyed,this,[this]{if(m_window)m_window->hide();});
    return true;
}

QVariantMap AuxiliaryWindowPolicy::geometry() const {
    if(!m_window)return {};
    QVariantMap value{{QStringLiteral("width"),m_window->width()},{QStringLiteral("height"),m_window->height()}};
    if(!QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))) {
        value.insert(QStringLiteral("x"),m_window->x());value.insert(QStringLiteral("y"),m_window->y());
    }
    return value;
}

void AuxiliaryWindowPolicy::returnFocus() {
    const auto owner=m_owner;
    QTimer::singleShot(0,this,[owner]{if(owner && owner->isVisible())owner->requestActivate();});
}
