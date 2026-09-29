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
- (void)pollForJitAndLaunch:(id)sender alert:(UIAlertController*)alert attemptsRemaining:(NSInteger)attempts;
@end

@implementation CoverViewController

static NSString* const reuseIdentifier = @"coverCell";

- (void)buildCollectionWithForcedFullScan:(BOOL)forceFullDeviceScan
{
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Building collection" message:@"Please wait..." preferredStyle:UIAlertControllerStyleAlert];

	CGRect aivRect = CGRectMake(0, 0, 40, 40);

	UIActivityIndicatorView* aiv = [[UIActivityIndicatorView alloc] initWithFrame:aivRect];
	[aiv startAnimating];

	UIViewController* vc = [[UIViewController alloc] init];
	vc.preferredContentSize = aivRect.size;
	[vc.view addSubview:aiv];
	[alert setValue:vc forKey:@"contentViewController"];

	[self presentViewController:alert animated:YES completion:nil];

	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_async(queue, ^{
	  auto activeDirs = GetActiveBootableDirectories();
	  if(forceFullDeviceScan)
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games on filesystem...";
		  });
		  ScanBootables("/private/var/mobile");
	  }
	  else if(!activeDirs.empty())
	  {
		  dispatch_async(dispatch_get_main_queue(), ^{
			alert.message = @"Scanning games in active directories...";
		  });
		  for(const auto& activeDir : activeDirs)
		  {
			  ScanBootables(activeDir, false);
		  }
	  }

	  //Always scan games in app storage. The app's path change when it's reinstalled,
	  //thus, games from the previous installation won't be found (will be deleted in PurgeInexistingFiles).
	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Scanning games in app storage...";
	  });
	  ScanBootables(Framework::PathUtils::GetPersonalDataPath());

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Purging inexisting files...";
	  });
	  PurgeInexistingFiles();

	  dispatch_async(dispatch_get_main_queue(), ^{
		alert.message = @"Fetching game titles...";
	  });
	  FetchGameTitles();

	  if(_bootables)
	  {
		  delete _bootables;
		  _bootables = nullptr;
	  }
	  _bootables = new BootableArray(BootablesDb::CClient::GetInstance().GetBootables());

	  //Done
	  dispatch_async(dispatch_get_main_queue(), ^{
		[alert dismissViewControllerAnimated:YES completion:nil];
		[self.collectionView reloadData];
	  });
	});
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	CAGradientLayer* bgLayer = [BackgroundLayer blueGradient];
	bgLayer.frame = self.view.bounds;
	[self.view.layer insertSublayer:bgLayer atIndex:0];

	self.collectionView.allowsMultipleSelection = NO;
	if(@available(iOS 11.0, *))
	{
		self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
	}

	[[AltServerJitService sharedAltServerJitService] startProcess];
	[self buildCollectionWithForcedFullScan:NO];
}

- (void)viewDidUnload
{
	assert(_bootables != nullptr);
	delete _bootables;

	[super viewDidUnload];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	// resize your layers based on the view’s new bounds
	[[[self.view.layer sublayers] objectAtIndex:0] setFrame:self.view.bounds];
}

- (BOOL)shouldAutorotate
{
	if([self isViewLoaded] && self.view.window)
	{
		return YES;
	}
	else
	{
		return NO;
	}
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView
{
	return 1;
}

- (NSString*)collectionView:(UICollectionView*)collectionView titleForHeaderInSection:(NSInteger)section
{
	return @"";
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section
{
	return _bootables ? _bootables->size() : 0;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath
{
	CoverViewCell* cell = (CoverViewCell*)[collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier forIndexPath:indexPath];

	auto bootable = (*_bootables)[indexPath.row];
	UIImage* placeholder = [UIImage imageNamed:@"boxart.png"];
	cell.nameLabel.text = [NSString stringWithUTF8String:bootable.title.c_str()];
	cell.backgroundView = [[UIImageView alloc] initWithImage:placeholder];

	if(!bootable.coverUrl.empty())
	{
		NSString* coverUrl = [NSString stringWithUTF8String:bootable.coverUrl.c_str()];
		[(UIImageView*)cell.backgroundView sd_setImageWithURL:[NSURL URLWithString:coverUrl] placeholderImage:placeholder];
	}

	return cell;
}

- (void)beginStikDebugJitLaunch:(id)sender
{
	NSString* bundleID = GetProcessBundleIDForStikDebug();
	if(bundleID == nil) return;

	UIAlertController* progressAlert =
	    [UIAlertController alertControllerWithTitle:@"Enabling JIT"
	                                      message:@"Opening StikDebug and preparing executable memory..."
	                               preferredStyle:UIAlertControllerStyleAlert];

	UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
	[spinner startAnimating];
	spinner.translatesAutoresizingMaskIntoConstraints = NO;
	[progressAlert.view addSubview:spinner];
	[NSLayoutConstraint activateConstraints:@[
		[spinner.centerXAnchor constraintEqualToAnchor:progressAlert.view.centerXAnchor],
		[spinner.bottomAnchor constraintEqualToAnchor:progressAlert.view.bottomAnchor constant:-18],
	]];

	[self presentViewController:progressAlert animated:YES completion:^{
	  NSURLComponents* components = [[NSURLComponents alloc] init];
	  // LiveContainer/FlekDeck uses the stikjit:// scheme for StikDebug. Newer
	  // standalone StikDebug also accepts stikdebug://, so use stikjit first and
	  // automatically fall back to stikdebug for compatibility with both setups.
	  components.scheme = @"stikjit";
	  components.host = @"enable-jit";
	  components.queryItems = @[
		  [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
		  [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]],
		  [NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"],
	  ];

	  NSURL* primaryURL = components.URL;
	  components.scheme = @"stikdebug";
	  NSURL* fallbackURL = components.URL;
	  if(primaryURL == nil || fallbackURL == nil)
	  {
		  [progressAlert dismissViewControllerAnimated:YES completion:nil];
		  return;
	  }

	  void (^beginPolling)(void) = ^{
	    [self pollForJitAndLaunch:sender alert:progressAlert attemptsRemaining:80];
	  };

	  PublishStikDebugDirectRequest();

	  [[UIApplication sharedApplication] openURL:primaryURL
	                                    options:@{}
	                          completionHandler:^(BOOL success) {
	                            if(success)
	                            {
		                            beginPolling();
		                            return;
	                            }

	                            // Older or differently packaged StikDebug builds
	                            // may expose only the stikdebug:// alias.
	                            [[UIApplication sharedApplication] openURL:fallbackURL
	                                                              options:@{}
	                                                    completionHandler:^(BOOL fallbackSuccess) {
	                                                      if(fallbackSuccess)
	                                                      {
		                                                      beginPolling();
		                                                      return;
	                                                      }

	                                                      if(OpenStikDebugDirectly())
	                                                      {
		                                                      beginPolling();
		                                                      return;
	                                                      }

	                                                      [progressAlert dismissViewControllerAnimated:YES completion:^{
		                                                      UIAlertController* error =
		                                                          [UIAlertController alertControllerWithTitle:@"Couldn't reach StikDebug"
		                                                                                            message:@"iOS couldn't open StikDebug by URL scheme or bundle ID. Install the patched StikDebug as a standalone app, not inside FlekDeck."
		                                                                                     preferredStyle:UIAlertControllerStyleAlert];
		                                                      [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		                                                      [self presentViewController:error animated:YES completion:nil];
	                                                      }];
	                                                    }];
	                          }];
	}];
}

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
