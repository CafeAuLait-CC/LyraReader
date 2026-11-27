#include "AnnotationPassageText.h"
#include "ReadingTextGeometry.h"
#include <QAbstractTextDocumentLayout>
#include <QGuiApplication>
#include <QPainter>
#include <QTextBlock>
#include <QTextCursor>
#include <cmath>

namespace {
constexpr qsizetype maximumText=32768,maximumMarks=512;
constexpr double maximumHeight=2048;
}
AnnotationPassageText::AnnotationPassageText(QQuickItem *parent):QQuickPaintedItem(parent),m_font(QGuiApplication::font()) {
    m_font.setPixelSize(12);setAntialiasing(true);setClip(true);
}
void AnnotationPassageText::schedule(){polish();update();emit changed();}
void AnnotationPassageText::setText(const QString &value){if(m_text==value)return;m_text=value;schedule();}
void AnnotationPassageText::setMarks(const QVariantList &value){if(m_marks==value)return;m_marks=value;schedule();}
void AnnotationPassageText::setColor(const QColor &value){if(m_color==value)return;m_color=value;schedule();}
void AnnotationPassageText::setFont(const QFont &value){if(m_font==value)return;m_font=value;schedule();}
void AnnotationPassageText::geometryChange(const QRectF &next,const QRectF &previous){QQuickPaintedItem::geometryChange(next,previous);if(next.width()!=previous.width())polish();}
void AnnotationPassageText::updatePolish() {
    const auto oldWarning=m_warning;const bool oldClipped=m_clipped;m_warning.clear();
    auto count=std::min(m_text.size(),maximumText);
    if(count<m_text.size() && count>0 && m_text.at(count).isLowSurrogate() && m_text.at(count-1).isHighSurrogate())--count;
    const auto displayed=m_text.left(count);
    m_clipped=count<m_text.size();
    for(auto *document:{&m_ink,&m_strikes}) {
        document->setUndoRedoEnabled(false);document->setDocumentMargin(0);document->setDefaultFont(m_font);
        auto option=document->defaultTextOption();option.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);document->setDefaultTextOption(option);
        document->setPlainText(displayed);
        QTextCursor cursor(document);cursor.select(QTextCursor::Document);
        QTextBlockFormat block;block.setLineHeight(3,QTextBlockFormat::LineDistanceHeight);cursor.setBlockFormat(block);
        QTextCharFormat format;format.setForeground(document==&m_ink?m_color:QColor(Qt::transparent));cursor.setCharFormat(format);
        document->setTextWidth(std::max(1.,width()));
    }
    const auto boundaries=ReadingTextGeometry::sourceBoundaries(&m_ink,displayed);
    if(boundaries.isEmpty() || m_marks.size()>maximumMarks)m_warning=tr("The annotation styles could not be placed. Open the full context to read the passage.");
    else for(const auto &value:m_marks) {
        const auto mark=value.toMap();bool firstOk=false,lastOk=false;
        const auto first=mark.value(QStringLiteral("start")).toInt(&firstOk),last=mark.value(QStringLiteral("end")).toInt(&lastOk);
        const auto tint=mark.value(QStringLiteral("color")).value<QColor>();
        if(!firstOk || !lastOk || first<0 || last<=first || last>m_text.size() || !tint.isValid()) {m_warning=tr("Some annotation styles could not be placed.");continue;}
        if(first>=count && m_clipped)continue;
        const auto end=std::min(last,int(count));
        if(first>=boundaries.size() || end>=boundaries.size() || boundaries[first]<0 || boundaries[end]<0){m_warning=tr("Some annotation styles could not be placed.");continue;}
        const auto kind=mark.value(QStringLiteral("kind")).toString();
        const bool strike=kind==QStringLiteral("strikeout");
        QTextCharFormat format;
        if(kind==QStringLiteral("highlight"))format.setBackground(tint);
        else if(kind==QStringLiteral("underline") || kind==QStringLiteral("squiggly")){format.setUnderlineStyle(QTextCharFormat::SingleUnderline);format.setUnderlineColor(tint);}
        else if(strike){format.setFontStrikeOut(true);format.setUnderlineColor(tint);}
        else continue;
        // Qt shares one decoration colour for underline and strike. Separate native
        // documents preserve both colours when those marks overlap; glyphs stay ink.
        QTextCursor cursor(strike?&m_strikes:&m_ink);cursor.setPosition(boundaries[first]);cursor.setPosition(boundaries[end],QTextCursor::KeepAnchor);cursor.mergeCharFormat(format);
    }
    // Shape both documents during GUI polish; the render-thread paint only reads them.
    const auto inkHeight=m_ink.size().height(),strikeHeight=m_strikes.size().height();
    if(!std::isfinite(inkHeight) || !std::isfinite(strikeHeight)){m_warning=tr("The annotation text layout is unavailable.");setImplicitHeight(0);}
    else {const auto wanted=std::max(inkHeight,strikeHeight);m_clipped=m_clipped || wanted>maximumHeight;setImplicitHeight(std::min(wanted,maximumHeight));}
    update();if(oldWarning!=m_warning || oldClipped!=m_clipped)emit changed();
}
void AnnotationPassageText::paint(QPainter *painter) {
    const auto draw=[&](QTextDocument &document,QColor ink){QAbstractTextDocumentLayout::PaintContext context;context.palette.setColor(QPalette::Text,ink);context.clip=boundingRect();document.documentLayout()->draw(painter,context);};
    draw(m_ink,m_color);draw(m_strikes,Qt::transparent);
}
