#ifndef SENSORS_H
#define SENSORS_H

#include <stdint.h>

typedef struct {
    char   name[96];
    double value;      /* Celsius */
} TempSensor;

/* Enumerate all AppleVendor temperature sensors.
   Returns number written into out (max entries). */
int sensors_read_temperatures(TempSensor *out, int max);

/* System load in milliwatts from AppleSmartBattery->PowerTelemetryData.
   Returns -1 if unavailable. */
double sensors_system_mw(void);

/* SMC PZC0 chip/package power in watts; NAN when unavailable.
   Read only while the details menu is open. Not CPU+GPU+ANE energy sum. */
double sensors_chip_w(void);

/* 1 if running on AC power. */
int sensors_on_ac(void);

/* Pointer to the sensor's name buffer (valid while the struct lives). */
const char *sensor_name(const TempSensor *s);

/* Battery charge/discharge power in watts (positive = charging). NAN if unknown. */
double sensors_battery_w(void);

/* Current AppleCLPC package thermal power cap in watts, or -1.0 if disabled/unavailable. */
double sensors_pkg_power_cap_w(void);

/* Current AGX MaxGPUAbsolutePower in mW, or -1 if unavailable. */
int64_t sensors_gpu_power_cap_mw(void);

/* Current IOPMrootDomain SleepDisabled state: 1 = disabled, 0 = normal, -1 = unavailable. */
int sensors_sleep_disabled(void);

#endif
