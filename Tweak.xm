// IconReaper v8 — анимации удаления приложений
//
// Эффекты: чёрная дыра, пыль, раскол, сгорание, исчезновение, жидкость.
// Настройки (какие эффекты включены) и предпросмотр — в приложении "Настройки" -> IconReaper.
// Крестик и окно "Удалить?" не трогаем.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>

// ============ НАСТРОЙКИ ВРЕМЕНИ (можно менять числа) ============
static const CGFloat        kIconScale = 1.8;  // во сколько раз растёт иконка
static const NSTimeInterval kFadeOut   = 0.9;  // сколько секунд стол гаснет
static const NSTimeInterval kCrawl     = 1.3;  // сколько секунд иконка ползёт в центр
static const NSTimeInterval kDeleteAt  = 1.0;  // через сколько секунд реально удалять (>= kFadeOut)
static const NSTimeInterval kFadeIn    = 1.8;  // сколько секунд стол возвращается
// ================================================================

#define IRDomain CFSTR("com.user.iconreaper")

// --- Минимальные описания приватных классов SpringBoard ---
@interface SBIcon : NSObject
- (UIImage *)generateIconImage:(int)format;
- (NSString *)nodeIdentifier;
@end

@interface SBLeafIcon : SBIcon
@end

@interface SBIconView : UIView
- (UIView *)_iconImageView;
- (SBIcon *)icon;
@end

@interface SBIconViewMap : NSObject
+ (instancetype)homescreenMap;
- (SBIconView *)mappedIconViewForIcon:(SBIcon *)icon;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (id)homescreenIconViewMap;
@end

@interface UIWindow (IconReaper)
+ (NSArray *)allWindowsIncludingInternalWindows:(BOOL)internal onlyVisibleWindows:(BOOL)visible;
@end

@interface UIImage (IconReaper)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(CGFloat)scale;
@end

// --- Контекст эффекта: что доступно каждому эффекту ---
@interface IRCtx : NSObject
@property (nonatomic, strong) UIView *root;        // весь экран эффекта
@property (nonatomic, strong) UIView *holder;      // контейнер иконки (уже в центре и увеличен)
@property (nonatomic, strong) UIImageView *icon;   // картинка иконки внутри holder
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, assign) CGPoint center;      // центр экрана
@property (nonatomic, assign) CGRect rect;         // где на экране сейчас иконка (после увеличения)
@end
@implementation IRCtx
@end

typedef void (*IREffectFn)(IRCtx *ctx, void (^finish)(void));

static UIWindow *gWindow = nil;   // окно с эффектом
static BOOL gBusy = NO;           // эффект сейчас идёт
static BOOL gPassThrough = NO;    // после нашего удаления вызовы идут как обычно

// ====================== ЖУРНАЛ ======================
static void IRLog(NSString *msg) {
    NSLog(@"[IconReaper] %@", msg);
    NSString *path = @"/var/mobile/iconreaper.log";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ====================== НАСТРОЙКИ ======================
static NSArray *IRAllEffectIDs(void) {
    return @[@"blackhole", @"dust", @"shatter", @"burn", @"vanish", @"liquid"];
}

static BOOL IRPrefBool(CFStringRef key, BOOL def) {
    BOOL result = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, IRDomain);
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) result = CFBooleanGetValue((CFBooleanRef)v);
        CFRelease(v);
    }
    return result;
}

// Выбрать случайный эффект из включённых. nil = анимации выключены, удаляем как обычно.
static NSString *IRPickEffectID(void) {
    CFPreferencesAppSynchronize(IRDomain);
    if (!IRPrefBool(CFSTR("enabled"), YES)) return nil;
    NSMutableArray *on = [NSMutableArray array];
    for (NSString *eid in IRAllEffectIDs()) {
        NSString *key = [@"fx_" stringByAppendingString:eid];
        if (IRPrefBool((__bridge CFStringRef)key, YES)) [on addObject:eid];
    }
    if (on.count == 0) return nil;
    return on[arc4random_uniform((uint32_t)on.count)];
}

// ====================== МЕЛКИЕ ПОМОЩНИКИ ======================
static CGFloat IRRand(void) {
    return (CGFloat)arc4random_uniform(10001) / 10000.0;
}

static void IRAfter(NSTimeInterval t, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

static CABasicAnimation *IRBasic(NSString *kp, id from, id to, NSTimeInterval dur, NSString *timing) {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:kp];
    a.fromValue = from;
    a.toValue = to;
    a.duration = dur;
    a.timingFunction = [CAMediaTimingFunction functionWithName:timing];
    return a;
}

static CAKeyframeAnimation *IRKeys(NSString *kp, NSArray *values, NSArray *times, NSTimeInterval dur) {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:kp];
    a.values = values;
    a.keyTimes = times;
    a.duration = dur;
    return a;
}

// Запустить группу анимаций на слое с задержкой; после конца слой остаётся в конечном состоянии
static void IRRun(CALayer *layer, NSArray *anims, NSTimeInterval dur, NSTimeInterval delay, NSString *key) {
    CAAnimationGroup *g = [CAAnimationGroup animation];
    g.animations = anims;
    g.duration = dur;
    g.beginTime = CACurrentMediaTime() + delay;
    g.fillMode = kCAFillModeBoth;
    g.removedOnCompletion = NO;
    [layer addAnimation:g forKey:key];
}

static UIImage *IRSnapshotOfView(UIView *v) {
    UIGraphicsBeginImageContextWithOptions(v.bounds.size, NO, 0);
    [v.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Мягкая светящаяся точка (для частиц огня)
static UIImage *IRDotImage(CGFloat d) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat colors[8] = {1, 1, 1, 1, 1, 1, 1, 0};
    CGFloat locs[2] = {0, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, colors, locs, 2);
    CGContextDrawRadialGradient(c, g, CGPointMake(d / 2, d / 2), 0, CGPointMake(d / 2, d / 2), d / 2, 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return im;
}

// Средний цвет картинки (для жидкости)
static UIColor *IRAverageColor(UIImage *img) {
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    CGFloat a = px[3] / 255.0;
    if (a < 0.05) return [UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1];
    return [UIColor colorWithRed:px[0] / 255.0 / a green:px[1] / 255.0 / a blue:px[2] / 255.0 / a alpha:1];
}

// Нарезать картинку на cols x rows плиток и положить слои на экран эффекта
static NSArray *IRMakeTiles(UIImage *image, CGRect rect, int cols, int rows, UIView *root) {
    NSMutableArray *arr = [NSMutableArray array];
    CGFloat tw = rect.size.width / cols;
    CGFloat th = rect.size.height / rows;
    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            CALayer *l = [CALayer layer];
            l.frame = CGRectMake(rect.origin.x + c * tw, rect.origin.y + r * th, tw, th);
            l.contents = (__bridge id)image.CGImage;
            l.contentsRect = CGRectMake((CGFloat)c / cols, (CGFloat)r / rows, 1.0 / cols, 1.0 / rows);
            [root.layer addSublayer:l];
            [arr addObject:l];
        }
    }
    return arr;
}

static void IRCleanup(UIWindow *win) {
    win.hidden = YES;
    gWindow = nil;
    gBusy = NO;
    gPassThrough = NO;
}

// ====================== ЭФФЕКТ 1: ЧЁРНАЯ ДЫРА ======================
static void IREffectBlackHole(IRCtx *ctx, void (^finish)(void)) {
    UIView *root = ctx.root;
    CGPoint c = ctx.center;
    const CGFloat D = 320;

    // Аккреционный диск: конический градиент, обрезанный кольцом, сплющенный как наклонённый диск
    UIView *diskBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, D, D)];
    diskBox.center = c;
    diskBox.alpha = 0;
    diskBox.transform = CGAffineTransformMakeScale(0.1, 0.04);
    [root insertSubview:diskBox belowSubview:ctx.holder];

    CAGradientLayer *disk = [CAGradientLayer layer];
    disk.frame = diskBox.bounds;
    disk.type = @"conic";
    disk.startPoint = CGPointMake(0.5, 0.5);
    disk.endPoint = CGPointMake(0.5, 0.0);
    UIColor *hot  = [UIColor colorWithRed:1.0 green:0.97 blue:0.85 alpha:1.0];
    UIColor *org  = [UIColor colorWithRed:1.0 green:0.6 blue:0.15 alpha:1.0];
    UIColor *red  = [UIColor colorWithRed:0.55 green:0.1 blue:0.05 alpha:0.9];
    UIColor *dark = [UIColor colorWithRed:0.1 green:0.02 blue:0.02 alpha:0.2];
    disk.colors = @[(id)hot.CGColor, (id)org.CGColor, (id)red.CGColor, (id)dark.CGColor,
                    (id)red.CGColor, (id)org.CGColor, (id)hot.CGColor];
    CAShapeLayer *ringMask = [CAShapeLayer layer];
    ringMask.frame = disk.bounds;
    CGFloat rr = 95;
    ringMask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(D / 2 - rr, D / 2 - rr, rr * 2, rr * 2)].CGPath;
    ringMask.fillColor = [UIColor clearColor].CGColor;
    ringMask.strokeColor = [UIColor blackColor].CGColor;
    ringMask.lineWidth = 70;
    disk.mask = ringMask;
    [diskBox.layer addSublayer:disk];
    CABasicAnimation *spinDisk = IRBasic(@"transform.rotation.z", @0, @(M_PI * 2), 1.8, kCAMediaTimingFunctionLinear);
    spinDisk.repeatCount = HUGE_VALF;
    [disk addAnimation:spinDisk forKey:@"spin"];

    // Тонкие пунктирные кольца (потоки газа), крутятся в разные стороны
    CGFloat dashR[2] = {140, 112};
    for (int i = 0; i < 2; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = diskBox.bounds;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(D / 2 - dashR[i], D / 2 - dashR[i], dashR[i] * 2, dashR[i] * 2)].CGPath;
        ring.fillColor = [UIColor clearColor].CGColor;
        ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        ring.lineWidth = 2;
        ring.lineDashPattern = @[@(3 + i * 4), @9];
        [diskBox.layer addSublayer:ring];
        CABasicAnimation *sp = IRBasic(@"transform.rotation.z", @0, @((i == 0 ? -1 : 1) * M_PI * 2), 2.4 - i * 0.8, kCAMediaTimingFunctionLinear);
        sp.repeatCount = HUGE_VALF;
        [ring addAnimation:sp forKey:@"spin"];
    }

    // Горизонт событий: чёрное ядро со свечением и яркое фотонное кольцо
    UIView *holeView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 160, 160)];
    holeView.center = c;
    holeView.alpha = 0;
    holeView.transform = CGAffineTransformMakeScale(0.1, 0.1);
    [root insertSubview:holeView belowSubview:ctx.holder];

    CAShapeLayer *photon = [CAShapeLayer layer];
    photon.frame = holeView.bounds;
    photon.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(80 - 50, 80 - 50, 100, 100)].CGPath;
    photon.fillColor = [UIColor clearColor].CGColor;
    photon.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
    photon.lineWidth = 3;
    photon.shadowColor = [UIColor whiteColor].CGColor;
    photon.shadowOpacity = 1.0;
    photon.shadowRadius = 10;
    photon.shadowOffset = CGSizeZero;
    [holeView.layer addSublayer:photon];

    UIView *core = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 92, 92)];
    core.center = CGPointMake(80, 80);
    core.backgroundColor = [UIColor blackColor];
    core.layer.cornerRadius = 46;
    core.layer.shadowColor = [UIColor whiteColor].CGColor;
    core.layer.shadowOpacity = 0.8;
    core.layer.shadowRadius = 22;
    core.layer.shadowOffset = CGSizeZero;
    [holeView addSubview:core];

    [UIView animateWithDuration:0.6 animations:^{
        diskBox.alpha = 1;
        diskBox.transform = CGAffineTransformMakeScale(1.0, 0.38);
        holeView.alpha = 1;
        holeView.transform = CGAffineTransformIdentity;
    }];

    // Звёзды и пыль, которые закручиваются по спирали в дыру
    for (int i = 0; i < 26; i++) {
        CALayer *dot = [CALayer layer];
        CGFloat s = 2 + IRRand() * 3;
        dot.bounds = CGRectMake(0, 0, s, s);
        dot.cornerRadius = s / 2;
        dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.5 + IRRand() * 0.5].CGColor;
        dot.position = c;
        dot.opacity = 0;
        [root.layer addSublayer:dot];

        CGFloat a0 = IRRand() * M_PI * 2;
        CGFloat r0 = 150 + IRRand() * 70;
        UIBezierPath *path = [UIBezierPath bezierPath];
        for (int k = 0; k <= 14; k++) {
            CGFloat t = (CGFloat)k / 14;
            CGFloat ang = a0 + t * M_PI * 2.6;
            CGFloat rad = r0 * pow(1 - t, 1.5);
            CGPoint p = CGPointMake(c.x + cos(ang) * rad, c.y + sin(ang) * rad * 0.55);
            if (k == 0) [path moveToPoint:p]; else [path addLineToPoint:p];
        }
        CGFloat dur = 1.1 + IRRand() * 0.6;
        CAKeyframeAnimation *mv = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        mv.path = path.CGPath;
        mv.duration = dur;
        mv.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        CAKeyframeAnimation *op = IRKeys(@"opacity", @[@0, @1, @1, @0], @[@0, @0.1, @0.8, @1], dur);
        IRRun(dot, @[mv, op], dur, 0.1 + IRRand() * 0.5, @"star");
    }

    // Иконка: закручивается и растягивается, как при падении в дыру
    NSTimeInterval T = 1.6;
    CABasicAnimation *rot = IRBasic(@"transform.rotation.z", @0, @(M_PI * 8), T, kCAMediaTimingFunctionEaseIn);
    CABasicAnimation *sx = IRBasic(@"transform.scale.x", @1.0, @0.01, T, kCAMediaTimingFunctionEaseIn);
    CAKeyframeAnimation *sy = IRKeys(@"transform.scale.y", @[@1.0, @1.5, @0.01], @[@0, @0.55, @1], T);
    CAKeyframeAnimation *op = IRKeys(@"opacity", @[@1, @1, @0], @[@0, @0.8, @1], T);
    IRRun(ctx.icon.layer, @[rot, sx, sy, op], T, 0.5, @"bh");

    // Финал: ударная волна, дыра схлопывается
    IRAfter(0.5 + T, ^{
        ctx.icon.hidden = YES;
        CAShapeLayer *wave = [CAShapeLayer layer];
        wave.bounds = CGRectMake(0, 0, 100, 100);
        wave.position = c;
        wave.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 100, 100)].CGPath;
        wave.fillColor = [UIColor clearColor].CGColor;
        wave.strokeColor = [UIColor whiteColor].CGColor;
        wave.lineWidth = 4;
        wave.opacity = 0;
        [root.layer addSublayer:wave];
        IRRun(wave, @[IRBasic(@"transform.scale", @0.3, @5.0, 0.55, kCAMediaTimingFunctionEaseOut),
                      IRBasic(@"opacity", @0.9, @0.0, 0.55, kCAMediaTimingFunctionLinear)],
              0.55, 0, @"wave");
        [UIView animateWithDuration:0.45 animations:^{
            diskBox.alpha = 0;
            diskBox.transform = CGAffineTransformMakeScale(0.05, 0.02);
            holeView.alpha = 0;
            holeView.transform = CGAffineTransformMakeScale(0.05, 0.05);
        }];
    });
    IRAfter(0.5 + T + 0.65, finish);
}

// ====================== ЭФФЕКТ 2: ПЫЛЬ ======================
static void IREffectDust(IRCtx *ctx, void (^finish)(void)) {
    const int cols = 14, rows = 14;
    NSArray *tiles = IRMakeTiles(ctx.image, ctx.rect, cols, rows, ctx.root);
    ctx.holder.hidden = YES;
    CGFloat T = 1.1;
    for (int i = 0; i < (int)tiles.count; i++) {
        CALayer *l = tiles[i];
        int col = i % cols;
        // волна распада идёт слева направо
        CGFloat delay = 0.15 + ((CGFloat)col / cols) * 0.9 + IRRand() * 0.35;
        CGFloat dx = 30 + IRRand() * 110;
        CGFloat dy = -(20 + IRRand() * 120);
        CGFloat rot = (IRRand() - 0.5) * M_PI * 2;
        IRRun(l, @[
            IRBasic(@"transform.translation.x", @0, @(dx), T, kCAMediaTimingFunctionEaseIn),
            IRBasic(@"transform.translation.y", @0, @(dy), T, kCAMediaTimingFunctionEaseOut),
            IRBasic(@"transform.rotation.z", @0, @(rot), T, kCAMediaTimingFunctionLinear),
            IRBasic(@"transform.scale", @1.0, @0.2, T, kCAMediaTimingFunctionEaseIn),
            IRKeys(@"opacity", @[@1, @1, @0], @[@0, @0.45, @1], T)
        ], T, delay, @"dust");
    }
    IRAfter(0.15 + 0.9 + 0.35 + T + 0.1, finish);
}

// ====================== ЭФФЕКТ 3: РАСКОЛ ======================
static void IREffectShatter(IRCtx *ctx, void (^finish)(void)) {
    CGRect rect = ctx.rect;
    UIView *root = ctx.root;
    CGPoint ctr = ctx.center;

    // Трещины расходятся от центра
    CAShapeLayer *cracks = [CAShapeLayer layer];
    cracks.frame = root.bounds;
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGPoint o = CGPointMake(ctr.x + (IRRand() - 0.5) * 20, ctr.y + (IRRand() - 0.5) * 20);
    for (int i = 0; i < 8; i++) {
        CGFloat ang = (CGFloat)i / 8 * M_PI * 2 + (IRRand() - 0.5) * 0.5;
        CGFloat len = rect.size.width * (0.45 + IRRand() * 0.35);
        CGPoint mid = CGPointMake(o.x + cos(ang) * len * 0.5 + (IRRand() - 0.5) * 10,
                                  o.y + sin(ang) * len * 0.5 + (IRRand() - 0.5) * 10);
        CGPoint end = CGPointMake(o.x + cos(ang) * len, o.y + sin(ang) * len);
        [p moveToPoint:o];
        [p addLineToPoint:mid];
        [p addLineToPoint:end];
    }
    cracks.path = p.CGPath;
    cracks.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    cracks.fillColor = [UIColor clearColor].CGColor;
    cracks.lineWidth = 1.5;
    cracks.shadowColor = [UIColor whiteColor].CGColor;
    cracks.shadowOpacity = 1;
    cracks.shadowRadius = 3;
    cracks.shadowOffset = CGSizeZero;
    [root.layer addSublayer:cracks];
    [cracks addAnimation:IRBasic(@"strokeEnd", @0, @1, 0.2, kCAMediaTimingFunctionEaseOut) forKey:@"cr"];
    [ctx.icon.layer addAnimation:IRKeys(@"transform.translation.x",
                                        @[@0, @-3, @3, @-2, @2, @0],
                                        @[@0, @0.2, @0.4, @0.6, @0.8, @1], 0.3) forKey:@"shake"];

    // Через 0.35 с иконка рассыпается на осколки и падает вниз
    IRAfter(0.35, ^{
        NSArray *tiles = IRMakeTiles(ctx.image, rect, 6, 6, root);
        ctx.holder.hidden = YES;
        cracks.hidden = YES;
        for (CALayer *tile in tiles) {
            CGFloat ox = tile.position.x - ctr.x;
            CGFloat oy = tile.position.y - ctr.y;
            CGFloat T = 0.9 + IRRand() * 0.5;
            CGFloat fall = root.bounds.size.height - rect.origin.y + 150 + IRRand() * 150;
            CGFloat drift = ox * 0.8 + (IRRand() - 0.5) * 60;
            CAKeyframeAnimation *kx = IRKeys(@"transform.translation.x", @[@0, @(ox * 0.6), @(drift * 1.2)], @[@0, @0.15, @1], T);
            CAKeyframeAnimation *ky = IRKeys(@"transform.translation.y", @[@0, @(oy * 0.6 - 25), @(fall)], @[@0, @0.15, @1], T);
            ky.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                                   [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
            CABasicAnimation *kr = IRBasic(@"transform.rotation.z", @0, @((IRRand() - 0.5) * M_PI * 3), T, kCAMediaTimingFunctionLinear);
            IRRun(tile, @[kx, ky, kr], T, IRRand() * 0.1, @"shatter");
        }
    });
    IRAfter(0.35 + 0.1 + 1.4 + 0.1, finish);
}

// ====================== ЭФФЕКТ 4: СГОРАНИЕ ======================
static void IREffectBurn(IRCtx *ctx, void (^finish)(void)) {
    CGRect rect = ctx.rect;
    UIView *root = ctx.root;
    CGSize s = ctx.holder.bounds.size;
    NSTimeInterval T = 1.9;     // сколько горит
    NSTimeInterval D0 = 0.35;   // пауза: зажигалка разгорается

    // Маска иконки: уменьшается снизу вверх (иконка сгорает)
    CALayer *mask = [CALayer layer];
    mask.anchorPoint = CGPointZero;
    mask.position = CGPointZero;
    mask.bounds = CGRectMake(0, 0, s.width, s.height);
    mask.backgroundColor = [UIColor whiteColor].CGColor;
    ctx.icon.layer.mask = mask;
    IRRun(mask, @[IRBasic(@"bounds.size.height", @(s.height), @0, T, kCAMediaTimingFunctionLinear)], T, D0, @"burnmask");

    // Раскалённый обугленный край, едет вверх вместе с огнём
    CGFloat bh = 12;
    CAGradientLayer *band = [CAGradientLayer layer];
    band.frame = CGRectMake(3, s.height - bh, s.width - 6, bh);
    band.colors = @[(id)[UIColor colorWithRed:0.1 green:0.03 blue:0.0 alpha:0.0].CGColor,
                    (id)[UIColor colorWithRed:0.15 green:0.05 blue:0.0 alpha:0.95].CGColor,
                    (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1.0].CGColor,
                    (id)[UIColor colorWithRed:1.0 green:0.9 blue:0.4 alpha:1.0].CGColor];
    band.startPoint = CGPointMake(0.5, 0);
    band.endPoint = CGPointMake(0.5, 1);
    [ctx.holder.layer addSublayer:band];
    IRRun(band, @[IRBasic(@"transform.translation.y", @0, @(-s.height), T, kCAMediaTimingFunctionLinear)], T, D0, @"burnband");

    // Огонь, искры и дым
    UIImage *dot = IRDotImage(24);
    CAEmitterCell *flame = [CAEmitterCell emitterCell];
    flame.contents = (__bridge id)dot.CGImage;
    flame.birthRate = 140;
    flame.lifetime = 0.7;
    flame.lifetimeRange = 0.3;
    flame.velocity = 70;
    flame.velocityRange = 30;
    flame.emissionLongitude = -M_PI_2;
    flame.emissionRange = M_PI / 5;
    flame.scale = 0.55;
    flame.scaleRange = 0.25;
    flame.scaleSpeed = -0.5;
    flame.color = [UIColor colorWithRed:1.0 green:0.45 blue:0.08 alpha:0.9].CGColor;
    flame.alphaSpeed = -1.2;

    CAEmitterCell *ember = [CAEmitterCell emitterCell];
    ember.contents = (__bridge id)dot.CGImage;
    ember.birthRate = 35;
    ember.lifetime = 1.0;
    ember.lifetimeRange = 0.5;
    ember.velocity = 110;
    ember.velocityRange = 50;
    ember.emissionLongitude = -M_PI_2;
    ember.emissionRange = M_PI / 3;
    ember.scale = 0.18;
    ember.scaleRange = 0.1;
    ember.color = [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1.0].CGColor;
    ember.alphaSpeed = -0.9;

    CAEmitterCell *smoke = [CAEmitterCell emitterCell];
    smoke.contents = (__bridge id)dot.CGImage;
    smoke.birthRate = 25;
    smoke.lifetime = 1.6;
    smoke.lifetimeRange = 0.5;
    smoke.velocity = 35;
    smoke.velocityRange = 15;
    smoke.emissionLongitude = -M_PI_2;
    smoke.emissionRange = M_PI / 6;
    smoke.scale = 0.9;
    smoke.scaleSpeed = 0.5;
    smoke.color = [UIColor colorWithWhite:0.25 alpha:0.3].CGColor;
    smoke.alphaSpeed = -0.2;

    CAEmitterLayer *em = [CAEmitterLayer layer];
    em.frame = root.bounds;
    em.emitterShape = kCAEmitterLayerLine;
    em.emitterPosition = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));
    em.emitterSize = CGSizeMake(rect.size.width * 0.8, 1);
    em.renderMode = kCAEmitterLayerAdditive;
    em.emitterCells = @[smoke, flame, ember];
    [root.layer addSublayer:em];
    IRRun(em, @[IRBasic(@"emitterPosition",
                        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect))],
                        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))],
                        T, kCAMediaTimingFunctionLinear)], T, D0, @"burnem");

    IRAfter(D0 + T, ^{
        em.birthRate = 0;
        ctx.holder.hidden = YES;
    });
    IRAfter(D0 + T + 1.0, finish);
}

// ====================== ЭФФЕКТ 5: ИСЧЕЗНОВЕНИЕ ИЗ ПРОСТРАНСТВА ======================
static void IREffectVanish(IRCtx *ctx, void (^finish)(void)) {
    UIView *holder = ctx.holder;
    CGPoint c = ctx.center;

    // Глитч: цветные копии дёргаются, иконка мерцает
    UIImage *tpl = [ctx.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    NSArray *colors = @[[UIColor redColor], [UIColor cyanColor]];
    NSMutableArray *ghosts = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        UIImageView *g = [[UIImageView alloc] initWithImage:tpl];
        g.frame = ctx.icon.frame;
        g.tintColor = colors[i];
        g.alpha = 0.55;
        g.layer.compositingFilter = @"screenBlendMode";
        [holder insertSubview:g aboveSubview:ctx.icon];
        [ghosts addObject:g];
        CGFloat dir = (i == 0) ? -1 : 1;
        [g.layer addAnimation:IRKeys(@"transform.translation.x",
                                     @[@0, @(5 * dir), @(-7 * dir), @(9 * dir), @(-4 * dir), @0],
                                     @[@0, @0.2, @0.4, @0.6, @0.8, @1], 0.4) forKey:@"gl"];
    }
    [ctx.icon.layer addAnimation:IRKeys(@"opacity",
                                        @[@1, @0.3, @1, @0.5, @1, @0.7, @1],
                                        @[@0, @0.15, @0.3, @0.45, @0.6, @0.8, @1], 0.4) forKey:@"fl"];

    // Схлопывание: сначала в горизонтальную линию, потом в точку
    IRAfter(0.4, ^{
        for (UIView *g in ghosts) g.hidden = YES;
        UIView *flash = [[UIView alloc] initWithFrame:holder.bounds];
        flash.backgroundColor = [UIColor whiteColor];
        flash.layer.cornerRadius = 13;
        flash.layer.masksToBounds = YES;
        flash.alpha = 0;
        [holder addSubview:flash];
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            holder.transform = CGAffineTransformMakeScale(kIconScale * 1.35, kIconScale * 0.02);
            flash.alpha = 0.95;
        } completion:^(BOOL f) {
            [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                holder.transform = CGAffineTransformMakeScale(0.01, kIconScale * 0.02);
            } completion:^(BOOL f2) {
                holder.hidden = YES;
            }];
        }];
    });

    // Волны от точки, где пропала иконка
    IRAfter(0.82, ^{
        for (int i = 0; i < 2; i++) {
            CAShapeLayer *ring = [CAShapeLayer layer];
            ring.bounds = CGRectMake(0, 0, 60, 60);
            ring.position = c;
            ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 60, 60)].CGPath;
            ring.fillColor = [UIColor clearColor].CGColor;
            ring.strokeColor = [UIColor whiteColor].CGColor;
            ring.lineWidth = 2;
            ring.opacity = 0;
            [ctx.root.layer addSublayer:ring];
            IRRun(ring, @[IRBasic(@"transform.scale", @0.1, @4.0, 0.6, kCAMediaTimingFunctionEaseOut),
                          IRBasic(@"opacity", @1.0, @0.0, 0.6, kCAMediaTimingFunctionLinear)],
                  0.6, i * 0.14, @"ripple");
        }
    });
    IRAfter(0.82 + 0.8, finish);
}

// ====================== ЭФФЕКТ 6: ЖИДКОСТЬ ======================
static void IREffectLiquid(IRCtx *ctx, void (^finish)(void)) {
    CGRect rect = ctx.rect;
    UIView *root = ctx.root;
    CGFloat screenH = root.bounds.size.height;

    // Иконка "дрожит", как желе
    NSArray *times = @[@0, @0.2, @0.4, @0.6, @0.8, @1];
    [ctx.icon.layer addAnimation:IRKeys(@"transform.scale.x", @[@1, @1.08, @0.94, @1.06, @0.97, @1.0], times, 0.55) forKey:@"w1"];
    [ctx.icon.layer addAnimation:IRKeys(@"transform.scale.y", @[@1, @0.93, @1.07, @0.95, @1.04, @1.0], times, 0.55) forKey:@"w2"];

    // Потом плавится: вертикальные полоски вытягиваются вниз и стекают
    IRAfter(0.55, ^{
        int n = 18;
        NSArray *strips = IRMakeTiles(ctx.image, rect, n, 1, root);
        ctx.holder.hidden = YES;
        UIColor *avg = IRAverageColor(ctx.image);

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *l in strips) {
            l.anchorPoint = CGPointMake(0.5, 0);
            l.position = CGPointMake(l.position.x, rect.origin.y);
        }
        [CATransaction commit];

        for (CALayer *l in strips) {
            CGFloat T = 1.1 + IRRand() * 0.4;
            CGFloat stretch = 3 + IRRand() * 7;
            CGFloat drop = 160 + IRRand() * 420;
            IRRun(l, @[
                IRKeys(@"transform.scale.y", @[@1, @(stretch * 0.5), @(stretch)], @[@0, @0.5, @1], T),
                IRBasic(@"transform.scale.x", @1.0, @0.35, T, kCAMediaTimingFunctionEaseIn),
                IRBasic(@"transform.translation.y", @0, @(drop), T, kCAMediaTimingFunctionEaseIn),
                IRKeys(@"opacity", @[@1, @1, @0], @[@0, @0.65, @1], T)
            ], T, IRRand() * 0.45, @"liq");
        }

        // Капли
        for (int i = 0; i < 10; i++) {
            CALayer *d = [CALayer layer];
            CGFloat sz = 5 + IRRand() * 5;
            d.bounds = CGRectMake(0, 0, sz, sz);
            d.cornerRadius = sz / 2;
            d.backgroundColor = avg.CGColor;
            CGFloat x = rect.origin.x + IRRand() * rect.size.width;
            CGFloat y = CGRectGetMaxY(rect) - 4;
            d.position = CGPointMake(x, y);
            d.opacity = 0;
            [root.layer addSublayer:d];
            CGFloat T = 0.8 + IRRand() * 0.5;
            IRRun(d, @[
                IRBasic(@"transform.translation.y", @0, @(screenH - y + 40), T, kCAMediaTimingFunctionEaseIn),
                IRBasic(@"transform.scale.y", @1.0, @2.2, T, kCAMediaTimingFunctionEaseIn),
                IRKeys(@"opacity", @[@0, @1, @1], @[@0, @0.05, @1], T)
            ], T, 0.15 + IRRand() * 0.6, @"drop");
        }

        // Лужа растекается и утекает вниз
        CALayer *puddle = [CALayer layer];
        puddle.bounds = CGRectMake(0, 0, rect.size.width * 0.6, 10);
        puddle.cornerRadius = 5;
        puddle.backgroundColor = avg.CGColor;
        puddle.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect) + 2);
        puddle.opacity = 0;
        [root.layer addSublayer:puddle];
        CGFloat PT = 1.3;
        CAKeyframeAnimation *py = IRKeys(@"transform.translation.y", @[@0, @0, @(screenH)], @[@0, @0.5, @1], PT);
        py.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
                               [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];
        IRRun(puddle, @[
            IRKeys(@"transform.scale.x", @[@0.2, @1.5, @1.8], @[@0, @0.5, @1], PT),
            IRKeys(@"opacity", @[@0, @1, @1, @0], @[@0, @0.15, @0.8, @1], PT),
            py
        ], PT, 0.3, @"puddle");
    });
    IRAfter(0.55 + 0.45 + 1.5 + 0.3, finish);
}

static IREffectFn IREffectForID(NSString *eid) {
    if ([eid isEqualToString:@"blackhole"]) return IREffectBlackHole;
    if ([eid isEqualToString:@"dust"])      return IREffectDust;
    if ([eid isEqualToString:@"shatter"])   return IREffectShatter;
    if ([eid isEqualToString:@"burn"])      return IREffectBurn;
    if ([eid isEqualToString:@"vanish"])    return IREffectVanish;
    if ([eid isEqualToString:@"liquid"])    return IREffectLiquid;
    return NULL;
}

// ====================== ОБЩИЙ СЦЕНАРИЙ ======================
// 1) стол гаснет, иконка ползёт в центр и растёт
// 2) играет выбранный эффект (в это время реально удаляем приложение)
// 3) стол медленно возвращается
// deleteBlock = nil для предпросмотра (ничего не удаляем)
static void IRPlayEffect(NSString *effectID, UIImage *image, CGRect startFrame, void (^deleteBlock)(void)) {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));

    UIWindow *win = [[UIWindow alloc] initWithFrame:screen];
    win.windowLevel = UIWindowLevelAlert + 1000;
    win.userInteractionEnabled = NO;
    win.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = vc;
    win.hidden = NO;
    gWindow = win;
    UIView *root = vc.view;

    // Аварийная очистка, если что-то зависло
    IRAfter(15.0, ^{
        if (gWindow == win) {
            IRCleanup(win);
            IRLog(@"аварийная очистка окна эффекта");
        }
    });

    UIView *dim = [[UIView alloc] initWithFrame:screen];
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0;
    [root addSubview:dim];

    UIView *holder = [[UIView alloc] initWithFrame:startFrame];
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = holder.bounds;
    [holder addSubview:icon];
    [root addSubview:holder];

    IRCtx *ctx = [[IRCtx alloc] init];
    ctx.root = root;
    ctx.holder = holder;
    ctx.icon = icon;
    ctx.image = image;
    ctx.center = center;

    // Шаг 1
    [UIView animateWithDuration:kFadeOut animations:^{
        dim.alpha = 1.0;
    }];

    // Настоящее удаление — когда экран уже тёмный
    IRAfter(kDeleteAt, ^{
        if (deleteBlock) deleteBlock();
    });

    [UIView animateWithDuration:kCrawl delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        holder.center = center;
        holder.transform = CGAffineTransformMakeScale(kIconScale, kIconScale);
    } completion:^(BOOL finishedCrawl) {
        ctx.rect = holder.frame;

        // Шаг 3 (вызывается эффектом, когда он закончился)
        __block BOOL done = NO;
        void (^finish)(void) = ^{
            if (done) return;
            done = YES;
            // Спрятать всё, кроме чёрной пелены
            for (CALayer *l in [root.layer.sublayers copy]) {
                if (l != dim.layer) l.hidden = YES;
            }
            IRAfter(0.3, ^{
                [UIView animateWithDuration:kFadeIn animations:^{
                    dim.alpha = 0;
                } completion:^(BOOL f) {
                    IRCleanup(win);
                    IRLog(@"эффект закончен");
                }];
            });
        };

        // Шаг 2
        IREffectFn fx = IREffectForID(effectID);
        if (fx) fx(ctx, finish); else finish();
    }];
}

// ====================== ПОИСК ИКОНКИ НА ЭКРАНЕ ======================
static BOOL IRSameIcon(SBIcon *a, SBIcon *b) {
    if (a == nil || b == nil) return NO;
    if (a == b) return YES;
    if ([a respondsToSelector:@selector(nodeIdentifier)] &&
        [b respondsToSelector:@selector(nodeIdentifier)]) {
        NSString *x = [a nodeIdentifier];
        NSString *y = [b nodeIdentifier];
        if ([x isKindOfClass:[NSString class]] && [y isKindOfClass:[NSString class]] &&
            [x isEqualToString:y]) return YES;
    }
    return NO;
}

static SBIconView *IRWalk(UIView *v, SBIcon *icon, Class iconViewClass, int *visited) {
    if ([v isKindOfClass:iconViewClass]) {
        (*visited)++;
        SBIconView *iv = (SBIconView *)v;
        if ([iv respondsToSelector:@selector(icon)] && IRSameIcon([iv icon], icon)) return iv;
    }
    for (UIView *sub in v.subviews) {
        SBIconView *found = IRWalk(sub, icon, iconViewClass, visited);
        if (found) return found;
    }
    return nil;
}

static SBIconView *IRFindIconView(SBIcon *icon) {
    // Способ 1: карта вьюх иконок у SBIconController
    Class ctrlClass = NSClassFromString(@"SBIconController");
    if ([ctrlClass respondsToSelector:@selector(sharedInstance)]) {
        SBIconController *ctrl = [ctrlClass sharedInstance];
        if ([ctrl respondsToSelector:@selector(homescreenIconViewMap)]) {
            id map = [ctrl homescreenIconViewMap];
            if ([map respondsToSelector:@selector(mappedIconViewForIcon:)]) {
                SBIconView *v = [map mappedIconViewForIcon:icon];
                if (v) { IRLog(@"иконка найдена: способ 1"); return v; }
            }
        }
    }
    // Способ 2: старая карта SBIconViewMap
    Class mapClass = NSClassFromString(@"SBIconViewMap");
    if ([mapClass respondsToSelector:@selector(homescreenMap)]) {
        SBIconViewMap *map = [mapClass homescreenMap];
        if ([map respondsToSelector:@selector(mappedIconViewForIcon:)]) {
            SBIconView *v = [map mappedIconViewForIcon:icon];
            if (v) { IRLog(@"иконка найдена: способ 2"); return v; }
        }
    }
    // Способ 3: обход всех вьюх во всех окнах
    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (iconViewClass == nil) {
        IRLog(@"класс SBIconView не найден");
        return nil;
    }
    NSMutableArray *wins = [NSMutableArray array];
    [wins addObjectsFromArray:[UIApplication sharedApplication].windows];
    if ([UIWindow respondsToSelector:@selector(allWindowsIncludingInternalWindows:onlyVisibleWindows:)]) {
        NSArray *all = [UIWindow allWindowsIncludingInternalWindows:YES onlyVisibleWindows:NO];
        for (UIWindow *w in all) {
            if (![wins containsObject:w]) [wins addObject:w];
        }
    }
    int visited = 0;
    for (UIWindow *w in wins) {
        SBIconView *found = IRWalk(w, icon, iconViewClass, &visited);
        if (found) { IRLog(@"иконка найдена: способ 3"); return found; }
    }
    IRLog([NSString stringWithFormat:@"иконка не найдена. окон: %lu, SBIconView просмотрено: %d",
           (unsigned long)wins.count, visited]);
    return nil;
}

// ====================== ЗАПУСК ПРИ УДАЛЕНИИ ======================
// YES = эффект запущен, настоящее удаление отложено
static BOOL IRStartEffect(SBIcon *icon, void (^deleteBlock)(void)) {
    if (gBusy || icon == nil) return NO;

    NSString *effectID = IRPickEffectID();
    if (effectID == nil) {
        IRLog(@"анимации выключены в настройках — удаляю как обычно");
        return NO;
    }

    SBIconView *iconView = IRFindIconView(icon);
    if (iconView == nil) {
        IRLog(@"не нашёл вьюху иконки — удаляю без эффекта");
        return NO;
    }
    if (iconView.window == nil) {
        IRLog(@"вьюха иконки не на экране — удаляю без эффекта");
        return NO;
    }

    UIView *imgView = nil;
    if ([iconView respondsToSelector:@selector(_iconImageView)]) {
        UIView *candidate = [iconView _iconImageView];
        if ([candidate isKindOfClass:[UIView class]]) imgView = candidate;
    }

    UIImage *img = nil;
    if ([icon respondsToSelector:@selector(generateIconImage:)]) {
        img = [icon generateIconImage:2];
    }
    if (img == nil && imgView != nil) {
        img = IRSnapshotOfView(imgView);
    }
    if (img == nil) {
        IRLog(@"не получилось взять картинку иконки — удаляю без эффекта");
        return NO;
    }

    CGSize size = imgView ? imgView.bounds.size : img.size;
    UIView *base = imgView ? imgView : iconView;
    CGRect r = [base convertRect:base.bounds toView:nil];
    CGRect frame = CGRectMake(CGRectGetMidX(r) - size.width / 2,
                              CGRectGetMidY(r) - size.height / 2,
                              size.width, size.height);

    IRLog([NSString stringWithFormat:@"запускаю эффект: %@", effectID]);
    gBusy = YES;

    void (^wrapped)(void) = ^{
        IRLog(@"удаляю приложение (экран уже тёмный)");
        gPassThrough = YES;
        if (deleteBlock) deleteBlock();
    };
    IRPlayEffect(effectID, img, frame, wrapped);
    return YES;
}

// ====================== ПРЕДПРОСМОТР ИЗ НАСТРОЕК ======================
static UIImage *IRPlaceholderIcon(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(60, 60), NO, 0);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 60, 60) cornerRadius:13];
    [[UIColor colorWithRed:0.2 green:0.5 blue:0.95 alpha:1] setFill];
    [bp fill];
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:24],
                            NSForegroundColorAttributeName: [UIColor whiteColor]};
    [@"IR" drawInRect:CGRectMake(0, 16, 60, 30) withAttributes:attrs];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static void IRStartPreview(NSString *effectID) {
    if (gBusy) return;
    CGRect screen = [UIScreen mainScreen].bounds;
    UIImage *img = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        img = [UIImage _applicationIconImageForBundleIdentifier:@"com.apple.Preferences"
                                                         format:2
                                                          scale:[UIScreen mainScreen].scale];
    }
    if (img == nil) img = IRPlaceholderIcon();
    CGRect frame = CGRectMake(CGRectGetMidX(screen) - 30, screen.size.height * 0.75, 60, 60);
    gBusy = YES;
    IRLog([NSString stringWithFormat:@"предпросмотр: %@", effectID]);
    IRPlayEffect(effectID, img, frame, nil);
}

static void IRPreviewCallback(CFNotificationCenterRef center, void *observer,
                              CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPreferencesAppSynchronize(IRDomain);
        NSString *eid = nil;
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("preview"), IRDomain);
        if (v) {
            if (CFGetTypeID(v) == CFStringGetTypeID()) eid = [(__bridge NSString *)v copy];
            CFRelease(v);
        }
        if (eid.length == 0 || [eid isEqualToString:@"none"]) return;
        // Сбросить выбор, чтобы можно было посмотреть тот же эффект ещё раз
        CFPreferencesSetAppValue(CFSTR("preview"), CFSTR("none"), IRDomain);
        CFPreferencesAppSynchronize(IRDomain);
        if ([IRAllEffectIDs() containsObject:eid]) IRStartPreview(eid);
    });
}

// ====================== ПЕРЕХВАТ УДАЛЕНИЯ ======================
%hook SBIconController

- (void)uninstallIcon:(SBIcon *)icon animate:(BOOL)animate completion:(id)completion {
    IRLog(@"вызван uninstallIcon:animate:completion:");
    if (gPassThrough) { %orig; return; }
    id completionCopy = [completion copy];
    BOOL started = IRStartEffect(icon, ^{
        %orig(icon, NO, completionCopy);
    });
    if (!started) { %orig; }
}

- (void)uninstallIcon:(SBIcon *)icon animate:(BOOL)animate {
    IRLog(@"вызван uninstallIcon:animate:");
    if (gPassThrough) { %orig; return; }
    BOOL started = IRStartEffect(icon, ^{
        %orig(icon, NO);
    });
    if (!started) { %orig; }
}

- (void)uninstallIcon:(SBIcon *)icon {
    IRLog(@"вызван uninstallIcon:");
    if (gPassThrough) { %orig; return; }
    BOOL started = IRStartEffect(icon, ^{
        %orig(icon);
    });
    if (!started) { %orig; }
}

%end

// Запасной вариант: самый последний шаг удаления приложения
%hook SBLeafIcon

- (void)completeUninstall {
    IRLog(@"вызван SBLeafIcon completeUninstall");
    if (gPassThrough) { %orig; return; }
    BOOL started = IRStartEffect((SBIcon *)self, ^{
        %orig;
    });
    if (!started) { %orig; }
}

%end

%ctor {
    IRLog(@"=== IconReaper v8 загружен ===");
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    IRPreviewCallback, CFSTR("com.user.iconreaper/preview"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    %init;
}
