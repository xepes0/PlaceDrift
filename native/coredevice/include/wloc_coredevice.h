#ifndef WLOC_COREDEVICE_H
#define WLOC_COREDEVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WLOCPairingSession WLOCPairingSession;
typedef struct WLOCLocationSession WLOCLocationSession;

typedef struct {
    int32_t code;
    uint32_t failure_stage;
} WLOCEngineStatus;

typedef struct {
    char *error_message;
    uint32_t failure_stage;
    uint8_t *pairing_record;
    size_t pairing_record_length;
    char *device_name;
    char *device_model;
} WLOCPairingResult;

typedef struct {
    char *error_message;
    uint32_t failure_stage;
} WLOCLocationResult;

typedef void (*WLOCPairingReadyCallback)(
    void *context,
    const char *service_identifier,
    uint16_t port,
    const char *const *txt_keys,
    const char *const *txt_values,
    size_t txt_count
);

typedef void (*WLOCPairingPinCallback)(void *context, const char *pin);
typedef void (*WLOCLocationStartedCallback)(void *context);

WLOCEngineStatus wloc_coredevice_validate_coordinates(double latitude, double longitude);

WLOCPairingSession *wloc_pairing_session_create(void);
void wloc_pairing_session_cancel(WLOCPairingSession *session);
void wloc_pairing_session_destroy(WLOCPairingSession *session);
int32_t wloc_pairing_session_run(
    WLOCPairingSession *session,
    WLOCPairingReadyCallback ready_callback,
    WLOCPairingPinCallback pin_callback,
    void *context,
    WLOCPairingResult *result
);
void wloc_pairing_result_destroy(WLOCPairingResult *result);
int32_t wloc_pairing_record_matches_service(
    const uint8_t *pairing_record,
    size_t pairing_record_length,
    const char *service_identifier,
    const char *auth_tag
);

WLOCLocationSession *wloc_location_session_create(void);
int32_t wloc_location_session_update(
    WLOCLocationSession *session,
    double latitude,
    double longitude
);
void wloc_location_session_cancel(WLOCLocationSession *session);
void wloc_location_session_destroy(WLOCLocationSession *session);
int32_t wloc_location_session_run(
    WLOCLocationSession *session,
    const uint8_t *pairing_record,
    size_t pairing_record_length,
    const char *peer_address,
    uint16_t remote_pairing_port,
    const char *service_identifier,
    const char *auth_tag,
    double latitude,
    double longitude,
    WLOCLocationStartedCallback started_callback,
    void *context,
    WLOCLocationResult *result
);
void wloc_location_result_destroy(WLOCLocationResult *result);

#ifdef __cplusplus
}
#endif

#endif
