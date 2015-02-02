/****************************************************************************
**
** Copyright (C) 2014 Digia Plc and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/legal
**
** This file is part of the QtBluetooth module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and Digia.  For licensing terms and
** conditions see http://qt.digia.com/licensing.  For further information
** use the contact form at http://qt.digia.com/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 2.1 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU Lesser General Public License version 2.1 requirements
** will be met: http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Digia gives you certain additional
** rights.  These rights are described in the Digia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 3.0 as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL included in the
** packaging of this file.  Please review the following information to
** ensure the GNU General Public License version 3.0 requirements will be
** met: http://www.gnu.org/copyleft/gpl.html.
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include "qlowenergyserviceprivate_p.h"
#include "qlowenergycharacteristic.h"
#include "osxbtcentralmanager_p.h"


#include <QtCore/qloggingcategory.h>
#include <QtCore/qdebug.h>

#include <algorithm>
#include <limits>

QT_BEGIN_NAMESPACE

namespace OSXBluetooth {

CentralManagerDelegate::~CentralManagerDelegate()
{
}

NSUInteger qt_countGATTEntries(CBService *service)
{
    // Identify, how many characteristics/descriptors we have on a given service,
    // +1 for the service itself.
    // No checks if NSUInteger is big enough :)
    // Let's assume such number of entries is not possible :)

    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;

    NSArray *const cs = service.characteristics;
    if (!cs || !cs.count)
        return 1;

    NSUInteger n = 1 + cs.count;
    for (CBCharacteristic *c in cs) {
        NSArray *const ds = c.descriptors;
        if (ds)
            n += ds.count;
    }

    return n;
}

}

QT_END_NAMESPACE


#ifdef QT_NAMESPACE
using namespace QT_NAMESPACE;
#endif

@interface QT_MANGLE_NAMESPACE(OSXBTCentralManager) (PrivateAPI)

- (QLowEnergyController::Error)connectToDevice; // "Device" is in Qt's world ...
- (void)connectToPeripheral; // "Peripheral" is in Core Bluetooth.
- (void)discoverIncludedServices;
- (void)readCharacteristics:(CBService *)service;
- (void)serviceDetailsDiscoveryFinished:(CBService *)service;
- (void)performNextWriteRequest;

// Aux. functions.
- (CBService *)serviceForUUID:(const QBluetoothUuid &)qtUuid;
- (CBCharacteristic *)nextCharacteristicForService:(CBService*)service
                      startingFrom:(CBCharacteristic *)from;
- (CBCharacteristic *)nextCharacteristicForService:(CBService*)service
                      startingFrom:(CBCharacteristic *)from
                      withProperties:(CBCharacteristicProperties)properties;
- (CBDescriptor *)nextDescriptorForCharacteristic:(CBCharacteristic *)characteristic
                  startingFrom:(CBDescriptor *)descriptor;
- (CBDescriptor *)descriptor:(const QBluetoothUuid &)dUuid
                  forCharacteristic:(CBCharacteristic *)ch;
- (bool)cacheWriteValue:(const QByteArray &)value for:(NSObject *)obj;
- (void)reset;

@end

@implementation QT_MANGLE_NAMESPACE(OSXBTCentralManager)

- (id)initWithDelegate:(QT_PREPEND_NAMESPACE(OSXBluetooth)::CentralManagerDelegate *)aDelegate
{
    Q_ASSERT_X(aDelegate, Q_FUNC_INFO, "invalid delegate (null)");

    if (self = [super init]) {
        manager = nil;
        managerState = OSXBluetooth::CentralManagerIdle;
        disconnectPending = false;
        peripheral = nil;
        delegate = aDelegate;
        currentService = 0;
        lastValidHandle = 0;
        writePending = false;
    }

    return self;
}

- (void)dealloc
{
    // In the past I had a 'transient delegate': I've seen some crashes
    // while deleting a manager _before_ its state updated.
    // Strangely enough, I can not reproduce this anymore, so this
    // part is simplified now. To be investigated though.

    visitedServices.reset(nil);
    servicesToVisit.reset(nil);
    servicesToVisitNext.reset(nil);

    [manager setDelegate:nil];
    [manager release];

    [peripheral setDelegate:nil];
    [peripheral release];

    [super dealloc];
}

- (QLowEnergyController::Error)connectToDevice:(const QBluetoothUuid &)aDeviceUuid
{
    Q_ASSERT_X(managerState == OSXBluetooth::CentralManagerIdle,
               Q_FUNC_INFO, "invalid state");

    deviceUuid = aDeviceUuid;

    if (!manager) {
        managerState = OSXBluetooth::CentralManagerUpdating; // We'll have to wait for updated state.
        manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        if (!manager) {
            managerState = OSXBluetooth::CentralManagerIdle;
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to allocate a "
                                    "central manager";
            return QLowEnergyController::ConnectionError;
        }
        return QLowEnergyController::NoError;
    } else {
        return [self connectToDevice];
    }
}

- (QLowEnergyController::Error)connectToDevice
{
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid central manager (nil)");
    Q_ASSERT_X(managerState == OSXBluetooth::CentralManagerIdle,
               Q_FUNC_INFO, "invalid state");

    if ([self isConnected]) {
        qCDebug(QT_BT_OSX) << Q_FUNC_INFO << "already connected";
        delegate->connectSuccess();
        return QLowEnergyController::NoError;
    } else if (peripheral) {
        // Was retrieved already, but not connected
        // or disconnected.
        [self connectToPeripheral];
        return QLowEnergyController::NoError;
    }

    using namespace OSXBluetooth;

    // Retrieve a peripheral first ...
    ObjCScopedPointer<NSMutableArray> uuids([[NSMutableArray alloc] init]);
    if (!uuids) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to allocate identifiers";
        return QLowEnergyController::ConnectionError;
    }

#if QT_MAC_PLATFORM_SDK_EQUAL_OR_ABOVE(__MAC_10_9, __IPHONE_6_0)
    const quint128 qtUuidData(deviceUuid.toUInt128());
    // STATIC_ASSERT on sizes would be handy!
    uuid_t uuidData = {};
    std::copy(qtUuidData.data, qtUuidData.data + 16, uuidData);
    const ObjCScopedPointer<NSUUID> nsUuid([[NSUUID alloc] initWithUUIDBytes:uuidData]);
    if (!nsUuid) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to allocate NSUUID identifier";
        return QLowEnergyController::ConnectionError;
    }

    [uuids addObject:nsUuid];

    // With the latest CoreBluetooth, we can synchronously retrive peripherals:
    QT_BT_MAC_AUTORELEASEPOOL;
    NSArray *const peripherals = [manager retrievePeripheralsWithIdentifiers:uuids];
    if (!peripherals || peripherals.count != 1) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to retrive a peripheral";
        return QLowEnergyController::UnknownRemoteDeviceError;
    }

    peripheral = [static_cast<CBPeripheral *>([peripherals objectAtIndex:0]) retain];
    [self connectToPeripheral];

    return QLowEnergyController::NoError;
#else
    OSXBluetooth::CFStrongReference<CFUUIDRef> cfUuid(OSXBluetooth::cf_uuid(deviceUuid));
    if (!cfUuid) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to create CFUUID object";
        return QLowEnergyController::ConnectionError;
    }
    // TODO: With ARC this cast will be illegal:
    [uuids addObject:(id)cfUuid.data()];
    // Unfortunately, with old Core Bluetooth this call is asynchronous ...
    managerState = OSXBluetooth::CentralManagerConnecting;
    [manager retrievePeripherals:uuids];

    return QLowEnergyController::NoError;
#endif
}

- (void)connectToPeripheral
{
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid central manager (nil)");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");
    Q_ASSERT_X(managerState == OSXBluetooth::CentralManagerIdle,
               Q_FUNC_INFO, "invalid state");

    // The state is still the same - connecting.
    if ([self isConnected]) {
        qCDebug(QT_BT_OSX) << Q_FUNC_INFO << "already connected";
        delegate->connectSuccess();
    } else {
        qCDebug(QT_BT_OSX) << Q_FUNC_INFO << "trying to connect";
        managerState = OSXBluetooth::CentralManagerConnecting;
        [manager connectPeripheral:peripheral options:nil];
    }
}

- (bool)isConnected
{
    if (!peripheral)
        return false;

#if QT_MAC_PLATFORM_SDK_EQUAL_OR_ABOVE(__MAC_10_9, __IPHONE_7_0)
    return peripheral.state == CBPeripheralStateConnected;
#else
    return peripheral.isConnected;
#endif
}

- (void)disconnectFromDevice
{
    [self reset];

    if (managerState == OSXBluetooth::CentralManagerUpdating) {
        disconnectPending = true;
    } else {
        disconnectPending = false;

        if ([self isConnected])
            managerState = OSXBluetooth::CentralManagerDisconnecting;
        else
            managerState = OSXBluetooth::CentralManagerIdle;

        // We have to call -cancelPeripheralConnection: even
        // if not connected (to cancel a pending connect attempt).
        // Unfortunately, didDisconnect callback is not always called
        // (despite of Apple's docs saying it _must_).
        [manager cancelPeripheralConnection:peripheral];
    }
}

- (void)discoverServices
{
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");
    Q_ASSERT_X(managerState == OSXBluetooth::CentralManagerIdle,
               Q_FUNC_INFO, "invalid state");

    // From Apple's docs:
    //
    //"If the servicesUUIDs parameter is nil, all the available
    //services of the peripheral are returned; setting the
    //parameter to nil is considerably slower and is not recommended."
    //
    // ... but we'd like to have them all:

    [peripheral setDelegate:self];
    managerState = OSXBluetooth::CentralManagerDiscovering;
    [peripheral discoverServices:nil];
}

- (void)discoverIncludedServices
{
    using namespace OSXBluetooth;

    Q_ASSERT_X(managerState == CentralManagerIdle, Q_FUNC_INFO,
               "invalid state");
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid manager (nil)");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;

    NSArray *const services = peripheral.services;
    if (!services || !services.count) { // Actually, !services.count works in both cases, but ...
        // A peripheral without any services at all.
        Q_ASSERT_X(delegate, Q_FUNC_INFO,
                   "invalid delegate (null)");
        delegate->serviceDiscoveryFinished(ObjCStrongReference<NSArray>());
    } else {
        // 'reset' also calls retain on a parameter.
        servicesToVisitNext.reset(nil);
        servicesToVisit.reset([NSMutableArray arrayWithArray:services]);
        currentService = 0;
        visitedServices.reset([NSMutableSet setWithCapacity:peripheral.services.count]);

        CBService *const s = [services objectAtIndex:currentService];
        [visitedServices addObject:s];
        managerState = CentralManagerDiscovering;
        [peripheral discoverIncludedServices:nil forService:s];
    }
}

- (bool)discoverServiceDetails:(const QBluetoothUuid &)serviceUuid
{
    // This function does not change 'managerState', since it
    // can be called concurrently (not waiting for the previous
    // discovery to finish).

    using namespace OSXBluetooth;

    Q_ASSERT_X(managerState != CentralManagerUpdating, Q_FUNC_INFO, "invalid state");
    Q_ASSERT_X(!serviceUuid.isNull(), Q_FUNC_INFO, "invalid service UUID");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    if (servicesToDiscoverDetails.contains(serviceUuid)) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO <<"already discovering for "
                             << serviceUuid;
        return true;
    }

    QT_BT_MAC_AUTORELEASEPOOL;

    if (CBService *const service = [self serviceForUUID:serviceUuid]) {
        servicesToDiscoverDetails.append(serviceUuid);
        [peripheral discoverCharacteristics:nil forService:service];
        return true;
    }

    qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "unknown service uuid "
                         << serviceUuid;

    return false;
}

- (void)readCharacteristics:(CBService *)service
{
    // This method does not change 'managerState', we can
    // have several 'detail discoveries' active.
    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    Q_ASSERT_X(managerState != CentralManagerUpdating, Q_FUNC_INFO,
               "invalid state");
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid manager (nil)");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");
    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    if (!service.characteristics || !service.characteristics.count)
        return [self serviceDetailsDiscoveryFinished:service];

    NSArray *const cs = service.characteristics;
    for (CBCharacteristic *c in cs) {
        if (c.properties & CBCharacteristicPropertyRead)
            return [peripheral readValueForCharacteristic:c];
    }

    // No readable properties? Discover descriptors then:
    [self discoverDescriptors:service];
}

- (void)discoverDescriptors:(CBService *)service
{
    // This method does not change 'managerState', we can have
    // several discoveries active.
    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    Q_ASSERT_X(managerState != CentralManagerUpdating,
               Q_FUNC_INFO, "invalid state");
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid manager (nil)");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    if (!service.characteristics || !service.characteristics.count) {
        [self serviceDetailsDiscoveryFinished:service];
    } else {
        // Start from 0 and continue in the callback.
        [peripheral discoverDescriptorsForCharacteristic:[service.characteristics objectAtIndex:0]];
    }
}

- (void)readDescriptors:(CBService *)service
{
    Q_ASSERT_X(service, "-readDescriptors:",
               "invalid service (nil)");
    Q_ASSERT_X(managerState != OSXBluetooth::CentralManagerUpdating,
               "-readDescriptors:",
               "invalid state");
    Q_ASSERT_X(peripheral, "-readDescriptors:",
               "invalid peripheral (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;

    NSArray *const cs = service.characteristics;
    // We can never be here if we have no characteristics.
    Q_ASSERT_X(cs && cs.count, "-readDescriptors:",
               "invalid service");
    for (CBCharacteristic *c in cs) {
        if (c.descriptors && c.descriptors.count)
            return [peripheral readValueForDescriptor:[c.descriptors objectAtIndex:0]];
    }

    // No descriptors to read, done.
    [self serviceDetailsDiscoveryFinished:service];
}

- (void)serviceDetailsDiscoveryFinished:(CBService *)service
{
    //
    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");
    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    const QBluetoothUuid serviceUuid(qt_uuid(service.UUID));
    servicesToDiscoverDetails.removeAll(serviceUuid);

    const NSUInteger nHandles = qt_countGATTEntries(service);
    Q_ASSERT_X(nHandles, Q_FUNC_INFO, "unexpected number of GATT entires");

    const QLowEnergyHandle maxHandle = std::numeric_limits<QLowEnergyHandle>::max();
    if (nHandles >= maxHandle || lastValidHandle > maxHandle - nHandles) {
        // Well, that's unlikely :) But we must be sure.
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "can not allocate more handles";
        delegate->error(serviceUuid, QLowEnergyService::OperationError);
        return;
    }

    // A temporary service object to pass the details.
    // Set only uuid, characteristics and descriptors (and probably values),
    // nothing else is needed.
    QSharedPointer<QLowEnergyServicePrivate> qtService(new QLowEnergyServicePrivate);
    qtService->uuid = serviceUuid;
    // We 'register' handles/'CBentities' even if qlowenergycontroller (delegate)
    // later fails to do this with some error. Otherwise, if we try to implement
    // rollback/transaction logic interface is getting too ugly/complicated.
    ++lastValidHandle;
    serviceMap[lastValidHandle] = service;
    qtService->startHandle = lastValidHandle;

    NSArray *const cs = service.characteristics;
    // Now map chars/descriptors and handles.
    if (cs && cs.count) {
        QHash<QLowEnergyHandle, QLowEnergyServicePrivate::CharData> charList;

        for (CBCharacteristic *c in cs) {
            ++lastValidHandle;
            // Register this characteristic:
            charMap[lastValidHandle] = c;
            // Create a Qt's internal characteristic:
            QLowEnergyServicePrivate::CharData newChar = {};
            newChar.uuid = qt_uuid(c.UUID);
            const int cbProps = c.properties & 0xff;
            newChar.properties = static_cast<QLowEnergyCharacteristic::PropertyTypes>(cbProps);
            newChar.value = qt_bytearray(c.value);
            newChar.valueHandle = lastValidHandle;

            NSArray *const ds = c.descriptors;
            if (ds && ds.count) {
                QHash<QLowEnergyHandle, QLowEnergyServicePrivate::DescData> descList;
                for (CBDescriptor *d in ds) {
                    // Register this descriptor:
                    ++lastValidHandle;
                    descMap[lastValidHandle] = d;
                    // Create a Qt's internal descriptor:
                    QLowEnergyServicePrivate::DescData newDesc = {};
                    newDesc.uuid = qt_uuid(d.UUID);
                    newDesc.value = qt_bytearray(static_cast<NSObject *>(d.value));
                    descList[lastValidHandle] = newDesc;
                    // Check, if it's client characteristic configuration descriptor:
                    if (newDesc.uuid == QBluetoothUuid::ClientCharacteristicConfiguration) {
                        if (newDesc.value.size() && (newDesc.value[0] & 3))
                            [peripheral setNotifyValue:YES forCharacteristic:c];
                    }
                }

                newChar.descriptorList = descList;
            }

            charList[newChar.valueHandle] = newChar;
        }

        qtService->characteristicList = charList;
    }

    qtService->endHandle = lastValidHandle;

    ObjCStrongReference<CBService> leService(service, true);
    delegate->serviceDetailsDiscoveryFinished(qtService);
}

- (void)performNextWriteRequest
{
    using namespace OSXBluetooth;

    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    if (writePending || !writeQueue.size())
        return;

    LEWriteRequest request(writeQueue.dequeue());

    if (request.isDescriptor) {
        if (!descMap.contains(request.handle)) {
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "handle: "
                                 << request.handle << " not found";
            return [self performNextWriteRequest];
        }

        CBDescriptor *const descriptor = descMap[request.handle];
        ObjCStrongReference<NSData> data(data_from_bytearray(request.value));
        if (!data) {
            // Even if qtData.size() == 0, we still need NSData object.
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed "
                                    "to allocate an NSData object";
            return [self performNextWriteRequest];
        }

        if (![self cacheWriteValue:request.value for:descriptor])
            return [self performNextWriteRequest];

        writePending = true;
        return [peripheral writeValue:data.data() forDescriptor:descriptor];
    } else {
        if (!charMap.contains(request.handle)) {
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "characteristic with "
                                    "handle: " << request.handle << " not found";
            return [self performNextWriteRequest];
        }

        CBCharacteristic *const characteristic = charMap[request.handle];

        if (request.isClientConfiguration) {
            const QBluetoothUuid qtUuid(QBluetoothUuid::ClientCharacteristicConfiguration);
            CBDescriptor *const descriptor = [self descriptor:qtUuid forCharacteristic:characteristic];
            Q_ASSERT_X(descriptor, Q_FUNC_INFO, "no client characteristic "
                       "configuration descriptor found");

            if (![self cacheWriteValue:request.value for:descriptor])
                return [self performNextWriteRequest];

            bool enable = false;
            if (request.value.size())
                enable = request.value[0] & 3;

            writePending = true;
            [peripheral setNotifyValue:enable forCharacteristic:characteristic];
        } else {
            ObjCStrongReference<NSData> data(data_from_bytearray(request.value));
            if (!data) {
                // Even if qtData.size() == 0, we still need NSData object.
                qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to allocate NSData object";
                return [self performNextWriteRequest];
            }

            // TODO: check what happens if I'm using NSData with length 0.
            if (request.withResponse) {
                if (![self cacheWriteValue:request.value for:characteristic])
                    return [self performNextWriteRequest];

                writePending = true;
                [peripheral writeValue:data.data() forCharacteristic:characteristic
                            type:CBCharacteristicWriteWithResponse];
            } else {
                [peripheral writeValue:data.data() forCharacteristic:characteristic
                            type:CBCharacteristicWriteWithoutResponse];
                [self performNextWriteRequest];
            }
        }
    }
}

- (bool)setNotifyValue:(const QByteArray &)value
        forCharacteristic:(QT_PREPEND_NAMESPACE(QLowEnergyHandle))charHandle
{
    Q_ASSERT_X(charHandle, Q_FUNC_INFO, "invalid characteristic handle (0)");
    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    if (!charMap.contains(charHandle)) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO
                             << "unknown characteristic handle " << charHandle;
        return false;
    }

    // At the moment we call setNotifyValue _only_ from 'writeDescriptor';
    // from Qt's API POV it's a descriptor write oprtation and we must report
    // it back, so check _now_ that we really have this descriptor.
    const QBluetoothUuid qtUuid(QBluetoothUuid::ClientCharacteristicConfiguration);
    if (![self descriptor:qtUuid forCharacteristic:charMap[charHandle]]) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO
                             << "no client characteristic configuration found";
        return false;
    }

    OSXBluetooth::LEWriteRequest request;
    request.isDescriptor = false;
    request.isClientConfiguration = true;
    request.handle = charHandle;
    request.value = value;

    writeQueue.enqueue(request);
    [self performNextWriteRequest];
    // TODO: check if I need a special map - to reset notify to NO
    // before disconnect/dealloc later! Also, this can be needed if notify was set
    // to YES from another application - to be tested.
    return true;
}

- (bool)write:(const QT_PREPEND_NAMESPACE(QByteArray) &)value
        charHandle:(QT_PREPEND_NAMESPACE(QLowEnergyHandle))charHandle
        withResponse:(bool)withResponse
{
    using namespace OSXBluetooth;

    Q_ASSERT_X(charHandle, Q_FUNC_INFO, "invalid characteristic handle (0)");

    QT_BT_MAC_AUTORELEASEPOOL;

    if (!charMap.contains(charHandle)) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "characteristic: " << charHandle << " not found";
        return false;
    }

    LEWriteRequest request;
    request.isDescriptor = false;
    request.withResponse = withResponse;
    request.handle = charHandle;
    request.value = value;

    writeQueue.enqueue(request);
    [self performNextWriteRequest];
    // TODO: this is quite ugly: true value can be returned after
    // write actually. If I have any problems with the order later,
    // I'll use performSelector afterDelay with some delay.
    return true;
}

- (bool)write:(const QByteArray &)value descHandle:(QLowEnergyHandle)descHandle
{
    using namespace OSXBluetooth;

    Q_ASSERT_X(descHandle, Q_FUNC_INFO, "invalid descriptor handle (0)");

    if (!descMap.contains(descHandle)) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "handle: "
                             << descHandle << " not found";
        return false;
    }

    LEWriteRequest request;
    request.isDescriptor = true;
    request.handle = descHandle;
    request.value = value;

    writeQueue.enqueue(request);
    [self performNextWriteRequest];
    // TODO: this is quite ugly: true value can be returned after
    // write actually. If I have any problems with the order later,
    // I'll use performSelector afterDelay with some delay.
    return true;
}

// Aux. methods:

- (CBService *)serviceForUUID:(const QBluetoothUuid &)qtUuid
{
    using namespace OSXBluetooth;

    Q_ASSERT_X(!qtUuid.isNull(), Q_FUNC_INFO, "invalid uuid");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    ObjCStrongReference<NSMutableArray> toVisit([NSMutableArray arrayWithArray:peripheral.services], true);
    ObjCStrongReference<NSMutableArray> toVisitNext([[NSMutableArray alloc] init], false);
    ObjCStrongReference<NSMutableSet> visitedNodes([[NSMutableSet alloc] init], false);

    while (true) {
        for (NSUInteger i = 0, e = [toVisit count]; i < e; ++i) {
            CBService *const s = [toVisit objectAtIndex:i];
            if (equal_uuids(s.UUID, qtUuid))
                return s;
            if ([visitedNodes containsObject:s] && s.includedServices && s.includedServices.count) {
                [visitedNodes addObject:s];
                [toVisitNext addObjectsFromArray:s.includedServices];
            }
        }

        if (![toVisitNext count])
            return nil;

        toVisit.resetWithoutRetain(toVisitNext.take());
        toVisitNext.resetWithoutRetain([[NSMutableArray alloc] init]);
    }

    return nil;
}

- (CBCharacteristic *)nextCharacteristicForService:(CBService*)service
                      startingFrom:(CBCharacteristic *)characteristic
{
    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");
    Q_ASSERT_X(characteristic, Q_FUNC_INFO, "invalid characteristic (nil)");
    Q_ASSERT_X(service.characteristics, Q_FUNC_INFO, "invalid service");
    Q_ASSERT_X(service.characteristics.count, Q_FUNC_INFO, "invalid service");

    QT_BT_MAC_AUTORELEASEPOOL;

    // TODO: test that we NEVER have the same characteristic twice in array!
    // At the moment I just protect against this by iterating in a reverse
    // order (at least avoiding a potential inifite loop with '-indexOfObject:').
    NSArray *const cs = service.characteristics;
    if (cs.count == 1)
        return nil;

    for (NSUInteger index = cs.count - 1; index != 0; --index) {
        if ([cs objectAtIndex:index] == characteristic) {
            if (index + 1 == cs.count)
                return nil;
            else
                return [cs objectAtIndex:index + 1];
        }
    }

    Q_ASSERT_X([cs objectAtIndex:0] == characteristic, Q_FUNC_INFO,
               "characteristic was not found in service.characteristics");

    return [cs objectAtIndex:1];
}

- (CBCharacteristic *)nextCharacteristicForService:(CBService*)service
                      startingFrom:(CBCharacteristic *)characteristic
                      properties:(CBCharacteristicProperties)properties
{
    Q_ASSERT_X(service, Q_FUNC_INFO, "invalid service (nil)");
    Q_ASSERT_X(characteristic, Q_FUNC_INFO, "invalid characteristic (nil)");
    Q_ASSERT_X(service.characteristics, Q_FUNC_INFO, "invalid service");
    Q_ASSERT_X(service.characteristics.count, Q_FUNC_INFO, "invalid service");

    QT_BT_MAC_AUTORELEASEPOOL;

    // TODO: test that we NEVER have the same characteristic twice in array!
    // At the moment I just protect against this by iterating in a reverse
    // order (at least avoiding a potential inifite loop with '-indexOfObject:').
    NSArray *const cs = service.characteristics;
    if (cs.count == 1)
        return nil;

    NSUInteger index = cs.count - 1;
    for (; index != 0; --index) {
        if ([cs objectAtIndex:index] == characteristic) {
            if (index + 1 == cs.count) {
                return nil;
            } else {
                index += 1;
                break;
            }
        }
    }

    if (!index) {
        Q_ASSERT_X([cs objectAtIndex:0] == characteristic, Q_FUNC_INFO,
                   "characteristic not found in service.characteristics");
        index = 1;
    }

    for (const NSUInteger e = cs.count; index < e; ++index) {
        CBCharacteristic *const c = [cs objectAtIndex:index];
        if (c.properties & properties)
            return c;
    }

    return nil;
}

- (CBDescriptor *)nextDescriptorForCharacteristic:(CBCharacteristic *)characteristic
                  startingFrom:(CBDescriptor *)descriptor
{
    Q_ASSERT_X(characteristic, Q_FUNC_INFO, "invalid characteristic (nil)");
    Q_ASSERT_X(descriptor, Q_FUNC_INFO, "invalid descriptor (nil)");
    Q_ASSERT_X(characteristic.descriptors, Q_FUNC_INFO, "invalid characteristic");
    Q_ASSERT_X(characteristic.descriptors.count, Q_FUNC_INFO, "invalid characteristic");

    QT_BT_MAC_AUTORELEASEPOOL;

    NSArray *const ds = characteristic.descriptors;
    if (ds.count == 1)
        return nil;

    for (NSUInteger index = ds.count - 1; index != 0; --index) {
        if ([ds objectAtIndex:index] == descriptor) {
            if (index + 1 == ds.count)
                return nil;
            else
                return [ds objectAtIndex:index + 1];
        }
    }

    Q_ASSERT_X([ds objectAtIndex:0] == descriptor, Q_FUNC_INFO,
               "descriptor was not found in characteristic.descriptors");

    return [ds objectAtIndex:1];
}

- (CBDescriptor *)descriptor:(const QBluetoothUuid &)qtUuid
                  forCharacteristic:(CBCharacteristic *)ch
{
    if (qtUuid.isNull() || !ch)
        return nil;

    QT_BT_MAC_AUTORELEASEPOOL;

    CBDescriptor *descriptor = nil;
    NSArray *const ds = ch.descriptors;
    if (ds && ds.count) {
        for (CBDescriptor *d in ds) {
            if (OSXBluetooth::equal_uuids(d.UUID, qtUuid)) {
                descriptor = d;
                break;
            }
        }
    }

    return descriptor;
}

- (bool)cacheWriteValue:(const QByteArray &)value for:(NSObject *)obj
{
    Q_ASSERT_X(obj, Q_FUNC_INFO, "invalid object (nil)");

    if ([obj isKindOfClass:[CBCharacteristic class]]) {
        CBCharacteristic *const ch = static_cast<CBCharacteristic *>(obj);
        if (!charMap.key(ch)) {
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "unexpected "
                                    "characteristic, no handle found";
            return false;
        }
    } else if ([obj isKindOfClass:[CBDescriptor class]]) {
        CBDescriptor *const d = static_cast<CBDescriptor *>(obj);
        if (!descMap.key(d)) {
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "unexpected "
                                    "descriptor, no handle found";
            return false;
        }
    } else {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "invalid object, "
                                "characteristic or descriptor required";
        return false;
    }

    if (valuesToWrite.contains(obj)) {
        // It can be a result of some previous errors - for example,
        // we never got a callback from a previous write.
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "already has a cached value for this "
                                "object, the value will be replaced";
    }

    valuesToWrite[obj] = value;
    return true;
}

- (void)reset
{
    writePending = false;
    valuesToWrite.clear();
    writeQueue.clear();
    servicesToDiscoverDetails.clear();
    lastValidHandle = 0;
    serviceMap.clear();
    charMap.clear();
    descMap.clear();

    // TODO: also serviceToVisit/VisitNext and visitedServices ?
}

// CBCentralManagerDelegate (the real one).

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    using namespace OSXBluetooth;

    const CBCentralManagerState state = central.state;

    if (state == CBCentralManagerStateUnknown
        || state == CBCentralManagerStateResetting) {
        // We still have to wait, docs say:
        // "The current state of the central manager is unknown;
        // an update is imminent." or
        // "The connection with the system service was momentarily
        // lost; an update is imminent."
        return;
    }

    if (disconnectPending) {
        disconnectPending = false;
        managerState = OSXBluetooth::CentralManagerIdle;
        return [self disconnectFromDevice];
    }

    // Let's check some states we do not like first:
    if (state == CBCentralManagerStateUnsupported || state == CBCentralManagerStateUnauthorized) {
        if (managerState == CentralManagerUpdating) {
            // We tried to connect just to realize, LE is not supported. Report this.
            managerState = CentralManagerIdle;
            delegate->LEnotSupported();
        } else {
            // TODO: if we are here, LE _was_ supported and we first managed to update
            // and reset managerState from CentralManagerUpdating.
            managerState = CentralManagerIdle;
            delegate->error(QLowEnergyController::InvalidBluetoothAdapterError);
        }
        return;
    }

    if (state == CBCentralManagerStatePoweredOff) {
        if (managerState == CentralManagerUpdating) {
            // I've seen this instead of Unsopported on OS X.
            managerState = CentralManagerIdle;
            delegate->LEnotSupported();
        } else {
            managerState = CentralManagerIdle;
            // TODO: we need a better error +
            // what will happen if later the state changes to PoweredOn???
            delegate->error(QLowEnergyController::InvalidBluetoothAdapterError);
        }
        return;
    }

    if (state == CBCentralManagerStatePoweredOn) {
        if (managerState == CentralManagerUpdating) {
            managerState = CentralManagerIdle;
            const QLowEnergyController::Error status = [self connectToDevice];
            if (status != QLowEnergyController::NoError)// An allocation problem?
                delegate->error(status);
        }
    } else {
        // We actually handled all known states, but .. Core Bluetooth can change?
        Q_ASSERT_X(0, Q_FUNC_INFO, "invalid centra's state");
    }
}

- (void)centralManager:(CBCentralManager *)central didRetrievePeripherals:(NSArray *)peripherals
{
    Q_UNUSED(central)

    // This method is required for iOS before 7.0 and OS X below 10.9.
    Q_ASSERT_X(manager, Q_FUNC_INFO, "invalid central manager (nil)");

    if (managerState != OSXBluetooth::CentralManagerConnecting) {
        // Canceled by calling -disconnectFromDevice method.
        return;
    }

    managerState = OSXBluetooth::CentralManagerIdle;

    if (!peripherals || peripherals.count != 1) {
        Q_ASSERT_X(delegate, Q_FUNC_INFO,
                   "invalid delegate (null)");

        qCDebug(QT_BT_OSX) << Q_FUNC_INFO <<"unexpected number of peripherals (!= 1)";

        delegate->error(QLowEnergyController::UnknownRemoteDeviceError);
    } else {
        peripheral = [static_cast<CBPeripheral *>([peripherals objectAtIndex:0]) retain];
        [self connectToPeripheral];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)aPeripheral
{
    Q_UNUSED(central)
    Q_UNUSED(aPeripheral)

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    if (managerState != OSXBluetooth::CentralManagerConnecting) {
        // We called cancel but before disconnected, managed to connect?
        return;
    }

    managerState = OSXBluetooth::CentralManagerIdle;
    delegate->connectSuccess();
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)aPeripheral
        error:(NSError *)error
{
    Q_UNUSED(central)
    Q_UNUSED(aPeripheral)
    Q_UNUSED(error)

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    if (managerState != OSXBluetooth::CentralManagerConnecting) {
        // Canceled already.
        return;
    }

    managerState = OSXBluetooth::CentralManagerIdle;
    // TODO: better error mapping is required.
    delegate->error(QLowEnergyController::UnknownRemoteDeviceError);
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)aPeripheral
        error:(NSError *)error
{
    Q_UNUSED(central)
    Q_UNUSED(aPeripheral)

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    // Clear internal caches/data.
    [self reset];

    if (error && managerState == OSXBluetooth::CentralManagerDisconnecting) {
        managerState = OSXBluetooth::CentralManagerIdle;
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "failed to disconnect";
        // TODO: instead of 'unknown' - .. ?
        delegate->error(QLowEnergyController::UnknownRemoteDeviceError);
    } else {
        managerState = OSXBluetooth::CentralManagerIdle;
        delegate->disconnected();
    }
}

// CBPeripheralDelegate.

- (void)peripheral:(CBPeripheral *)aPeripheral didDiscoverServices:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    if (managerState != OSXBluetooth::CentralManagerDiscovering) {
        // Canceled by -disconnectFromDevice.
        return;
    }

    managerState = OSXBluetooth::CentralManagerIdle;

    if (error) {
        // NSLog, not qCDebug/Warning - to print the error.
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        // TODO: better error mapping required.
        delegate->error(QLowEnergyController::UnknownError);
    } else {
        [self discoverIncludedServices];
    }
}


- (void)peripheral:(CBPeripheral *)aPeripheral didDiscoverIncludedServicesForService:(CBService *)service
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    using namespace OSXBluetooth;

    if (managerState != CentralManagerDiscovering) {
        // Canceled by disconnectFromDevice or -peripheralDidDisconnect...
        return;
    }

    QT_BT_MAC_AUTORELEASEPOOL;

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");
    // TODO: asserts on other "pointers" ...

    managerState = CentralManagerIdle;

    if (error) {
        // NSLog, not qCWarning/Critical - to log the actual NSError and service UUID.
        NSLog(@"%s: finished with error %@ for service %@",
              Q_FUNC_INFO, error, service.UUID);
    } else if (service.includedServices && service.includedServices.count) {
        // Now we have even more services to do included services discovery ...
        if (!servicesToVisitNext)
            servicesToVisitNext.reset([NSMutableArray arrayWithArray:service.includedServices]);
        else
            [servicesToVisitNext addObjectsFromArray:service.includedServices];
    }

    // Do we have something else to discover on this 'level'?
    ++currentService;

    for (const NSUInteger e = [servicesToVisit count]; currentService < e; ++currentService) {
        CBService *const s = [servicesToVisit objectAtIndex:currentService];
        if (![visitedServices containsObject:s]) {
            // Continue with discovery ...
            [visitedServices addObject:s];
            managerState = CentralManagerDiscovering;
            return [peripheral discoverIncludedServices:nil forService:s];
        }
    }

    // No services to visit more on this 'level'.

    if (servicesToVisitNext && [servicesToVisitNext count]) {
        servicesToVisit.resetWithoutRetain(servicesToVisitNext.take());

        currentService = 0;
        for (const NSUInteger e = [servicesToVisit count]; currentService < e; ++currentService) {
            CBService *const s = [servicesToVisit objectAtIndex:currentService];
            if (![visitedServices containsObject:s]) {
                [visitedServices addObject:s];
                managerState = CentralManagerDiscovering;
                return [peripheral discoverIncludedServices:nil forService:s];
            }
        }
    }

    // Finally, if we're here, the service discovery is done!

    // Release all these things now, no need to prolong their lifetime.
    visitedServices.reset(nil);
    servicesToVisit.reset(nil);
    servicesToVisitNext.reset(nil);

    const ObjCStrongReference<NSArray> services(peripheral.services, true); // true == retain.
    delegate->serviceDiscoveryFinished(services);
}

- (void)peripheral:(CBPeripheral *)aPeripheral didDiscoverCharacteristicsForService:(CBService *)service
        error:(NSError *)error
{
    // This method does not change 'managerState', we can have several
    // discoveries active.
    Q_UNUSED(aPeripheral)

    // TODO: check that this can never be called after cancelPeripheralConnection was executed.

    using namespace OSXBluetooth;

    Q_ASSERT_X(managerState != CentralManagerUpdating,
               Q_FUNC_INFO, "invalid state");
    Q_ASSERT_X(delegate, Q_FUNC_INFO,
               "invalid delegate (null)");

    if (error) {
        // NSLog to show the actual NSError (can contain something interesting).
        NSLog(@"%s failed with error: %@", Q_FUNC_INFO, error);
        // We did not discover any characteristics and can not discover descriptors,
        // inform our delegate (it will set a service state also).
        delegate->error(qt_uuid(service.UUID), QLowEnergyController::UnknownError);
    } else {
        [self readCharacteristics:service];
    }
}

- (void)peripheral:(CBPeripheral *)aPeripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    using namespace OSXBluetooth;

    Q_ASSERT_X(managerState != CentralManagerUpdating, Q_FUNC_INFO, "invalid state");
    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;
    // First, let's check if we're discovering a service details now.
    CBService *const service = characteristic.service;
    const QBluetoothUuid qtUuid(qt_uuid(service.UUID));
    const bool isDetailsDiscovery = servicesToDiscoverDetails.contains(qtUuid);

    if (error) {
        // Use NSLog, not qCDebug/qCWarning to log the actual error.
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        if (!isDetailsDiscovery) {
            // TODO: this can be something else in a future (if needed at all).
            return;
        }
    }

    if (isDetailsDiscovery) {
        // Test if we have any other characteristic to read yet.
        CBCharacteristic *const next = [self nextCharacteristicForService:characteristic.service
                                             startingFrom:characteristic properties:CBCharacteristicPropertyRead];
        if (next)
            [peripheral readValueForCharacteristic:next];
        else
            [self discoverDescriptors:characteristic.service];
    } else {
        // This is (probably) the result of update notification.
        const QLowEnergyHandle chHandle = charMap.key(characteristic);
        // It's very possible we can have an invalid handle here (0) -
        // if something esle is wrong (we subscribed for a notification),
        // disconnected (but other application is connected) and still receiveing
        // updated values ...
        // TODO: this must be properly tested.
        if (!chHandle) {
            qCCritical(QT_BT_OSX) << Q_FUNC_INFO << "unexpected update notification, "
                                     "no characteristic handle found";
            return;
        }

        Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");
        delegate->characteristicUpdateNotification(chHandle,
                                                   qt_bytearray(characteristic.value));
    }
}

- (void)peripheral:(CBPeripheral *)aPeripheral
        didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
        error:(NSError *)error
{
    // This method does not change 'managerState', we can
    // have several discoveries active at the same time.
    Q_UNUSED(aPeripheral)

    QT_BT_MAC_AUTORELEASEPOOL;

    using namespace OSXBluetooth;

    if (error) {
        // Log the error using NSLog:
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        // Probably, we can continue though ...
    }

    // Do we have more characteristics on this service to discover descriptors?
    CBCharacteristic *const next = [self nextCharacteristicForService:characteristic.service
                                         startingFrom:characteristic];
    if (next)
        [peripheral discoverDescriptorsForCharacteristic:next];
    else
        [self readDescriptors:characteristic.service];
}

- (void)peripheral:(CBPeripheral *)aPeripheral
        didUpdateValueForDescriptor:(CBDescriptor *)descriptor
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    Q_ASSERT_X(peripheral, Q_FUNC_INFO, "invalid peripheral (nil)");

    QT_BT_MAC_AUTORELEASEPOOL;

    using namespace OSXBluetooth;

    CBService *const service = descriptor.characteristic.service;
    const QBluetoothUuid qtUuid(qt_uuid(service.UUID));
    const bool isDetailsDiscovery = servicesToDiscoverDetails.contains(qtUuid);

    if (error) {
        // NSLog to log the actual error ...
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        if (!isDetailsDiscovery) {
            // TODO: probably will be required in a future.
            return;
        }
    }

    if (isDetailsDiscovery) {
        // Test if we have any other characteristic to read yet.
        CBDescriptor *const next = [self nextDescriptorForCharacteristic:descriptor.characteristic
                                         startingFrom:descriptor];
        if (next) {
            [peripheral readValueForDescriptor:next];
        } else {
            // We either have to read a value for a next descriptor
            // on a given characteristic, or continue with the
            // next characteristic in a given service (if any).
            CBCharacteristic *const ch = descriptor.characteristic;
            CBCharacteristic *nextCh = [self nextCharacteristicForService:ch.service
                                             startingFrom:ch];
            while (nextCh) {
                if (nextCh.descriptors && nextCh.descriptors.count)
                    return [peripheral readValueForDescriptor:[nextCh.descriptors objectAtIndex:0]];

                nextCh = [self nextCharacteristicForService:ch.service
                               startingFrom:nextCh];
            }

            [self serviceDetailsDiscoveryFinished:service];
        }
    } else {
        // TODO: this can be something else in a future (if needed at all).
    }
}

- (void)peripheral:(CBPeripheral *)aPeripheral
        didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)
    Q_UNUSED(characteristic)

    // From docs:
    //
    // "This method is invoked only when your app calls the writeValue:forCharacteristic:type:
    //  method with the CBCharacteristicWriteWithResponse constant specified as the write type.
    //  If successful, the error parameter is nil. If unsuccessful,
    //  the error parameter returns the cause of the failure."

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    writePending = false;

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");


    // Error or not, but the cached value has to be deleted ...
    const QByteArray valueToReport(valuesToWrite.value(characteristic, QByteArray()));
    if (!valuesToWrite.remove(characteristic)) {
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "no updated value found"
                                " for characteristic";
    }

    if (error) {
        // Use NSLog to log the actual error:
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        delegate->error(qt_uuid(characteristic.service.UUID),
                        QLowEnergyService::CharacteristicWriteError);
    } else {
        // Keys are unique.
        const QLowEnergyHandle cHandle = charMap.key(characteristic);
        Q_ASSERT_X(cHandle, Q_FUNC_INFO, "invalid handle, not found in the characteristics map");
        delegate->characteristicWriteNotification(cHandle, valueToReport);
    }

    [self performNextWriteRequest];
}

- (void)peripheral:(CBPeripheral *)aPeripheral
        didWriteValueForDescriptor:(CBDescriptor *)descriptor
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (null)");

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    writePending = false;

    using namespace OSXBluetooth;

    // Error or not, a value (if any) must be removed.
    const QByteArray valueToReport(valuesToWrite.value(descriptor, QByteArray()));
    if (!valuesToWrite.remove(descriptor))
        qCWarning(QT_BT_OSX) << Q_FUNC_INFO << "no updated value found";

    if (error) {
        // NSLog to log the actual NSError:
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        delegate->error(qt_uuid(descriptor.characteristic.service.UUID),
                        QLowEnergyService::DescriptorWriteError);
    } else {
        const QLowEnergyHandle dHandle = descMap.key(descriptor);
        Q_ASSERT_X(dHandle, Q_FUNC_INFO,
                   "descriptor not found in the descriptors map");
        delegate->descriptorWriteNotification(dHandle, valueToReport);
    }

    [self performNextWriteRequest];
}

- (void)peripheral:(CBPeripheral *)aPeripheral
        didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
        error:(NSError *)error
{
    Q_UNUSED(aPeripheral)

    using namespace OSXBluetooth;

    QT_BT_MAC_AUTORELEASEPOOL;

    writePending = false;

    Q_ASSERT_X(delegate, Q_FUNC_INFO, "invalid delegate (nil)");

    const QBluetoothUuid qtUuid(QBluetoothUuid::ClientCharacteristicConfiguration);
    CBDescriptor *const descriptor = [self descriptor:qtUuid forCharacteristic:characteristic];
    const QByteArray valueToReport(valuesToWrite.value(descriptor, QByteArray()));
    const int nRemoved = valuesToWrite.remove(descriptor);

    if (error) {
        // NSLog to log the actual NSError:
        NSLog(@"%s failed with error %@", Q_FUNC_INFO, error);
        delegate->error(qt_uuid(characteristic.service.UUID),
                        // In Qt's API it's a descriptor write actually.
                        QLowEnergyService::DescriptorWriteError);
    } else {
        if (nRemoved) {
            const QLowEnergyHandle dHandle = descMap.key(descriptor);
            delegate->descriptorWriteNotification(dHandle, valueToReport);
        } else {
            /*
            qCWarning(QT_BT_OSX) << Q_FUNC_INFO << ": notification value set to "
                                 << int(characteristic.isNotifying)
                                 << " but no client characteristic configuration descriptor found"
                                    " or no previous writeDescriptor request found";
            */
        }
    }

    [self performNextWriteRequest];
}

@end
