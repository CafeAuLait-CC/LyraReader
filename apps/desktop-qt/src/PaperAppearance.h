#pragma once
#include <QColor>
#include <QImage>
class QQuickWindow;
class QSGNode;
class QRectF;

// Display conversion only. Source rasters and persisted annotation colours stay intact.
namespace PaperAppearance {
int mode(const QString &name);
QColor displayColor(const QColor &source, int mode);
QImage displayImage(const QImage &source, int mode);
QSGNode *createNode(QQuickWindow *window, const QImage &source, int mode);
void updateNode(QSGNode *node, const QRectF &bounds, int mode, const QRectF &sourceRect);
}
