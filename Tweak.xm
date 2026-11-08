// IconReaper — своя анимация удаления приложений (чёрная дыра)

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ============ НАСТРОЙКИ ============
static const CGFloat        kIconScale = 1.8;
static const NSTimeInterval kFadeOut   = 0.9;
static const NSTimeInterval kCrawl     = 1.3;
static const NSTimeInterval kDeleteAt  = 1.0;
static const NSTimeInterval kEffect    = 1.5;
static const NSTimeInterval kFadeIn    = 1.8;
// ====================================

@interface SBIcon : NSObject
- (UIImage *)generateIconImage:(int)format;
@end

@interface SBIconView : UIView
- (UIView *)_iconImageView;
@end

@interface SBIconViewMap : NSObject
+ (instancetype)homescreenMap;
- (SBIconView *)mappedIconViewForIcon:(SBIcon *)icon;
@end

@interface SBIconController : NSObject
- (void)uninstallIcon:(SBIcon *)icon animate:(BOOL)animate;
@end

static UIWindow *gWindow = nil;
static BOOL gBusy = NO;

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

static UIImage *IRSnapshotOfView(UIView *v) {
    UIGraphicsBeginImageContextWithOptions(v.bounds.size, NO, 0);
    [v.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static void IRPlayBlackHole(UIImage *image, CGRect startFrame, void (^deleteBlock)(void)) {
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

    UIView *dim = [[UIView alloc] initWithFrame:screen];
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0;
    [root addSubview:dim];

    UIView *hole = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 260)];
    hole.center = center;
    hole.alpha = 0;
    hole.transform = CGAffineTransformMakeScale(0.1, 0.1);
    [root addSubview:hole];

    CGFloat radii[3] = {120, 90, 62};
    for (int i = 0; i < 3; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = hole.bounds;
        CGFloat r = radii[i];
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(130 - r, 130 - r, r * 2, r * 2)].CGPath;
        ring.fillColor = [UIColor clearColor].CGColor;
        ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        ring.lineWidth = 2.5;
        ring.lineDashPattern = @[@(4 + i * 3), @10];
        [hole.layer addSublayer:ring];

        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @((i % 2 == 0 ? 1 : -1) * M_PI * 2);
        spin.duration = 3.0 / (i + 1);
        spin.repeatCount = HUGE_VALF;
        [ring addAnimation:spin forKey:@"spin"];
    }
    UIView *core = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
    core.center = CGPointMake(130, 130);
    core.backgroundColor = [UIColor blackColor];
    core.layer.cornerRadius = 32;
    core.layer.shadowColor = [UIColor whiteColor].CGColor;
    core.layer.shadowOpacity = 0.9;
    core.layer.shadowRadius = 16;
    core.layer.shadowOffset = CGSizeZero;
    [hole addSubview:core];

    UIView *holder = [[UIView alloc] initWithFrame:startFrame];
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = holder.bounds;
    [holder addSubview:icon];
    [root addSubview:holder];

    [UIView animateWithDuration:kFadeOut animations:^{
        dim.alpha = 1.0;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeleteAt * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (deleteBlock) deleteBlock();
    });

    [UIView animateWithDuration:kCrawl delay:0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        holder.center = center;
        holder.transform = CGAffineTransformMakeScale(kIconScale, kIconScale);
    } completion:^(BOOL finished) {

        [UIView animateWithDuration:0.5 animations:^{
            hole.alpha = 1.0;
            hole.transform = CGAffineTransformIdentity;
        }];

        CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rot.fromValue = @0;
        rot.toValue = @(M_PI * 6);
        rot.duration = kEffect;
        rot.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];

        CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        shrink.fromValue = @1.0;
        shrink.toValue = @0.02;
        shrink.duration = kEffect;
        shrink.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];

        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[rot, shrink];
        group.duration = kEffect;
        group.beginTime = CACurrentMediaTime() + 0.4;
        group.fillMode = kCAFillModeBoth;
        group.removedOnCompletion = NO;
        [icon.layer addAnimation:group forKey:@"blackhole"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.4 + kEffect) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            icon.hidden = YES;
            [UIView animateWithDuration:0.5 animations:^{
                hole.alpha = 0;
                hole.transform = CGAffineTransformMakeScale(0.05, 0.05);
            } completion:^(BOOL f2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:kFadeIn animations:^{
                        dim.alpha = 0;
                    } completion:^(BOOL f3) {
                        win.hidden = YES;
                        gWindow = nil;
                        gBusy = NO;
                        IRLog(@"эффект закончен");
                    }];
                });
            }];
        });
    }];
}

static BOOL IRStartEffect(SBIcon *icon, void (^deleteBlock)(void)) {
    if (gBusy || icon == nil) return NO;

    SBIconView *iconView = nil;
    Class mapClass = NSClassFromString(@"SBIconViewMap");
    if ([mapClass respondsToSelector:@selector(homescreenMap)]) {
        SBIconViewMap *map = [mapClass homescreenMap];
        if ([map respondsToSelector:@selector(mappedIconViewForIcon:)]) {
            iconView = [map mappedIconViewForIcon:icon];
        }
    }
    if (iconView == nil || iconView.window == nil) {
        IRLog(@"не нашёл вьюху иконки на экране — без эффекта");
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
        IRLog(@"не получилось взять картинку иконки — без эффекта");
        return NO;
    }

    CGSize size = imgView ? imgView.bounds.size : img.size;
    UIView *base = imgView ? imgView : iconView;
    CGRect r = [base convertRect:base.bounds toView:nil];
    CGRect frame = CGRectMake(CGRectGetMidX(r) - size.width / 2,
                              CGRectGetMidY(r) - size.height / 2,
                              size.width, size.height);

    IRLog(@"запускаю эффект чёрной дыры");
    gBusy = YES;
    IRPlayBlackHole(img, frame, deleteBlock);
    return YES;
}

%hook SBIconController

// ГЛАВНЫЙ ХУК: перехватываем нажатие на крестик
- (void)iconCloseBoxTapped:(id)iconView {
    IRLog(@"=== iconCloseBoxTapped вызван ===");
    
    // Получаем иконку из вьюхи
    SBIcon *icon = nil;
    if ([iconView respondsToSelector:@selector(icon)]) {
        icon = [iconView performSelector:@selector(icon)];
    }
    
    if (icon == nil) {
        IRLog(@"не получилось получить иконку из вьюхи");
        %orig;
        return;
    }
    
    // Запускаем эффект с отложенным удалением
    BOOL started = IRStartEffect(icon, ^{
        IRLog(@"удаляю приложение после анимации");
        // Вызываем оригинальный метод удаления
        [self uninstallIcon:icon animate:NO];
    });
    
    if (!started) {
        IRLog(@"эффект не запустился, удаляем стандартно");
        %orig;
    }
}

// На случай если вызывается напрямую
- (void)uninstallIcon:(SBIcon *)icon animate:(BOOL)animate {
    IRLog([NSString stringWithFormat:@"вызван uninstallIcon:animate: (занято: %d)", gBusy]);
    
    if (gBusy) {
        // Мы уже внутри эффекта, просто удаляем
        %orig(icon, NO);
        return;
    }
    
    BOOL started = IRStartEffect(icon, ^{
        IRLog(@"удаляю приложение (экран уже тёмный)");
        %orig(icon, NO);
    });
    if (!started) { %orig; }
}

%end

%ctor {
    IRLog(@"=== IconReaper v4 загружен ===");
    %init;
}
