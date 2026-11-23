#include "AuxiliaryWindowPolicy.h"
#include <QGuiApplication>
#include <QScreen>
#include <QTimer>
#include <cmath>

namespace {
bool isWayland() {
    return QGuiApplication::platformName().startsWith(QStringLiteral("wayland"));
}

QSize preferredSize(const QSizeF &requested) {
    const auto dimension=[](double value,int fallback,int minimum) {
        if(!std::isfinite(value) || value<=0 || value>32768)value=fallback;
        // Validate saved preferences before converting to logical pixels.
        return qRound(qMax(double(minimum),value));
    };
    return {dimension(requested.width(),560,360),dimension(requested.height(),650,280)};
}

QSize fitToAvailable(QSize size,const QRect &available) {
    if(!available.isValid())return {};
    const auto limit=available.size()-QSize(qMin(32,available.width()-1),qMin(32,available.height()-1));
    return size.boundedTo(limit);
}
}

void AuxiliaryWindowOwner::setWindow(QQuickWindow *window) {
    if(window==m_window)return;
    disconnect(m_visibility);
    m_window=window;
    if(window && isWayland())
        m_visibility=connect(window,&QWindow::visibleChanged,this,[this]{observeFirstFrame();});
    observeFirstFrame();
    emit windowChanged();
}

void AuxiliaryWindowOwner::observeFirstFrame() {
    const auto observation=++m_observation;
    disconnect(m_frame);
    m_frame={};
    m_hasSubmittedFrame=false;
    if(!isWayland() || !m_window || !m_window->isVisible())return;
    m_frame=connect(m_window,&QQuickWindow::frameSwapped,this,[this,observation] {
        if(observation!=m_observation || !m_window || !m_window->isVisible())return;
        disconnect(m_frame);
        m_frame={};
        m_hasSubmittedFrame=true;
        emit firstFrameSubmitted();
    },Qt::QueuedConnection);
}

QSize AuxiliaryWindowPolicy::boundedSize(const QSizeF &requested,const QRect &available) {
    return fitToAvailable(preferredSize(requested),available);
}

bool AuxiliaryWindowPolicy::prepare(QWindow *window,QWindow *owner,const QVariantMap &saved,int width,int height) {
    if(!window || !owner || window==owner)return false;
    if(window->isVisible()){window->requestActivate();return true;}
    auto *screen=owner->screen();
    if(!screen || !screen->availableGeometry().isValid())return false;
    bool widthOk=false,heightOk=false;
    const double savedWidth=saved.value(QStringLiteral("width")).toDouble(&widthOk);
    const double savedHeight=saved.value(QStringLiteral("height")).toDouble(&heightOk);
    const auto preference=preferredSize({widthOk ? savedWidth : double(width),heightOk ? savedHeight : double(height)});
    const auto size=fitToAvailable(preference,screen->availableGeometry());
    if(size.isEmpty())return false;
    cancelPresentation();
    disconnect(m_ownerVisibility);disconnect(m_ownerDestroyed);
    m_window=window;m_owner=owner;
    m_preferredSize=preference;
    m_initialSize=size;
    // Set the relationship and type before show/map, including on Wayland. No fixed size,
    // topmost/layer-shell hint or compositor-specific layout command is used.
    window->setFlags(Qt::Dialog|Qt::WindowTitleHint|Qt::WindowSystemMenuHint|Qt::WindowCloseButtonHint);
    window->setTransientParent(owner);
    window->setScreen(screen);
    window->setModality(Qt::NonModal);
    window->setMinimumSize({qMin(360,size.width()),qMin(280,size.height())});
    window->resize(size);
    if(!isWayland()) {
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
    m_ownerVisibility=connect(owner,&QWindow::visibleChanged,this,[this](bool visible) {
        if(visible)return;
        cancelPresentation();
        if(m_window)m_window->close();
    });
    m_ownerDestroyed=connect(owner,&QObject::destroyed,this,[this] {
        cancelPresentation();
        if(m_window)m_window->hide();
    });
    return true;
}

void AuxiliaryWindowPolicy::present(AuxiliaryWindowOwner *ownerFrames) {
    if(!m_window || !m_owner || !m_owner->isVisible() || m_ownerFrame)return;
    auto *owner=qobject_cast<QQuickWindow *>(m_owner.data());
    if(ownerFrames && ownerFrames->window()!=owner)ownerFrames=nullptr;
    if(m_window->isVisible() || !owner || !isWayland() || (ownerFrames && ownerFrames->hasSubmittedFrame())) {
        showPreparedWindow();
        return;
    }
    // xdg-shell treats a parent without a mapped buffer as unset. Queue the
    // auxiliary show after Qt submits an owner frame, on the owner's connection.
    const auto presentation=++m_presentation;
    const auto show=[this,presentation] {
        if(presentation!=m_presentation)return;
        cancelPresentation();
        showPreparedWindow();
    };
    // Once the owner is mapped, later dialogs must remain available even
    // when the compositor is deliberately withholding additional frames.
    m_ownerFrame=ownerFrames
        ? connect(ownerFrames,&AuxiliaryWindowOwner::firstFrameSubmitted,this,show,Qt::QueuedConnection)
        : connect(owner,&QQuickWindow::frameSwapped,this,show,Qt::QueuedConnection);
    owner->update();
}

void AuxiliaryWindowPolicy::cancelPresentation() {
    ++m_presentation;
    disconnect(m_ownerFrame);
    m_ownerFrame={};
}

void AuxiliaryWindowPolicy::showPreparedWindow() {
    const auto window=m_window;
    if(!window || !m_owner || !m_owner->isVisible())return;
    window->show();
    if(window && window->isVisible())window->requestActivate();
}

QVariantMap AuxiliaryWindowPolicy::geometry() const {
    if(!m_window)return {};
    const auto current=m_window->size();
    // A smaller output can constrain either axis without changing the user's
    // preferred size. Save each axis only when it moved from its opening size.
    const int width=current.width()==m_initialSize.width() ? m_preferredSize.width() : current.width();
    const int height=current.height()==m_initialSize.height() ? m_preferredSize.height() : current.height();
    QVariantMap value{{QStringLiteral("width"),width},{QStringLiteral("height"),height}};
    if(!isWayland()) {
        value.insert(QStringLiteral("x"),m_window->x());value.insert(QStringLiteral("y"),m_window->y());
    }
    return value;
}

void AuxiliaryWindowPolicy::returnFocus() {
    const auto owner=m_owner;
    // A one-shot preview destroys its policy on close. Keep the deferred activation
    // scoped to the surviving owner instead, so that destruction cannot cancel it.
    if(owner)QTimer::singleShot(0,owner,[owner]{if(owner && owner->isVisible())owner->requestActivate();});
}
