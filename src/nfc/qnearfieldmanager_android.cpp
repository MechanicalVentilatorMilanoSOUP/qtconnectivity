/****************************************************************************
**
** Copyright (C) 2016 Centria research and development
** Contact: https://www.qt.io/licensing/
**
** This file is part of the QtNfc module of the Qt Toolkit.
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

#include "qnearfieldmanager_android_p.h"
#include "qnearfieldtarget_android_p.h"

#include "qndeffilter.h"
#include "qndefmessage.h"
#include "qndefrecord.h"
#include "qbytearray.h"
#include "qcoreapplication.h"
#include "qdebug.h"
#include "qlist.h"

#include <QScopedPointer>
#include <QtCore/QMetaType>
#include <QtCore/QMetaMethod>
#include <QtCore/private/qjnihelpers_p.h>

QT_BEGIN_NAMESPACE

Q_GLOBAL_STATIC(QAndroidJniObject, broadcastReceiver)
Q_GLOBAL_STATIC(QList<QNearFieldManagerPrivateImpl *>, broadcastListener)

extern "C"
{
    JNIEXPORT void JNICALL Java_org_qtproject_qt5_android_nfc_QtNfcBroadcastReceiver_jniOnReceive(
        JNIEnv */*env*/, jobject /*javaObject*/, jint state)
    {
        QNearFieldManager::AdapterState adapterState = static_cast<QNearFieldManager::AdapterState>((int) state);

        for (const auto listener : qAsConst(*broadcastListener)) {
            Q_EMIT listener->adapterStateChanged(adapterState);
        }
    }
}

QNearFieldManagerPrivateImpl::QNearFieldManagerPrivateImpl() :
    m_detecting(false)
{
    qRegisterMetaType<QAndroidJniObject>("QAndroidJniObject");
    qRegisterMetaType<QNdefMessage>("QNdefMessage");

    if (!broadcastReceiver->isValid()) {
        *broadcastReceiver = QAndroidJniObject("org/qtproject/qt5/android/nfc/QtNfcBroadcastReceiver",
                                               "(Landroid/content/Context;)V", QtAndroidPrivate::context());
    }
    broadcastListener->append(this);
}

QNearFieldManagerPrivateImpl::~QNearFieldManagerPrivateImpl()
{
    broadcastListener->removeOne(this);
    if (broadcastListener->isEmpty()) {
        broadcastReceiver->callMethod<void>("unregisterReceiver");
        *broadcastReceiver = QAndroidJniObject();
    }
}

void QNearFieldManagerPrivateImpl::onTargetDetected(QNearFieldTarget *target)
{
    Q_EMIT targetDetected(target);
}

void QNearFieldManagerPrivateImpl::onTargetLost(QNearFieldTarget *target)
{
    Q_EMIT targetLost(target);
}

bool QNearFieldManagerPrivateImpl::isEnabled() const
{
    return AndroidNfc::isEnabled();
}

bool QNearFieldManagerPrivateImpl::isSupported() const
{
    return AndroidNfc::isSupported();
}

bool QNearFieldManagerPrivateImpl::startTargetDetection()
{
    if (m_detecting)
        return false;   // Already detecting targets

    m_detecting = true;
    updateReceiveState();
    return true;
}

void QNearFieldManagerPrivateImpl::stopTargetDetection()
{
    m_detecting = false;
    updateReceiveState();
}

void QNearFieldManagerPrivateImpl::requestAccess(QNearFieldManager::TargetAccessModes accessModes)
{
    Q_UNUSED(accessModes);
    //Do nothing, because we dont have access modes for the target
}

void QNearFieldManagerPrivateImpl::releaseAccess(QNearFieldManager::TargetAccessModes accessModes)
{
    Q_UNUSED(accessModes);
    //Do nothing, because we dont have access modes for the target
}

void QNearFieldManagerPrivateImpl::newIntent(QAndroidJniObject intent)
{
    // This function is called from different thread and is used to move intent to main thread.
    QMetaObject::invokeMethod(this, [this, intent] {
        this->onTargetDiscovered(intent);
    }, Qt::QueuedConnection);
}

QByteArray QNearFieldManagerPrivateImpl::getUid(const QAndroidJniObject &intent)
{
    if (!intent.isValid())
        return QByteArray();

    QAndroidJniEnvironment env;
    QAndroidJniObject tag = AndroidNfc::getTag(intent);
    return getUidforTag(tag);
}

void QNearFieldManagerPrivateImpl::onTargetDiscovered(QAndroidJniObject intent)
{
    // Only intents with a tag are relevant
    if (!AndroidNfc::getTag(intent).isValid())
        return;

    // Getting UID
    QByteArray uid = getUid(intent);

    // Accepting all targets but only sending signal of requested types.
    NearFieldTarget *&target = m_detectedTargets[uid];
    if (target) {
        target->setIntent(intent);  // Updating existing target
    } else {
        target = new NearFieldTarget(intent, uid, this);
        connect(target, &NearFieldTarget::targetDestroyed, this, &QNearFieldManagerPrivateImpl::onTargetDestroyed);
        connect(target, &NearFieldTarget::targetLost, this, &QNearFieldManagerPrivateImpl::onTargetLost);
    }
    onTargetDetected(target);
}

void QNearFieldManagerPrivateImpl::onTargetDestroyed(const QByteArray &uid)
{
    m_detectedTargets.remove(uid);
}

QByteArray QNearFieldManagerPrivateImpl::getUidforTag(const QAndroidJniObject &tag)
{
    if (!tag.isValid())
        return QByteArray();

    QAndroidJniEnvironment env;
    QAndroidJniObject tagId = tag.callObjectMethod("getId", "()[B");
    QByteArray uid;
    jsize len = env->GetArrayLength(tagId.object<jbyteArray>());
    uid.resize(len);
    env->GetByteArrayRegion(tagId.object<jbyteArray>(), 0, len, reinterpret_cast<jbyte*>(uid.data()));
    return uid;
}

void QNearFieldManagerPrivateImpl::updateReceiveState()
{
    if (m_detecting) {
        AndroidNfc::registerListener(this);
    } else {
        AndroidNfc::unregisterListener(this);
    }
}

QT_END_NAMESPACE
