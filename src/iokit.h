// The iOS SDK ships IOKit without headers, so declare the handful of calls we use.
#ifndef MOTIONWAKE_IOKIT_H
#define MOTIONWAKE_IOKIT_H

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;
typedef io_object_t io_iterator_t;
typedef char io_name_t[128];
typedef kern_return_t IOReturn;

extern const mach_port_t kIOMasterPortDefault;

CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t master, CFDictionaryRef matching);
kern_return_t IOServiceGetMatchingServices(mach_port_t master, CFDictionaryRef matching, io_iterator_t *it);
io_object_t IOIteratorNext(io_iterator_t it);
kern_return_t IORegistryCreateIterator(mach_port_t master, const io_name_t plane, uint32_t options, io_iterator_t *it);
kern_return_t IORegistryEntryCreateCFProperties(io_registry_entry_t entry, CFMutableDictionaryRef *props,
                                                CFAllocatorRef alloc, uint32_t options);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef alloc,
                                          uint32_t options);
kern_return_t IORegistryEntrySetCFProperties(io_registry_entry_t entry, CFTypeRef props);
kern_return_t IORegistryEntrySetCFProperty(io_registry_entry_t entry, CFStringRef key, CFTypeRef value);
kern_return_t IORegistryEntryGetName(io_registry_entry_t entry, io_name_t name);
kern_return_t IORegistryEntryGetParentEntry(io_registry_entry_t entry, const io_name_t plane,
                                            io_registry_entry_t *parent);
kern_return_t IOObjectGetClass(io_object_t object, io_name_t name);
boolean_t IOObjectConformsTo(io_object_t object, const io_name_t className);
kern_return_t IOObjectRelease(io_object_t object);

#define kIORegistryIterateRecursively 0x00000001

// IOPMLib: powerd assertions, dropped by powerd when the holder exits.
typedef uint32_t IOPMAssertionID;
IOReturn IOPMAssertionCreateWithName(CFStringRef type, uint32_t level, CFStringRef name, IOPMAssertionID *id);
IOReturn IOPMAssertionRelease(IOPMAssertionID id);
IOReturn IOPMCopyAssertionsStatus(CFDictionaryRef *status);
IOReturn IOPMCopyAssertionsByProcess(CFDictionaryRef *byPID);
#define kIOPMAssertionLevelOn 255

// System sleep/wake notifications. Will-sleep and can-sleep must be acknowledged.
typedef mach_port_t io_connect_t;
typedef struct IONotificationPort *IONotificationPortRef;
typedef void (*IOServiceInterestCallback)(void *refcon, io_service_t service, uint32_t type, void *arg);
io_connect_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *port, IOServiceInterestCallback callback,
                                      io_object_t *notifier);
IOReturn IOAllowPowerChange(io_connect_t kernelPort, intptr_t notificationID);
CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef port);
#define kIOMessageCanSystemSleep 0xe0000270
#define kIOMessageSystemWillSleep 0xe0000280
#define kIOMessageSystemHasPoweredOn 0xe0000300

// IOPowerSources: the battery as powerd reports it (percent matches the status bar).
typedef void (*IOPowerSourceCallbackType)(void *context);
CFTypeRef IOPSCopyPowerSourcesInfo(void);
CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);
CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback, void *context);

#endif
