#import "FlutterStarPrntPlugin.h"

#if __has_include(<flutter_star_prnt_plus/flutter_star_prnt_plus-Swift.h>)
#import <flutter_star_prnt_plus/flutter_star_prnt_plus-Swift.h>
#else
#import "flutter_star_prnt_plus-Swift.h"
#endif

@implementation FlutterStarPrntPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftFlutterStarPrntPlugin registerWithRegistrar:registrar];
}

@end
