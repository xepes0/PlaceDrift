#import "GeoServicesRegionBridge.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void placedrift_copy_string(NSString *value, char *buffer, size_t length) {
    if (!buffer || length == 0) return;
    buffer[0] = '\0';
    if (!value.length) return;
    const char *utf8 = value.UTF8String;
    if (!utf8) return;
    snprintf(buffer, length, "%s", utf8);
}

static void placedrift_set_error(NSString *message, char *buffer, size_t length) {
    placedrift_copy_string(message ?: @"Unknown GeoServices error", buffer, length);
}

static BOOL placedrift_load_geoservices(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded = NO;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/GeoServices.framework/GeoServices",
            RTLD_LAZY | RTLD_LOCAL
        );
        loaded = (handle != NULL);
    });
    return loaded;
}

static id placedrift_country_info_class(void) {
    if (!placedrift_load_geoservices()) return Nil;
    return NSClassFromString(@"_GEOCountryConfigurationInfo");
}

static NSString *placedrift_read_country_code(void) {
    Class cls = placedrift_country_info_class();
    if (!cls) return nil;

    SEL getSelector = NSSelectorFromString(@"get");
    if (![cls respondsToSelector:getSelector]) return nil;

    id (*sendGet)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id info = sendGet(cls, getSelector);
    if (!info) return nil;

    SEL countrySelector = NSSelectorFromString(@"countryCode");
    if (![info respondsToSelector:countrySelector]) return nil;

    id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id value = sendObject(info, countrySelector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

bool placedrift_geoservices_get_country_code(char *buffer, size_t buffer_length) {
    @autoreleasepool {
        NSString *code = placedrift_read_country_code();
        if (!code.length) {
            if (buffer && buffer_length > 0) buffer[0] = '\0';
            return false;
        }
        placedrift_copy_string(code, buffer, buffer_length);
        return true;
    }
}

bool placedrift_geoservices_set_country_code(
    const char *country_code,
    char *error_buffer,
    size_t error_buffer_length
) {
    @autoreleasepool {
        if (!country_code || strlen(country_code) != 2) {
            placedrift_set_error(@"Country code must be a two-letter ISO code.", error_buffer, error_buffer_length);
            return false;
        }

        NSString *code = [[NSString stringWithUTF8String:country_code] uppercaseString];
        if (code.length != 2) {
            placedrift_set_error(@"Country code could not be decoded.", error_buffer, error_buffer_length);
            return false;
        }

        Class cls = placedrift_country_info_class();
        if (!cls) {
            placedrift_set_error(@"GeoServices private framework or country configuration class is unavailable.", error_buffer, error_buffer_length);
            return false;
        }

        SEL allocSelector = sel_registerName("alloc");
        SEL initSelector = NSSelectorFromString(@"initWithCountryCode:source:");
        SEL setSelector = NSSelectorFromString(@"set");

        id (*sendAlloc)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id allocated = sendAlloc(cls, allocSelector);
        if (!allocated || ![allocated respondsToSelector:initSelector]) {
            placedrift_set_error(@"GeoServices country configuration initializer is unavailable.", error_buffer, error_buffer_length);
            return false;
        }

        // Source 260 is the GEOIP country source used by GeoServices itself when it
        // constructs _GEOCountryConfigurationInfo from a network country response.
        id (*sendInit)(id, SEL, id, unsigned int) = (id (*)(id, SEL, id, unsigned int))objc_msgSend;
        id info = sendInit(allocated, initSelector, code, 260);
        if (!info || ![info respondsToSelector:setSelector]) {
            placedrift_set_error(@"GeoServices country configuration object could not be created.", error_buffer, error_buffer_length);
            return false;
        }

        void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        sendVoid(info, setSelector);

        // Maps and other GeoServices clients observe this Darwin notification. The
        // experiments notification is also nudged because regional manifests and
        // feature gates can be cached independently from the country code itself.
        notify_post("com.apple.GeoServices.countryCodeChanged");
        notify_post("com.apple.GeoServices.experimentsChanged");

        NSString *readBack = placedrift_read_country_code();
        if (![readBack isEqualToString:code]) {
            NSString *message = readBack.length
                ? [NSString stringWithFormat:@"GeoServices read-back is %@ instead of %@.", readBack, code]
                : @"GeoServices did not return a country code after the write.";
            placedrift_set_error(message, error_buffer, error_buffer_length);
            return false;
        }

        if (error_buffer && error_buffer_length > 0) error_buffer[0] = '\0';
        return true;
    }
}
