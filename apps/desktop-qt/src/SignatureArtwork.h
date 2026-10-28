#pragma once
#include <QStringList>
#include <QVariantMap>

// Native font discovery and glyph rasterization. Call on the GUI thread; PDF annotation
// validation, history and publication remain with the shared Rust engine.
namespace SignatureArtwork {
QStringList fonts();
QVariantMap typed(const QString &name, const QString &family);
}
