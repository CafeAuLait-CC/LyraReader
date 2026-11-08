#pragma once
#include <QColor>
#include <QImage>
#include <QRectF>
class QQuickWindow;
class QSGNode;
class QRectF;

// Display conversion only. Source rasters and persisted annotation colours stay intact.
namespace PaperAppearance {
struct Quad {QRectF target,source;};
int mode(const QString &name);
QColor displayColor(const QColor &source, int mode);
QImage displayImage(const QImage &source, int mode);
QSGNode *createNode(QQuickWindow *window, const QImage &source, int mode);
void updateNode(QSGNode *node, const QRectF &bounds, int mode, const QRectF &sourceRect);
void updateNodeQuads(QSGNode *node,const Quad *quads,int count,int mode);
}
