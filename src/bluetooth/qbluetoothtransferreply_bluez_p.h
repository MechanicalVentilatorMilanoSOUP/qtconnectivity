/****************************************************************************
**
** Copyright (C) 2016 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the QtBluetooth module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-2.0.html and
** https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#ifndef QBLUETOOTHTRANSFERREPLY_BLUEZ_P_H
#define QBLUETOOTHTRANSFERREPLY_BLUEZ_P_H

//
//  W A R N I N G
//  -------------
//
// This file is not part of the Qt API.  It exists purely as an
// implementation detail.  This header file may change from version to
// version without notice, or even be removed.
//
// We mean it.
//

#include <QtCore/QIODevice>
#include <QtDBus/QtDBus>

#include <QtBluetooth/QBluetoothTransferRequest>
#include <QtBluetooth/QBluetoothTransferManager>

#include "qbluetoothtransferreply.h"

class OrgOpenobexClientInterface;
class AgentAdaptor;
class OrgBluezObexClient1Interface;
class OrgBluezObexObjectPush1Interface;

QT_BEGIN_NAMESPACE

class Q_BLUETOOTH_EXPORT QBluetoothTransferReplyBluez : public QBluetoothTransferReply
{
    Q_OBJECT

public:
    explicit QBluetoothTransferReplyBluez(QIODevice *input, const QBluetoothTransferRequest &request,
                                          QBluetoothTransferManager *parent = nullptr);
    ~QBluetoothTransferReplyBluez();

    bool isFinished() const override;
    bool isRunning() const override;

    QBluetoothTransferReply::TransferError error() const override;
    QString errorString() const override;

private slots:
    bool start();

private:
    void startOPP(const QString &filename);

    OrgOpenobexClientInterface *m_client = nullptr;
    AgentAdaptor *m_agent = nullptr;
    OrgBluezObexClient1Interface *m_clientBluez = nullptr;
    OrgBluezObexObjectPush1Interface *m_objectPushBluez = nullptr;


    QTemporaryFile *m_tempfile = nullptr;
    QIODevice *m_source = nullptr;

    bool m_running;
    bool m_finished;

    quint64 m_size;

    QBluetoothTransferReply::TransferError m_error;
    QString m_errorStr;

    QString m_agent_path;

    QString m_transfer_path;
    QString fileToTranser;

    static bool copyToTempFile(QIODevice *to, QIODevice *from);
    void cleanupSession();

private slots:
    void copyDone();
    void sessionCreated(QDBusPendingCallWatcher *watcher);
    void sessionStarted(QDBusPendingCallWatcher *watcher);
    void sessionChanged(const QString &interface,
                        const QVariantMap &changed_properties,
                        const QStringList &invalidated_properties,
                        const QDBusMessage &);

public slots:
    void abort();
    void Complete(const QDBusObjectPath &in0);
    void Error(const QDBusObjectPath &in0, const QString &in1);
    void Progress(const QDBusObjectPath &in0, qulonglong in1);
    void Release();
    QString Request(const QDBusObjectPath &in0);
    void sendReturned(QDBusPendingCallWatcher*);

};

QT_END_NAMESPACE

#endif // QBLUETOOTHTRANSFERREPLY_H
