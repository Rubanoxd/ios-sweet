// sweet-oslog SECONDS [PREDICATE]: live unified-log stream (LoggingSupport's OSLogEventLiveStream), one line per event.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
@interface OSLogEventLiveStream : NSObject
- (void)setEventHandler:(void (^)(id))handler;
- (void)setInvalidationHandler:(void (^)(int, id))handler;
- (void)setFilterPredicate:(NSPredicate *)p;
- (void)setFlags:(unsigned long long)f;
- (void)activate;
- (void)invalidate;
@end
int main(int argc, char **argv) {@autoreleasepool{
  if(!dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport",RTLD_NOW)){fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
  Class C=NSClassFromString(@"OSLogEventLiveStream");if(!C){fprintf(stderr,"no OSLogEventLiveStream\n");return 1;}
  double secs=argc>1?atof(argv[1]):10;
  OSLogEventLiveStream *st=[[C alloc] init];
  if(argc>2)[st setFilterPredicate:[NSPredicate predicateWithFormat:[NSString stringWithUTF8String:argv[2]]]];
  [st setFlags:0x1|0x2|0x4];  // info, debug, ...
  [st setEventHandler:^(id e){
    NSString *proc=[e valueForKey:@"process"],*msg=[e valueForKey:@"composedMessage"],*sub=[e valueForKey:@"subsystem"];
    unsigned type=[[e valueForKey:@"logType"] unsignedIntValue];
    printf("%s[%d] %02x %s: %s\n",proc.UTF8String?:"?",[[e valueForKey:@"processIdentifier"] intValue],type,sub.UTF8String?:"",msg.UTF8String?:"");fflush(stdout);
  }];
  [st setInvalidationHandler:^(int r,id x){fprintf(stderr,"invalidated %d\n",r);}];
  [st activate];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
  [st invalidate];
}return 0;}
