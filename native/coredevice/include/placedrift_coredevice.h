#ifndef PLACEDRIFT_COREDEVICE_H
#define PLACEDRIFT_COREDEVICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlaceDriftPairingSession PlaceDriftPairingSession;
typedef struct PlaceDriftLocationSession PlaceDriftLocationSession;

typedef struct {
    int32_t code;
    uint32_t failure_stage;
} PlaceDriftEngineStatus;

typedef struct {
    char *error_message;
    uint32_t failure_stage;
    uint8_t *pairing_record;
    size_t pairing_record_length;
    char *device_name;
    char *device_model;
} PlaceDriftPairingResult;

typedef struct {
    char *error_message;
    uint32_t failure_stage;
} PlaceDriftLocationResult;

typedef void (*PlaceDriftPairingReadyCallback)(
    void *context,
    const char *service_identifier,
    uint16_t port,
    const char *const *txt_keys,
    const char *const *txt_values,
    size_t txt_count
);

typedef void (*PlaceDriftPairingPinCallback)(void *context, const char *pin);
typedef void (*PlaceDriftLocationStartedCallback)(void *context);

PlaceDriftEngineStatus placedrift_coredevice_validate_coordinates(double latitude, double longitude);

PlaceDriftPairingSession *placedrift_pairing_session_create(void);
void placedrift_pairing_session_cancel(PlaceDriftPairingSession *session);
void placedrift_pairing_session_destroy(PlaceDriftPairingSession *session);
int32_t placedrift_pairing_session_run(
    PlaceDriftPairingSession *session,
    PlaceDriftPairingReadyCallback ready_callback,
    PlaceDriftPairingPinCallback pin_callback,
    void *context,
    PlaceDriftPairingResult *result
);
void placedrift_pairing_result_destroy(PlaceDriftPairingResult *result);
int32_t placedrift_pairing_record_matches_service(
    const uint8_t *pairing_record,
    size_t pairing_record_length,
    const char *service_identifier,
    const char *auth_tag
);

PlaceDriftLocationSession *placedrift_location_session_create(void);
int32_t placedrift_location_session_update(
    PlaceDriftLocationSession *session,
    double latitude,
    double longitude
);
void placedrift_location_session_cancel(PlaceDriftLocationSession *session);
void placedrift_location_session_destroy(PlaceDriftLocationSession *session);
int32_t placedrift_location_session_run(
    PlaceDriftLocationSession *session,
    const uint8_t *pairing_record,
    size_t pairing_record_length,
    const char *peer_address,
    uint16_t remote_pairing_port,
    const char *service_identifier,
    const char *auth_tag,
    double latitude,
    double longitude,
    PlaceDriftLocationStartedCallback started_callback,
    void *context,
    PlaceDriftLocationResult *result
);
void placedrift_location_result_destroy(PlaceDriftLocationResult *result);

#ifdef __cplusplus
}
#endif

#endif
