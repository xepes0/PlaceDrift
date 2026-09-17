#ifndef PLACEDRIFT_GEOSERVICES_REGION_BRIDGE_H
#define PLACEDRIFT_GEOSERVICES_REGION_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

bool placedrift_geoservices_get_country_code(char *buffer, size_t buffer_length);
bool placedrift_geoservices_set_country_code(
    const char *country_code,
    char *error_buffer,
    size_t error_buffer_length
);

#ifdef __cplusplus
}
#endif

#endif
