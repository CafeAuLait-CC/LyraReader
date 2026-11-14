#pragma once
#include "RenderTrace.h"
#include <QFile>
#include <QJsonDocument>
#include <QProcess>
#include <QDir>
#include <QGuiApplication>
#include <QTest>
#include <QUuid>
#include <functional>

struct TraceCapture {
    std::shared_ptr<RenderTrace::Sink> sink=RenderTrace::Sink::memory();
    QList<QJsonObject> records;
    bool overflow=false;
    void drain() {
        const auto incoming=sink->takeRecords();
        if(incoming.size()>20000-records.size()){overflow=true;return;}
        records.append(incoming);
    }
    qsizetype mark(){drain();return records.size();}
    bool has(qsizetype after,const std::function<bool(const QJsonObject &)> &predicate) {
        drain();for(qsizetype i=after;i<records.size();++i)if(predicate(records[i]))return true;return false;
    }
    QPair<int,QByteArray> analyze(const QString &root,const QString &directory) {
        sink->finish();drain();
        if(overflow || !sink->error().isEmpty())return {-1,"Trace capture exceeded its admission budget."};
        QFile output(directory+"/actual-scene-trace.log");
        if(!output.open(QIODevice::WriteOnly|QIODevice::NewOnly))return {-1,output.errorString().toUtf8()};
        for(const auto &record:records){const auto line=QByteArray("lyra-reader-perf-trace: ")+QJsonDocument(record).toJson(QJsonDocument::Compact)+'\n';if(output.write(line)!=line.size())return {-1,output.errorString().toUtf8()};}
        output.close();
        const auto *function=QTest::currentTestFunction();if(!function)return {-1,"No test identity is available for trace evidence."};
        const auto relative=QStringLiteral("build/qt-render-trace-evidence/")+QString::fromUtf8(function);
        if(!QDir().mkpath(root+"/"+relative))return {-1,"Could not create the local trace evidence directory."};
        const auto base=relative+"/"+QGuiApplication::platformName()+"-"+QUuid::createUuid().toString(QUuid::WithoutBraces);
        if(!QFile::copy(output.fileName(),root+"/"+base+".log"))return {-1,"Could not preserve the raw scene trace."};
        qInfo().noquote()<<"Qt scene trace evidence:"<<base+".log";
        QProcess parser;parser.start("python3",{"-B",root+"/scripts/analyze-qt-render-trace.py",root+"/"+base+".log","--output",root+"/"+base+".json"});
        if(!parser.waitForFinished(15000)){parser.kill();parser.waitForFinished(1000);return {-1,"The scene trace parser did not finish."};}
        if(parser.exitStatus()!=QProcess::NormalExit)return {-1,"The scene trace parser exited abnormally."};
        QFile report(root+"/"+base+".json");QByteArray bytes;
        if(report.open(QIODevice::ReadOnly))bytes=report.readAll();
        return {parser.exitCode(),bytes+parser.readAllStandardOutput()+parser.readAllStandardError()};
    }
};
