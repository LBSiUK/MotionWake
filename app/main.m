// MotionWake.app: what the camera sees right now, and the settings.
#import <UIKit/UIKit.h>
#include "../src/motionwake.h"

static UIColor *rgb(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

static NSString *duration(int seconds) {
    if (seconds < 60) return [NSString stringWithFormat:@"%d s", seconds];
    if (seconds % 60 == 0) return [NSString stringWithFormat:@"%d min", seconds / 60];
    return [NSString stringWithFormat:@"%d min %d s", seconds / 60, seconds % 60];
}

// How much of the picture changed in the last frame, with a tick at the amount that counts as movement.
@interface LevelBar : UIView
@property (nonatomic) float level, needed;
@end

@implementation LevelBar
- (void)drawRect:(CGRect)rect {
    CGRect track = self.bounds;
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:track cornerRadius:track.size.height / 2];
    [rgb(0xDADADF) setFill];
    [shape fill];
    [shape addClip];
    float scale = MAX(self.needed * 3, 10); // the tick sits a third of the way along
    CGRect fill = track;
    fill.size.width = round(track.size.width * MIN(1, self.level / scale));
    [(self.level >= self.needed ? rgb(0x4CD964) : rgb(0x8E8E93)) setFill];
    UIRectFill(fill);
    [rgb(0x1C1C1E) setFill];
    UIRectFill(CGRectMake(round(track.size.width * self.needed / scale) - 1, 0, 2, track.size.height));
}
@end

// A full-width slider that lines up with the text in the cells around it.
@interface SliderCell : UITableViewCell
@property (strong, nonatomic) UISlider *slider;
@end

@implementation SliderCell
- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets m = self.contentView.layoutMargins;
    CGRect b = self.contentView.bounds;
    self.slider.frame = CGRectMake(m.left, 0, b.size.width - m.left - m.right, b.size.height);
}
@end

enum { SecMotion, SecBattery, SecCount };
enum { RowEnabled, RowTimeout, RowTimeoutSlider, RowSensitivity, RowSensitivitySlider, RowDot, MotionRows };
enum { RowSleepLow, RowSleepBelow, RowSleepSlider, BatteryRows };

@interface SettingsController : UITableViewController
- (void)reloadPrefs;
@end

@implementation SettingsController {
    mw_prefs _prefs;
    NSDictionary *_status;
    UILabel *_stateLabel, *_detailLabel;
    UIView *_dot;
    LevelBar *_bar;
    UISwitch *_enabled, *_showDot, *_sleepLow;
    UISlider *_timeout, *_sensitivity, *_sleepBelow;
    NSArray *_motionCells, *_batteryCells;
    NSTimer *_timer;
    NSURLSession *_http;
    BOOL _asking;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) self.title = @"MotionWake";
    return self;
}

- (UITableViewCell *)cell:(NSString *)title {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.text = title;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)cell:(NSString *)title switch:(UISwitch *)sw {
    UITableViewCell *c = [self cell:title];
    [sw addTarget:self action:@selector(toggled) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (SliderCell *)sliderCell:(UISlider *)slider min:(float)min max:(float)max {
    slider.minimumValue = min;
    slider.maximumValue = max;
    [slider addTarget:self action:@selector(sliding) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(slid)
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    SliderCell *c = [[SliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.slider = slider;
    [c.contentView addSubview:slider];
    return c;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 2;
    _http = [NSURLSession sessionWithConfiguration:cfg];

    _enabled = [UISwitch new];
    _showDot = [UISwitch new];
    _sleepLow = [UISwitch new];
    _timeout = [UISlider new];
    _sensitivity = [UISlider new];
    _sleepBelow = [UISlider new];
    _motionCells = @[ [self cell:@"Wake on movement" switch:_enabled], [self cell:@"Screen off after"],
                      [self sliderCell:_timeout min:MW_MIN_TIMEOUT max:MW_MAX_TIMEOUT], [self cell:@"Sensitivity"],
                      [self sliderCell:_sensitivity min:1 max:100], [self cell:@"Show movement on the dashboard" switch:_showDot] ];
    _batteryCells = @[ [self cell:@"Sleep on low battery" switch:_sleepLow], [self cell:@"Sleep at"],
                       [self sliderCell:_sleepBelow min:MW_MIN_SLEEP_BELOW max:MW_MAX_SLEEP_BELOW] ];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 150)];
    _stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 30, 320, 44)];
    _stateLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightLight];
    _detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 78, 320, 22)];
    _detailLabel.font = [UIFont systemFontOfSize:17];
    _detailLabel.textColor = rgb(0x6D6D72);
    for (UILabel *l in @[ _stateLabel, _detailLabel ]) {
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:l];
    }
    _dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 14)];
    _dot.layer.cornerRadius = 7;
    [header addSubview:_dot];
    _bar = [[LevelBar alloc] initWithFrame:CGRectMake(40, 120, 240, 8)];
    _bar.backgroundColor = UIColor.clearColor;
    _bar.contentMode = UIViewContentModeRedraw;
    [header addSubview:_bar];
    self.tableView.tableHeaderView = header;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadPrefs)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    [self reloadPrefs];
}

// Line the level bar up with the text in the cells below it, with the dot just left of it.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect text = self.tableView.readableContentGuide.layoutFrame;
    _bar.frame = CGRectMake(CGRectGetMinX(text) + 24, 120, CGRectGetWidth(text) - 24, 8);
    _dot.center = CGPointMake(CGRectGetMinX(text) + 7, 124);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    [self poll];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
}

- (void)reloadPrefs {
    mw_prefs_load(&_prefs);
    _enabled.on = _prefs.enabled;
    _showDot.on = _prefs.show_dot;
    _sleepLow.on = _prefs.sleep_low;
    _timeout.value = _prefs.timeout;
    _sensitivity.value = _prefs.sensitivity;
    _sleepBelow.value = _prefs.sleep_below;
    [self showPrefs];
    [self.tableView reloadData];
}

- (void)showPrefs {
    [_motionCells[RowTimeout] detailTextLabel].text = duration(_prefs.timeout);
    [_motionCells[RowSensitivity] detailTextLabel].text = [NSString stringWithFormat:@"%d", _prefs.sensitivity];
    [_batteryCells[RowSleepBelow] detailTextLabel].text = [NSString stringWithFormat:@"%d%%", _prefs.sleep_below];
    for (UITableViewCell *c in [_motionCells arrayByAddingObjectsFromArray:_batteryCells]) [c setNeedsLayout];
    for (NSInteger s = 0; s < SecCount; s++) {
        UITableViewHeaderFooterView *footer = [self.tableView footerViewForSection:s];
        footer.textLabel.text = [self tableView:self.tableView titleForFooterInSection:s];
        [footer setNeedsLayout];
    }
    _bar.needed = mw_needed_percent(_prefs.sensitivity);
    [_bar setNeedsDisplay];
}

- (void)save {
    mw_prefs_clamp(&_prefs);
    if (!mw_prefs_save(&_prefs)) NSLog(@"MotionWake: could not save %s", MW_PREFS_PATH);
    [self showPrefs];
}

// Show or hide the rows under a switch.
- (void)section:(NSInteger)section rowsFrom:(NSInteger)from to:(NSInteger)to shown:(BOOL)shown {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSInteger r = from; r < to; r++) [rows addObject:[NSIndexPath indexPathForRow:r inSection:section]];
    [self.tableView beginUpdates];
    if (shown) [self.tableView insertRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
    else [self.tableView deleteRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
    [self.tableView endUpdates];
}

- (void)toggled {
    BOOL wasEnabled = _prefs.enabled, wasSleepLow = _prefs.sleep_low;
    _prefs.enabled = _enabled.on;
    _prefs.show_dot = _showDot.on;
    _prefs.sleep_low = _sleepLow.on;
    if (wasEnabled != _prefs.enabled) [self section:SecMotion rowsFrom:RowTimeout to:MotionRows shown:_prefs.enabled];
    if (wasSleepLow != _prefs.sleep_low) [self section:SecBattery rowsFrom:RowSleepBelow to:BatteryRows shown:_prefs.sleep_low];
    [self save];
}

- (void)sliding {
    _prefs.timeout = (int)lroundf(_timeout.value / 30) * 30; // half-minute steps
    _prefs.sensitivity = (int)lroundf(_sensitivity.value);
    _prefs.sleep_below = (int)lroundf(_sleepBelow.value / 5) * 5;
    mw_prefs_clamp(&_prefs);
    [self showPrefs];
}

- (void)slid {
    [self sliding];
    _timeout.value = _prefs.timeout;
    _sleepBelow.value = _prefs.sleep_below;
    [self save];
}

- (void)poll {
    if (_asking) return;
    _asking = YES;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/status", MW_STATUS_PORT]];
    [[_http dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        NSDictionary *status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_asking = NO;
            [self show:[status isKindOfClass:[NSDictionary class]] ? status : nil];
        });
    }] resume];
}

- (void)show:(NSDictionary *)s {
    BOOL wasUp = _status != nil;
    _status = s;
    if (wasUp != (s != nil)) [self showPrefs]; // the footer says when the service is down
    NSString *state = s[@"state"];
    BOOL motion = [s[@"motion"] boolValue];
    _dot.backgroundColor = motion ? rgb(0x4CD964) : rgb(0xDADADF);
    _bar.level = [s[@"level"] floatValue];
    _bar.hidden = _dot.hidden = ![state isEqual:@"watching"] && ![state isEqual:@"held"];
    [_bar setNeedsDisplay];

    int still = [s[@"stillFor"] intValue], left = MAX(0, [s[@"timeout"] intValue] - still);
    NSString *screen = s[@"screen"];
    if (!s) {
        _stateLabel.text = @"Not running";
        _detailLabel.text = @"The MotionWake service isn't answering";
    } else if ([state isEqual:@"off"]) {
        _stateLabel.text = @"Off";
        _detailLabel.text = @"The camera isn't watching";
    } else if ([state isEqual:@"battery"]) {
        _stateLabel.text = @"On battery";
        _detailLabel.text = [NSString stringWithFormat:@"Battery %@%% · the camera watches only on power", s[@"battery"]];
    } else if ([state isEqual:@"held"]) {
        _stateLabel.text = @"Locked by hand";
        _detailLabel.text = @"The screen stays off until the room has been still for 30 s";
    } else {
        _stateLabel.text = motion ? @"Movement" : @"Watching";
        if (![screen isEqual:@"on"]) _detailLabel.text = @"Screen off · movement turns it on";
        else if (motion) _detailLabel.text = @"Screen stays on";
        else _detailLabel.text = [NSString stringWithFormat:@"Screen off in %d:%02d unless something moves", left / 60, left % 60];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return SecCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == SecMotion) return _prefs.enabled ? MotionRows : 1;
    return _prefs.sleep_low ? BatteryRows : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == SecMotion ? _motionCells[ip.row] : _batteryCells[ip.row];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return section == SecMotion ? @"Camera" : @"Battery";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == SecMotion) {
        if (!_prefs.enabled) return @"The screen stays as it is. Auto-Lock should be Never, as MotionWake does the locking.";
        return [NSString stringWithFormat:@"While the iPad is plugged in, the front camera watches the room. Movement turns the "
                                          @"screen on; after %@ with no movement or touch it turns off. Higher sensitivity "
                                          @"reacts to smaller movements. Never runs on battery.",
                                          duration(_prefs.timeout)];
    }
    NSString *text = _prefs.sleep_low
        ? [NSString stringWithFormat:@"On battery at %d%% or less, the iPad goes to sleep once it has been left untouched for %@.",
                                     _prefs.sleep_below, duration(_prefs.timeout)]
        : @"On battery the screen stays on until the battery runs out.";
    if (!_status) text = [text stringByAppendingString:@"\n\nThe MotionWake service isn't running. Reinstall the package to start it."];
    return text;
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[SettingsController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
