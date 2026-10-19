#pragma once
#include "lyra_reader_desktop.h"
#include <QVariantList>
#include <functional>
#include <memory>
class QPrinter;

namespace PdfPrintJob {
// All PDF work runs on workers; QPrinter/QPainter and the cancel UI stay on the GUI thread.
void start(std::shared_ptr<LyraReaderDesktopDocument> document, const QVariantList &pages,
           std::shared_ptr<QPrinter> printer, int currentPage,
           std::function<void(QString)> finished, bool showProgress = true);
}
