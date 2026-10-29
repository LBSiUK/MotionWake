// Shared by the daemon and the app: settings, battery state and where things live.
#ifndef MOTIONWAKE_H
#define MOTIONWAKE_H

#include <stdbool.h>

#define MW_PREFS_PATH "/var/mobile/Library/Preferences/uk.lbsi.motionwake.plist"
#define MW_LOG_PATH "/var/mobile/Library/Logs/MotionWake.log"
#define MW_NOTIFY_PREFS "uk.lbsi.motionwake.prefs-changed"
#define MW_PID_PATH "/var/run/motionwaked.pid"
// The daemon answers GET /status here (loopback only) for the app and the dashboard page.
#define MW_STATUS_PORT 8095

#define MW_DEFAULT_TIMEOUT 120 // seconds of stillness before the screen goes off
#define MW_MIN_TIMEOUT 30
#define MW_MAX_TIMEOUT 900
#define MW_DEFAULT_SENSITIVITY 50
#define MW_DEFAULT_SLEEP_BELOW 30
#define MW_MIN_SLEEP_BELOW 5
#define MW_MAX_SLEEP_BELOW 90

typedef struct {
    bool enabled;    // watch the room while on the charger
    int timeout;     // seconds without movement before the screen goes off
    int sensitivity; // 1-100
    bool show_dot;   // the dashboard shows when the camera sees movement (on while this is being tuned)
    bool sleep_low;  // on battery, sleep the iPad at sleep_below
    int sleep_below; // percent
} mw_prefs;

typedef struct {
    int percent;   // as the status bar shows it
    bool external; // plugged into power
} mw_battery;

void mw_prefs_load(mw_prefs *p);
bool mw_prefs_save(const mw_prefs *p); // also tells the daemon
void mw_prefs_clamp(mw_prefs *p);

bool mw_battery_read(mw_battery *b);

// How much of the picture must change, and by how much, for the given sensitivity.
float mw_needed_percent(int sensitivity);
int mw_cell_threshold(int sensitivity);

#endif
