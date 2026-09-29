#import <SDWebImage/UIImageView+WebCache.h>
#import "CoverViewController.h"
#import "EmulatorViewController.h"
#import "SettingsViewController.h"
#import "../ui_shared/BootablesProcesses.h"
#import "../ui_shared/BootablesDbClient.h"
#import "PathUtils.h"
#import "BackgroundLayer.h"
#import "CoverViewCell.h"
#import "AltServerJitService.h"
#include "../../deps/CodeGen/include/MemoryFunction.h"
#include <dlfcn.h>
#include <notify.h>
#include <objc/message.h>

static NSString* GetProcessBundleIDForStikDebug()
{
	// LiveContainer/FlekDeck can spoof NSBundle.mainBundle to the guest app.
	// StikDebug needs the bundle ID of the actual installed host process so it
	// can return to it after attaching by PID. Read that from the process's own
	// application-identifier entitlement instead.
	void* security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
	if(security != nullptr)
	{
		typedef void* (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
		typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(void*, CFStringRef, CFErrorRef*);
		auto createTask = reinterpret_cast<SecTaskCreateFromSelfFn>(dlsym(security, "SecTaskCreateFromSelf"));
		auto copyEntitlement = reinterpret_cast<SecTaskCopyValueForEntitlementFn>(dlsym(security, "SecTaskCopyValueForEntitlement"));
		if(createTask && copyEntitlement)
		{
			void* task = createTask(nullptr);
			if(task)
			{
				CFTypeRef value = copyEntitlement(task, CFSTR("application-identifier"), nullptr);
				if(value && CFGetTypeID(value) == CFStringGetTypeID())
				{
					char buffer[1024] = {};
					if(CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8))
					{
						NSString* applicationIdentifier = [NSString stringWithUTF8String:buffer];
						NSRange firstDot = [applicationIdentifier rangeOfString:@"."];
						if(firstDot.location != NSNotFound && (firstDot.location + 1) < applicationIdentifier.length)
						{
							NSString* hostBundleID = [applicationIdentifier substringFromIndex:(firstDot.location + 1)];
							CFRelease(value);
							CFRelease((CFTypeRef)task);
							dlclose(security);
							return hostBundleID;
						}
					}
				}
				if(value) CFRelease(value);
				CFRelease((CFTypeRef)task);
			}
		}
		dlclose(security);
	}
	return [[NSBundle mainBundle] bundleIdentifier];
}

static void PublishStikDebugDirectRequest()
{
	int token = 0;
	const char* name = "com.ajthatkid.playjit.pid";
	if(notify_register_check(name, &token) == NOTIFY_STATUS_OK)
	{
		notify_set_state(token, static_cast<uint64_t>(getpid()));
		notify_post(name);
		notify_cancel(token);
	}
}

static bool OpenStikDebugDirectly()
{
	Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
	if(workspaceClass == Nil) return false;
	SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
	if(![workspaceClass respondsToSelector:defaultWorkspaceSel]) return false;
	id workspace = ((id(*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultWorkspaceSel);
	if(workspace == nil) return false;
	SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
	if(![workspace respondsToSelector:openSel]) return false;
	return ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, openSel, @"com.stik.stikdebug") == YES;
}

static bool IsJitAvailable()
{
	if(MemFunc_IsJitReady()) return true;

	// On iOS/iPadOS 26+, a debugger flag by itself is not enough. The executable
	// arena must actually be prepared through the universal StikDebug protocol.
	if(@available(iOS 26.0, *))
	{
		return false;
	}

	// Legacy paths remain valid on older systems.
	if(getppid() != 1) return true;
	if([[AltServerJitService sharedAltServerJitService] jitEnabled])
	{
		return true;
	}
	{
		std::error_code errorCode;
		fs::directory_iterator dirIterator("/private/var/mobile", errorCode);
		if(!errorCode)
		{
			return true;
		}
	}
	return false;
}

@interface CoverViewController ()
- (void)beginStikDebugJitLaunch:(id)sender;
- (void)pollForJitAndLaunch:(id)sender alert:(UIAlertController*)alert attemptsRemaining:(NSInteger)attempts
{
	UIApplication* application = [UIApplication sharedApplication];
	__block UIBackgroundTaskIdentifier backgroundTask = UIBackgroundTaskInvalid;
	backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
	  if(backgroundTask != UIBackgroundTaskInvalid)
	  {
		  [application endBackgroundTask:backgroundTask];
		  backgroundTask = UIBackgroundTaskInvalid;
	  }
	}];

	// The target must execute the universal JIT breakpoints while StikDebug is
	// in the foreground. Keep this work off the main queue so iOS can continue
	// the handshake during the app switch.
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
	  NSInteger remaining = attempts;
	  while(remaining-- > 0 && !MemFunc_IsJitReady())
	  {
		  MemFunc_InitJitArena();
		  if(MemFunc_IsJitReady()) break;
		  usleep(250000);
	  }

	  const bool ready = MemFunc_IsJitReady();
	  const char* statusCString = MemFunc_GetJitStatus();
	  NSString* status = statusCString ? [NSString stringWithUTF8String:statusCString] : @"jit: unknown";

	  dispatch_async(dispatch_get_main_queue(), ^{
		  if(backgroundTask != UIBackgroundTaskInvalid)
		  {
			  [application endBackgroundTask:backgroundTask];
			  backgroundTask = UIBackgroundTaskInvalid;
		  }

		  if(ready)
		  {
			  [alert dismissViewControllerAnimated:YES completion:^{
			    [self performSegueWithIdentifier:@"showEmulator" sender:sender];
			  }];
			  return;
		  }

		  NSString* message = [NSString stringWithFormat:@"JIT did not become ready. %@\n\nKeep LocalDevVPN connected and use the patched StikDebug build.", status];
		  [alert dismissViewControllerAnimated:YES completion:^{
			  UIAlertController* error =
			      [UIAlertController alertControllerWithTitle:@"JIT setup failed"
			                                        message:message
			                                 preferredStyle:UIAlertControllerStyleAlert];
			  [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			  [self presentViewController:error animated:YES completion:nil];
		  }];
	  });
	});
}

#pragma mark <UICollectionViewDelegate>

- (BOOL)shouldPerformSegueWithIdentifier:(NSString*)identifier sender:(id)sender
{
	if(![identifier isEqualToString:@"showEmulator"]) return YES;

	// If a compatible debugger is already attached, this prepares the arena now.
	if(!MemFunc_IsJitReady())
	{
		MemFunc_InitJitArena();
	}
	if(IsJitAvailable()) return YES;

	if(@available(iOS 26.0, *))
	{
		// Never boot the PS2 VM until the executable arena is confirmed ready.
		[self beginStikDebugJitLaunch:sender];
		return NO;
	}

	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"JIT unavailable" message:@"JIT doesn't seem to be available at the moment. If JIT is not available, the emulator will crash. Do you wish to continue?" preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
	  [self performSegueWithIdentifier:@"showEmulator" sender:sender];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction*){}]];
	[self presentViewController:alert animated:YES completion:nil];
	return NO;
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
	if([segue.identifier isEqualToString:@"showEmulator"])
	{
		NSIndexPath* indexPath = [[self.collectionView indexPathsForSelectedItems] objectAtIndex:0];
		auto bootable = (*_bootables)[indexPath.row];
		BootablesDb::CClient::GetInstance().SetLastBootedTime(bootable.path, time(nullptr));
		EmulatorViewController* emulatorViewController = segue.destinationViewController;
		emulatorViewController.bootablePath = [NSString stringWithUTF8String:bootable.path.native().c_str()];
		[self.collectionView deselectItemAtIndexPath:indexPath animated:NO];
	}
	else if([segue.identifier isEqualToString:@"showSettings"])
	{
		UINavigationController* navViewController = segue.destinationViewController;
		SettingsViewController* settingsViewController = (SettingsViewController*)navViewController.visibleViewController;
		settingsViewController.allowFullDeviceScan = true;
		settingsViewController.allowGsHandlerSelection = true;
		settingsViewController.completionHandler = ^(bool fullScanRequested) {
		  [[AltServerJitService sharedAltServerJitService] startProcess];
		  if(fullScanRequested)
		  {
			  [self buildCollectionWithForcedFullScan:YES];
		  }
		};
	}
}

- (IBAction)onExit:(id)sender
{
	exit(0);
}

@end
