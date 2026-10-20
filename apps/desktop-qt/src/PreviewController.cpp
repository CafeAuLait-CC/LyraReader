#include "PreviewController.h"
#include <QFutureWatcher>
#include <QRegularExpression>
#include <QUrlQuery>
#include <QtConcurrentRun>
#include <algorithm>
#include <cmath>

namespace {
QRectF box(const QVariantMap &v) {
    return {v.value(QStringLiteral("x_pt")).toDouble(),v.value(QStringLiteral("y_pt")).toDouble(),
            v.value(QStringLiteral("width_pt")).toDouble(),v.value(QStringLiteral("height_pt")).toDouble()};
}
QVariantMap region(const QVariantMap &v) {
    return {{QStringLiteral("x_pt"),v.value(QStringLiteral("x_pt"))},{QStringLiteral("y_pt"),v.value(QStringLiteral("y_pt"))},
            {QStringLiteral("width_pt"),v.value(QStringLiteral("width_pt"))},{QStringLiteral("height_pt"),v.value(QStringLiteral("height_pt"))}};
}
QVariantMap containing(const QVariantList &values,const QPointF &point) {
    for(const auto &value:values)if(box(value.toMap()).contains(point))return value.toMap();
    return {};
}
QString printedLine(const QVariantMap &text,const QRectF &target) {
    const auto chars=text.value(QStringLiteral("chars")).toList();
    int hit=-1;for(int i=0;i<chars.size();++i)if(box(chars.at(i).toMap()).intersects(target)){hit=i;break;}
    if(hit<0)return {};
    const auto onLine=[&](int i){const auto c=chars.at(i).toMap();const auto r=box(c);const auto code=c.value(QStringLiteral("unicode")).toUInt();return code!=10 && code!=13 && (r.height()<=0 || (r.bottom()>target.top() && r.top()<target.bottom()));};
    int first=hit,last=hit;
    while(first>0 && onLine(first-1))--first;
    while(last+1<chars.size() && onLine(last+1))++last;
    QString line;
    for(int i=first;i<=last;++i){const char32_t code=char32_t(chars.at(i).toMap().value(QStringLiteral("unicode")).toUInt());if(code>0 && code<=0x10ffff)line+=QString::fromUcs4(&code,1);}
    return line.simplified();
}
QVariantMap section(const QString &line,const QVariantList &outline,int page) {
    static const QRegularExpression pattern(QStringLiteral(R"((?i)(?<![A-Za-z])(?:§\s*|(?:sections?|sect|secs?|chapters?|ch|appendices|appendix|apps?|parts?)\.?\s+)((?:[A-Z]{1,2}|\d+)(?:\.\d+)*|[IVXLC]+)(?![A-Za-z0-9]))"));
    const auto match=pattern.match(line);
    if(!match.hasMatch())return {};
    const QRegularExpression designation(QStringLiteral("(?<![A-Za-z0-9.])")+QRegularExpression::escape(match.captured(1))+QStringLiteral("(?![A-Za-z0-9.])"));
    QVariantMap best;bool matched=false;
    for(const auto &value:outline) {
        const auto entry=value.toMap();const auto title=entry.value(QStringLiteral("title")).toString().trimmed();
        if(entry.value(QStringLiteral("page")).isNull() || entry.value(QStringLiteral("page")).toInt()!=page || title.isEmpty())continue;
        const bool same=designation.match(title).hasMatch();
        if(best.isEmpty() || (same && !matched) || (same==matched && entry.value(QStringLiteral("depth")).toInt()<best.value(QStringLiteral("depth")).toInt())){best=entry;matched=same;}
    }
    return {{QStringLiteral("section_reference"),match.captured().simplified()},
            {QStringLiteral("section_title"),best.value(QStringLiteral("title"))}};
}
struct Result {
    std::shared_ptr<NativeRasterSource> source;
    QVariantMap model;
    QVariantList sizes;
    QRectF clicked;
    QString error,message;
    QUrl external;
};
Result resolve(const std::shared_ptr<LyraReaderDesktopDocument> &document,int page,const QPointF &point) {
    Result r;r.source=NativeRasterSource::prepare(document,false,&r.error);if(!r.source)return r;
    const auto query=[&](const QString &op,QVariantMap args=QVariantMap{}) {args.insert(QStringLiteral("op"),op);return r.source->query(args,&r.error);};
    r.sizes=query(QStringLiteral("info")).toList();
    if(page<0 || page>=r.sizes.size())return r;
    const auto targets=query(QStringLiteral("page_targets"),{{QStringLiteral("page"),page}}).toMap();
    const auto link=containing(targets.value(QStringLiteral("links")).toList(),point);
    if(!link.isEmpty()) {
        const QUrl uri(link.value(QStringLiteral("uri")).toString());
        if(uri.scheme().compare(QStringLiteral("https"),Qt::CaseInsensitive)==0 || uri.scheme().compare(QStringLiteral("http"),Qt::CaseInsensitive)==0 || uri.scheme().compare(QStringLiteral("mailto"),Qt::CaseInsensitive)==0){r.external=uri;return r;}
    }
    const auto citation=containing(targets.value(QStringLiteral("citations")).toList(),point);
    if(!citation.isEmpty()) {
        const auto resolved=query(QStringLiteral("resolve_citations"),{{QStringLiteral("page"),page},{QStringLiteral("labels"),citation.value(QStringLiteral("labels"))}}).toList();
        QVariantList entries;
        for(const auto &value:resolved){const auto record=value.toMap().value(QStringLiteral("reference")).toMap();if(!record.isEmpty())entries.append(record);}
        if(!entries.isEmpty()) {
            const auto first=entries.first().toMap();r.clicked=box(citation);
            r.model={{QStringLiteral("kind"),QStringLiteral("reference")},{QStringLiteral("title"),citation.value(QStringLiteral("text")).toString().simplified()},
                     {QStringLiteral("page"),first.value(QStringLiteral("page"))},{QStringLiteral("region"),region(first)},
                     {QStringLiteral("entries"),entries},{QStringLiteral("from_page"),page},
                     {QStringLiteral("resolution_reason"),resolved.first().toMap().value(QStringLiteral("reason"))},
                     {QStringLiteral("list_heading"),resolved.first().toMap().value(QStringLiteral("list_heading"))},
                     {QStringLiteral("ambiguous"),resolved.first().toMap().value(QStringLiteral("ambiguous"))}};return r;
        }
        r.message=QObject::tr("Citation has no matching bibliography entry.");
    }
    const auto mention=containing(targets.value(QStringLiteral("mentions")).toList(),point);
    if(!mention.isEmpty()) {
        for(const auto &value:query(QStringLiteral("figures")).toList()) {
            const auto figure=value.toMap();
            if(figure.value(QStringLiteral("kind"))!=mention.value(QStringLiteral("kind")) || figure.value(QStringLiteral("label"))!=mention.value(QStringLiteral("label")))continue;
            r.clicked=box(mention);const auto title=figure.value(QStringLiteral("kind")).toString()+QStringLiteral(" ")+figure.value(QStringLiteral("label")).toString();
            r.model={{QStringLiteral("kind"),QStringLiteral("figure")},{QStringLiteral("title"),title},{QStringLiteral("page"),figure.value(QStringLiteral("page"))},
                     {QStringLiteral("region"),region(figure)},{QStringLiteral("caption"),figure.value(QStringLiteral("caption_text"))},{QStringLiteral("from_page"),page}};return r;
        }
        r.message=QObject::tr("No matching caption was indexed.");
    }
    if(!link.isEmpty() && !link.value(QStringLiteral("page")).isNull()) {
        const int destination=link.value(QStringLiteral("page")).toInt();
        if(destination<0 || destination>=r.sizes.size())return r;
        r.clicked=box(link);const auto target=link.value(QStringLiteral("region")).toMap();
        r.model={{QStringLiteral("kind"),target.isEmpty()?QStringLiteral("page"):QStringLiteral("figure")},
                 {QStringLiteral("title"),QObject::tr("Page %1").arg(destination+1)},{QStringLiteral("page"),destination},
                 {QStringLiteral("region"),target},{QStringLiteral("from_page"),page}};
        if(target.isEmpty()) {
            const auto text=query(QStringLiteral("text"),{{QStringLiteral("page"),page}}).toMap();
            const auto heading=section(printedLine(text,r.clicked),query(QStringLiteral("outline")).toList(),destination);
            if(!heading.isEmpty()) {
                r.model.insert(QStringLiteral("kind"),QStringLiteral("section"));
                r.model.insert(QStringLiteral("section_title"),heading.value(QStringLiteral("section_title")));
                r.model.insert(QStringLiteral("section_reference"),heading.value(QStringLiteral("section_reference")));
                r.model.insert(QStringLiteral("title"),heading.value(QStringLiteral("section_title")).toString().isEmpty()?heading.value(QStringLiteral("section_reference")):heading.value(QStringLiteral("section_title")));
            }
        }
    }
    return r;
}
}

PreviewController::~PreviewController() { NativeImageProvider::unregisterSource(m_sourceKey); }
void PreviewController::close() {
    ++m_epoch;m_loading=false;m_pinned=false;m_model.clear();m_textModel.clear();m_sizes.clear();
    NativeImageProvider::unregisterSource(m_sourceKey);m_sourceKey.clear();m_source.reset();
    QObject::disconnect(m_resetConnection);m_reader.clear();emit changed();
}
void PreviewController::togglePin() { if(!visible())return;m_pinned=!m_pinned;emit changed(); }
void PreviewController::openAt(ReaderController *reader,int page,double x,double y,double sceneX,double sceneY,double zoom) {
    if(!reader || !reader->documentHandle())return;
    if(m_pinned){emit statusMessage(tr("Preview pinned — unpin it to preview another reference."));return;}
    if(!std::isfinite(x) || !std::isfinite(y))return;
    close();m_reader=reader;m_url=reader->fileUrl();m_loading=true;emit changed();
    m_resetConnection=connect(reader,&ReaderController::documentReset,this,&PreviewController::close);
    const auto epoch=m_epoch;const auto document=reader->documentHandle();
    auto *watcher=new QFutureWatcher<Result>(this);
    connect(watcher,&QFutureWatcher<Result>::finished,this,[this,watcher,epoch,x,y,sceneX,sceneY,zoom] {
        auto result=watcher->result();watcher->deleteLater();
        if(epoch!=m_epoch)return;
        m_loading=false;
        if(!result.error.isEmpty()){emit changed();emit statusMessage(result.error);return;}
        if(!result.external.isEmpty()){emit changed();emit externalRequested(result.external);return;}
        if(result.model.isEmpty()){emit changed();if(!result.message.isEmpty())emit statusMessage(result.message);return;}
        m_model=std::move(result.model);m_textModel=m_model;m_sizes=std::move(result.sizes);m_source=std::move(result.source);
        m_sourceKey=NativeImageProvider::registerSource(m_source);
        m_anchor=QRectF(sceneX+(result.clicked.x()-x)*zoom,sceneY+(result.clicked.y()-y)*zoom,result.clicked.width()*zoom,result.clicked.height()*zoom);
        emit changed();
    });
    watcher->setFuture(QtConcurrent::run([document,page,x,y]{return resolve(document,page,{x,y});}));
}
void PreviewController::imageRegion(int page,const QVariantMap &region,const QVariantList &fragments) {
    if(page<0 || page>=m_sizes.size())return;
    m_model.insert(QStringLiteral("kind"),QStringLiteral("page"));m_model.insert(QStringLiteral("page"),page);
    m_model.insert(QStringLiteral("region"),region);m_model.insert(QStringLiteral("fragments"),fragments);emit changed();
}
void PreviewController::showEntry(int index) {
    const auto entries=m_textModel.value(QStringLiteral("entries")).toList();
    if(index<0 || index>=entries.size())return;
    const auto entry=entries.at(index).toMap();imageRegion(entry.value(QStringLiteral("page")).toInt(),region(entry),entry.value(QStringLiteral("fragments")).toList());
}
void PreviewController::showFullPage() { imageRegion(m_model.value(QStringLiteral("page")).toInt(),{}); }
void PreviewController::showText() {if(m_textModel.isEmpty())return;m_model=m_textModel;emit changed();}
QVariantList PreviewController::imageSegments(double width,double deviceScale,const QString &paper) const {
    if(!m_source || m_sourceKey.isEmpty() || !std::isfinite(width) || width<=0)return {};
    QVariantList segments=m_model.value(QStringLiteral("fragments")).toList();
    if(segments.isEmpty()){auto one=m_model.value(QStringLiteral("region")).toMap();one.insert(QStringLiteral("page"),m_model.value(QStringLiteral("page")));segments.append(one);}
    QVariantList result;
    for(const auto &value:segments) {
        const auto part=value.toMap();const int page=part.value(QStringLiteral("page")).toInt();if(page<0 || page>=m_sizes.size())continue;
        const auto size=m_sizes.at(page).toMap();const QRectF full(0,0,size.value(QStringLiteral("width_pt")).toDouble(),size.value(QStringLiteral("height_pt")).toDouble());
        auto target=box(part);if(target.isEmpty())target=full;target=target.intersected(full);if(target.isEmpty())continue;
        QUrl url(QStringLiteral("image://lyrapreview/")+m_sourceKey+QStringLiteral("/")+QString::number(page));QUrlQuery query;
        const auto add=[&](const QString &key,double number){query.addQueryItem(key,QString::number(number,'g',15));};
        add(QStringLiteral("x"),target.x());add(QStringLiteral("y"),target.y());add(QStringLiteral("w"),target.width());add(QStringLiteral("h"),target.height());
        const double pixels=std::ceil(width*qBound(1.0,deviceScale,4.0)/32.0)*32.0;
        add(QStringLiteral("scale"),qBound(.1,pixels/target.width(),16.0));query.addQueryItem(QStringLiteral("paper"),paper);url.setQuery(query);
        result.append(QVariantMap{{QStringLiteral("url"),url},{QStringLiteral("aspect"),target.height()/target.width()},{QStringLiteral("page"),page}});
    }
    return result;
}
QUrl PreviewController::imageUrl(double width,double deviceScale,const QString &paper) const {
    const auto segments=imageSegments(width,deviceScale,paper);return segments.isEmpty()?QUrl{}:segments.first().toMap().value(QStringLiteral("url")).toUrl();
}
void PreviewController::jump() {if(visible())emit navigateRequested(m_model.value(QStringLiteral("page")).toInt(),box(m_model.value(QStringLiteral("region")).toMap()).y());}
void PreviewController::openWindow() {if(visible())emit newWindowRequested(m_url,m_model.value(QStringLiteral("page")).toInt());}
