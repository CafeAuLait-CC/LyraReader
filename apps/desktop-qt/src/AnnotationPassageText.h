#pragma once
#include <QQuickPaintedItem>
#include <QTextDocument>
#include <QVariantList>

// Small native sidebar text. Geometry/UTF-16 marks are supplied by the shared engine.
class AnnotationPassageText : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(QString text READ text WRITE setText NOTIFY changed)
    Q_PROPERTY(QVariantList marks READ marks WRITE setMarks NOTIFY changed)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY changed)
    Q_PROPERTY(QFont font READ font WRITE setFont NOTIFY changed)
    Q_PROPERTY(bool clipped READ clipped NOTIFY changed)
    Q_PROPERTY(QString warning READ warning NOTIFY changed)
public:
    explicit AnnotationPassageText(QQuickItem *parent=nullptr);
    QString text()const{return m_text;}
    QVariantList marks()const{return m_marks;}
    QColor color()const{return m_color;}
    QFont font()const{return m_font;}
    bool clipped()const{return m_clipped;}
    QString warning()const{return m_warning;}
    void setText(const QString &value);
    void setMarks(const QVariantList &value);
    void setColor(const QColor &value);
    void setFont(const QFont &value);
    void paint(QPainter *painter)override;
signals:
    void changed();
protected:
    void updatePolish()override;
    void geometryChange(const QRectF &next,const QRectF &previous)override;
private:
    void schedule();
    QString m_text,m_warning;
    QVariantList m_marks;
    QColor m_color=Qt::black;
    QFont m_font;
    QTextDocument m_ink,m_strikes;
    bool m_clipped=false;
};
