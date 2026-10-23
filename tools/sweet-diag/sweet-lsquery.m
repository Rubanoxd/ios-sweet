// sweet-lsquery BUNDLEID...: what LaunchServices knows about an app and its plug-ins.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)i;
@end
@interface LSPlugInKitProxy : NSObject
+ (id)pluginKitProxyForIdentifier:(NSString *)i;
@end
static id kv(id o, NSString *k){@try{return [o valueForKey:k];}@catch(id e){return @"<n/a>";}}
int main(int argc,char**argv){@autoreleasepool{
  for(int i=1;i<argc;i++){
    NSString *bid=@(argv[i]);
    id a=[NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bid];
    if(a && [kv(a,@"isInstalled") boolValue]){
      printf("app %s: type %s installed %s restricted %s placeholder %s url %s\n",argv[i],[[kv(a,@"applicationType") description] UTF8String],
        [[kv(a,@"isInstalled") description] UTF8String],[[kv(a,@"isRestricted") description] UTF8String],[[kv(a,@"isPlaceholder") description] UTF8String],[[kv(a,@"bundleURL") description] UTF8String]);
      for(id p in kv(a,@"plugInKitPlugins"))
        printf("  plugin %s point %s\n",[[kv(p,@"bundleIdentifier") description] UTF8String],[[kv(p,@"protocol") description] UTF8String]);
      continue;
    }
    id p=[NSClassFromString(@"LSPlugInKitProxy") pluginKitProxyForIdentifier:bid];
    printf("%s: app %s, plugin %s point %s url %s\n",argv[i],a?"(not installed)":"none",p?"yes":"no",[[kv(p,@"protocol") description] UTF8String],[[kv(p,@"bundleURL") description] UTF8String]);
  }
}return 0;}
