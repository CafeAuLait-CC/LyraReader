#include "LocalFileIdentity.h"
#include <QFileInfo>
#include <filesystem>

bool sameLocalFile(const QUrl &one,const QUrl &two) {
    if(!one.isLocalFile() || !two.isLocalFile() || one.toLocalFile().isEmpty() || two.toLocalFile().isEmpty())return false;
    const auto a=QFileInfo(one.toLocalFile()),b=QFileInfo(two.toLocalFile());
    auto key=[](const QFileInfo &f){const auto canonical=f.canonicalFilePath();return canonical.isEmpty() ? QFileInfo(f.absolutePath()).canonicalFilePath()+QLatin1Char('/')+f.fileName() : canonical;};
    if(key(a)==key(b))return true;
    std::error_code error;
    auto path=[](const QString &s){
#ifdef Q_OS_WIN
        return std::filesystem::path(s.toStdWString());
#else
        return std::filesystem::path(s.toStdString());
#endif
    };
    return std::filesystem::equivalent(path(a.absoluteFilePath()),path(b.absoluteFilePath()),error) && !error;
}
