#pragma once
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QPointer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <memory>

// Real loopback HTTP/SSE, used only by the GUI checks. No external service or key.
class MockChatServer {
public:
    struct Response {QList<QByteArray> chunks;int delay=50;int status=200;bool holdLast=false;};
    QList<Response> responses;
    QList<QByteArray> requests;
    bool listen() {
        QObject::connect(&server,&QTcpServer::newConnection,&server,[this]{
            while(auto *socket=server.nextPendingConnection()) {
                sockets.append(socket);
                QObject::connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                struct Input {QByteArray bytes;bool replied=false;};
                auto input=std::make_shared<Input>();
                QObject::connect(socket,&QTcpSocket::readyRead,socket,[this,socket,input]{
                    input->bytes+=socket->readAll();if(input->replied)return;
                    const auto end=input->bytes.indexOf("\r\n\r\n");if(end<0)return;
                    qint64 length=0;
                    for(const auto &line:input->bytes.left(end).split('\n'))if(line.toLower().startsWith("content-length:"))length=line.mid(15).trimmed().toLongLong();
                    if(input->bytes.size()<end+4+length)return;
                    input->replied=true;const auto index=requests.size();requests.append(input->bytes);
                    const auto response=index<responses.size() ? responses[index] : Response{{QByteArray("unexpected request")},0,400};
                    qsizetype size=0;for(const auto &chunk:response.chunks)size+=chunk.size();
                    socket->write(QByteArray("HTTP/1.1 ")+QByteArray::number(response.status)+(response.status==200 ? " OK\r\n" : " Error\r\n")+
                        "Content-Type: "+(response.status==200 ? "text/event-stream" : "application/json")+"\r\nContent-Length: "+QByteArray::number(size)+"\r\nConnection: close\r\n\r\n");
                    for(qsizetype i=0;i<response.chunks.size();++i){
                        // An unfinished response lets cancellation be tested without racing the compositor.
                        if(response.holdLast && i==response.chunks.size()-1)continue;
                        QTimer::singleShot(int(i)*response.delay,socket,[socket,chunk=response.chunks[i],last=i==response.chunks.size()-1]{if(socket->state()!=QAbstractSocket::ConnectedState || !socket->isOpen())return;socket->write(chunk);socket->flush();if(last)socket->disconnectFromHost();});
                    }
                });
            }
        });
        return server.listen(QHostAddress::LocalHost,0);
    }
    QString baseUrl()const{return QStringLiteral("http://127.0.0.1:%1/v1").arg(server.serverPort());}
    int activeConnections()const{int n=0;for(const auto &socket:sockets)if(socket && socket->state()==QAbstractSocket::ConnectedState)++n;return n;}
    static QByteArray delta(const QJsonObject &value) {
        return QByteArray("data: ")+QJsonDocument(QJsonObject{{"choices",QJsonArray{QJsonObject{{"delta",value}}}}}).toJson(QJsonDocument::Compact)+"\n\n";
    }
    static QByteArray usage() {return "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":7,\"total_tokens\":10,\"completion_tokens_details\":{\"reasoning_tokens\":2}}}\n\n";}
private:
    QTcpServer server;
    QList<QPointer<QTcpSocket>> sockets;
};
