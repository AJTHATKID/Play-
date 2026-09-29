#import "AppDelegate.h"
#import "EmulatorViewController.h"
#include "../gs/GSH_OpenGL/GSH_OpenGL.h"
#include "DebuggerSimulator.h"
#include "../../deps/CodeGen/include/MemoryFunction.h"
#include <unistd.h>

static bool gStikDebugRequested = false;
static bool gJitPolling = false;

@interface AppDelegate ()
- (void)requestStikDebugJIT;
- (void)pollForStikDebugJIT:(NSInteger)attempts;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOption
{
	[EmulatorViewController registerPreferences];
	CGSH_OpenGL::RegisterPreferences();
	return YES;
}

- (void)requestStikDebugJIT
{
	if(MemFunc_IsJitReady()) return;

	NSString* bundleID = [[NSBundle mainBundle] bundleIdentifier];
	if(bundleID == nil) return;

	NSURLComponents* components = [[NSURLComponents alloc] init];
	components.scheme = @"stikdebug";
	components.host = @"enable-jit";

	NSMutableArray<NSURLQueryItem*>* queryItems = [NSMutableArray arrayWithArray:@[
		[NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
		[NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]],
	]];

	// iOS/iPadOS 26+ requires the universal breakpoint protocol on TXM/SPTM
	// devices. Play!'s patched CodeGen implements that protocol.
	if(@available(iOS 26.0, *))
	{
		[queryItems addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
	}
	components.queryItems = queryItems;

	NSURL* url = components.URL;
	if(url == nil) return;

	gStikDebugRequested = true;
	[[UIApplication sharedApplication] openURL:url
	                                  options:@{}
	                        completionHandler:^(BOOL success) {
	                          if(!success)
	                          {
		                          // Allow another attempt if StikDebug wasn't available.
		                          gStikDebugRequested = false;
	                          }
	                        }];
}

- (void)pollForStikDebugJIT:(NSInteger)attempts
{
	if(MemFunc_IsJitReady())
	{
		gJitPolling = false;
		return;
	}

	// Safe to call repeatedly: the patched allocator only executes the breakpoint
	// protocol after CS_DEBUGGED is present, and otherwise remains retryable.
	MemFunc_InitJitArena();
	if(MemFunc_IsJitReady())
	{
		gJitPolling = false;
		return;
	}

	if(attempts <= 0)
	{
		gJitPolling = false;
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
	               dispatch_get_main_queue(), ^{
	                 [self pollForStikDebugJIT:(attempts - 1)];
	               });
}

- (void)applicationWillResignActive:(UIApplication*)application
{
}

- (void)applicationDidEnterBackground:(UIApplication*)application
{
}

- (void)applicationWillEnterForeground:(UIApplication*)application
{
}

- (void)applicationDidBecomeActive:(UIApplication*)application
{
	if(MemFunc_IsJitReady()) return;

	if(!gStikDebugRequested)
	{
		// Give the app one short moment to finish becoming active before handing
		// off to StikDebug. This avoids the manual app-selection flow entirely.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)),
		               dispatch_get_main_queue(), ^{
		                 [self requestStikDebugJIT];
		               });
		return;
	}

	if(!gJitPolling)
	{
		gJitPolling = true;
		[self pollForStikDebugJIT:40];
	}
}

- (void)applicationWillTerminate:(UIApplication*)application
{
	StopSimulateDebugger();
}

@end
