#include "PdfPrintJob.h"
#include <QCoreApplication>
#include <QFutureWatcher>
#include <QPainter>
#include <QImage>
#include <QPrinter>
#include <QProgressDialog>
#include <QTimer>
#include <QtConcurrentRun>
#include "RasterJobs.h"
#include <algorithm>

namespace {
using Source=std::shared_ptr<LyraReaderRenderSource>;
QString takeError(LyraReaderBuffer &buffer) {
    const auto error=QString::fromUtf8(reinterpret_cast<const char *>(buffer.data),qsizetype(buffer.len));
    lyra_reader_desktop_buffer_free(buffer);buffer={};return error;
}
struct Prepared { Source source;QString error; };
struct Band { QImage image;QString error; };
void releasePixels(void *data) {
    auto *pixels=static_cast<LyraReaderBuffer *>(data);
    lyra_reader_desktop_buffer_free(*pixels);delete pixels;
}
class Job final:public QObject {
public:
    std::shared_ptr<QPrinter> printer;
    Source source;
    QVariantList sizes;
    QList<int> pages;
    int index=0;
    double top=0;
    bool cancelled=false;
    std::unique_ptr<QPainter> painter;
    QProgressDialog *progress=nullptr;
    std::function<void(QString)> finished;
    explicit Job(QObject *parent):QObject(parent){}
    void finish(const QString &error={}) {
        if(painter){if(cancelled || !error.isEmpty())printer->abort();painter->end();painter.reset();}
        if(progress){progress->close();progress->deleteLater();progress=nullptr;}
        finished(error.isEmpty() && cancelled ? tr("Printing cancelled.") : error);
        deleteLater();
    }
    void nextBand() {
        if(cancelled){finish();return;}
        if(index>=pages.size()){finish();return;}
        const auto size=sizes.at(pages.at(index)).toMap();
        const double width=size.value(QStringLiteral("width")).toDouble();
        const double height=size.value(QStringLiteral("height")).toDouble();
        const double y=top,bandHeight=qMin(128.0,height-y);
        const int page=pages.at(index);
        auto ticket=RasterJobs::enqueue();
        if(!ticket){QTimer::singleShot(100,this,[this]{nextBand();});return;}
        auto *watcher=new QFutureWatcher<Band>(this);
        connect(watcher,&QFutureWatcher<Band>::finished,this,[this,watcher,width,height,y,bandHeight] {
            const auto band=watcher->result();watcher->deleteLater();
            if(cancelled){finish();return;}
            if(!band.error.isEmpty()){finish(band.error);return;}
            if(!painter) {
                painter=std::make_unique<QPainter>();
                if(!painter->begin(printer.get())){finish(tr("The printer could not start the job."));return;}
            }else if(y==0 && !printer->newPage()){finish(tr("The printer could not start the next page."));return;}
            const QRectF available(QPointF(0,0),printer->pageRect(QPrinter::DevicePixel).size());
            const double fit=qMin(available.width()/width,available.height()/height);
            const QPointF origin(available.x()+(available.width()-width*fit)/2,available.y()+(available.height()-height*fit)/2);
            painter->drawImage(QRectF(origin.x(),origin.y()+y*fit,width*fit,bandHeight*fit),band.image);
            top=y+bandHeight;
            if(top>=height-0.00001){++index;top=0;if(progress)progress->setValue(index);}
            // Yield between bounded strips so cancellation and native window events remain responsive.
            QTimer::singleShot(0,this,[this]{nextBand();});
        });
        const auto snapshot=source;
        watcher->setFuture(QtConcurrent::run(RasterJobs::pool(),[snapshot,page,width,y,bandHeight,ticket] {
            RasterJobs::Run run(ticket);
            Band result;LyraReaderBitmap bitmap{};LyraReaderBuffer error{};
            if(!lyra_reader_desktop_render_region(snapshot.get(),page,300.0/72.0,0,y,width,bandHeight,true,false,&bitmap,&error)) {
                result.error=takeError(error);return result;
            }
            if(bitmap.width==0 || bitmap.height==0 || bitmap.stride<bitmap.width*4 || bitmap.pixels.len<std::size_t(bitmap.stride)*bitmap.height) {
                lyra_reader_desktop_buffer_free(bitmap.pixels);result.error=QStringLiteral("Invalid print raster.");return result;
            }
            auto *pixels=new LyraReaderBuffer(bitmap.pixels);
            result.image=QImage(pixels->data,int(bitmap.width),int(bitmap.height),int(bitmap.stride),QImage::Format_ARGB32,releasePixels,pixels);
            return result;
        }));
    }
};
}

void PdfPrintJob::start(std::shared_ptr<LyraReaderDesktopDocument> document,const QVariantList &sizes,
                       std::shared_ptr<QPrinter> printer,int currentPage,std::function<void(QString)> finished,bool showProgress) {
    auto *job=new Job(QCoreApplication::instance());
    job->printer=std::move(printer);job->sizes=sizes;job->finished=std::move(finished);
    int from=0,to=int(sizes.size())-1;
    if(job->printer->printRange()==QPrinter::PageRange) {
        from=qBound(0,job->printer->fromPage()-1,to);to=qBound(from,job->printer->toPage()-1,to);
    }else if(job->printer->printRange()==QPrinter::CurrentPage)from=to=qBound(0,currentPage,to);
    for(int page=from;page<=to;++page)job->pages.append(page);
    if(job->printer->pageOrder()==QPrinter::LastPageFirst)std::reverse(job->pages.begin(),job->pages.end());
    if(!job->printer->supportsMultipleCopies()) {
        const auto original=job->pages;const int copies=qMax(1,job->printer->copyCount());
        job->pages.clear();
        if(job->printer->collateCopies())for(int copy=0;copy<copies;++copy)job->pages.append(original);
        else for(const auto page:original)for(int copy=0;copy<copies;++copy)job->pages.append(page);
        job->printer->setCopyCount(1);
    }
    if(job->pages.isEmpty()){job->finish(QObject::tr("No pages to print."));return;}
    if(showProgress) {
        job->progress=new QProgressDialog(QObject::tr("Preparing print pages…"),QObject::tr("Cancel"),0,int(job->pages.size()));
        job->progress->setWindowTitle(QObject::tr("LyraReader — Print"));
        job->progress->setMinimumDuration(0);job->progress->setAutoClose(false);job->progress->setValue(0);
        QObject::connect(job->progress,&QProgressDialog::canceled,job,[job]{job->cancelled=true;});
    }
    auto *watcher=new QFutureWatcher<Prepared>(job);
    QObject::connect(watcher,&QFutureWatcher<Prepared>::finished,job,[job,watcher] {
        auto prepared=watcher->result();watcher->deleteLater();
        if(!prepared.error.isEmpty()){job->finish(prepared.error);return;}
        job->source=std::move(prepared.source);
        if(job->progress)job->progress->setLabelText(QObject::tr("Printing at 300 dpi…"));
        job->nextBand();
    });
    watcher->setFuture(QtConcurrent::run([document] {
        Prepared result;LyraReaderBuffer error{};
        result.source=Source(lyra_reader_desktop_render_source(document.get(),true,&error),lyra_reader_desktop_render_source_free);
        if(!result.source)result.error=takeError(error);
        return result;
    }));
}
