#import "RNNCommandsHandler.h"
#import "RNNNavigationOptions.h"
#import "RNNRootViewController.h"
#import "RNNSplitViewController.h"
#import "RNNElementFinder.h"
#import "React/RCTUIManager.h"
#import "RNNErrorHandler.h"
#import "RNNDefaultOptionsHelper.h"
#import "UIViewController+RNNOptions.h"
#import "React/RCTI18nUtil.h"

static NSString* const setRoot	= @"setRoot";
static NSString* const setStackRoot	= @"setStackRoot";
static NSString* const push	= @"push";
static NSString* const preview	= @"preview";
static NSString* const pop	= @"pop";
static NSString* const popTo	= @"popTo";
static NSString* const popToRoot	= @"popToRoot";
static NSString* const showModal	= @"showModal";
static NSString* const dismissModal	= @"dismissModal";
static NSString* const dismissAllModals	= @"dismissAllModals";
static NSString* const showOverlay	= @"showOverlay";
static NSString* const dismissOverlay	= @"dismissOverlay";
static NSString* const mergeOptions	= @"mergeOptions";
static NSString* const setDefaultOptions	= @"setDefaultOptions";

@interface RNNCommandsHandler() <RNNModalManagerDelegate>

@end

@implementation RNNCommandsHandler {
	RNNControllerFactory *_controllerFactory;
	RNNStore *_store;
	RNNModalManager* _modalManager;
	RNNOverlayManager* _overlayManager;
	RNNNavigationStackManager* _stackManager;
	RNNEventEmitter* _eventEmitter;
	UIWindow* _mainWindow;
}

- (instancetype)initWithStore:(RNNStore*)store controllerFactory:(RNNControllerFactory*)controllerFactory eventEmitter:(RNNEventEmitter *)eventEmitter stackManager:(RNNNavigationStackManager *)stackManager modalManager:(RNNModalManager *)modalManager overlayManager:(RNNOverlayManager *)overlayManager mainWindow:(UIWindow *)mainWindow {
	self = [super init];
	_store = store;
	_controllerFactory = controllerFactory;
	_eventEmitter = eventEmitter;
	_modalManager = modalManager;
	_modalManager.delegate = self;
	_stackManager = stackManager;
	_overlayManager = overlayManager;
	_mainWindow = mainWindow;
	return self;
}

#pragma mark - public

- (void)setRoot:(NSDictionary*)layout commandId:(NSString*)commandId completion:(RNNTransitionCompletionBlock)completion {
	[self assertReady];

	if (@available(iOS 9, *)) {
	    if(_controllerFactory.defaultOptions.layout.direction.hasValue) {
	        if ([_controllerFactory.defaultOptions.layout.direction.get isEqualToString:@"rtl"]) {
                [[RCTI18nUtil sharedInstance] allowRTL:YES];
                [[RCTI18nUtil sharedInstance] forceRTL:YES];
                [[UIView appearance] setSemanticContentAttribute:UISemanticContentAttributeForceRightToLeft];
                [[UINavigationBar appearance] setSemanticContentAttribute:UISemanticContentAttributeForceRightToLeft];
            } else {
                [[RCTI18nUtil sharedInstance] allowRTL:NO];
                [[RCTI18nUtil sharedInstance] forceRTL:NO];
                [[UIView appearance] setSemanticContentAttribute:UISemanticContentAttributeForceLeftToRight];
                [[UINavigationBar appearance] setSemanticContentAttribute:UISemanticContentAttributeForceLeftToRight];
            }
	    }
	}

	[_modalManager dismissAllModalsAnimated:NO];
	[_store removeAllComponentsFromWindow:_mainWindow];
	
	UIViewController<RNNLayoutProtocol> *vc = [_controllerFactory createLayout:layout[@"root"]];
	
	[vc renderTreeAndWait:[vc.resolveOptions.animations.setRoot.waitForRender getWithDefaultValue:NO] perform:^{
		_mainWindow.rootViewController = vc;
		[_eventEmitter sendOnNavigationCommandCompletion:setRoot commandId:commandId params:@{@"layout": layout}];
		completion() ;
	}];
}

- (void)mergeOptions:(NSString*)componentId options:(NSDictionary*)mergeOptions completion:(RNNTransitionCompletionBlock)completion {
	[self assertReady];
	
	UIViewController<RNNLayoutProtocol>* vc = (UIViewController<RNNLayoutProtocol>*)[_store findComponentForId:componentId];
	RNNNavigationOptions* newOptions = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	if ([vc conformsToProtocol:@protocol(RNNLayoutProtocol)] || [vc isKindOfClass:[RNNRootViewController class]]) {
		[CATransaction begin];
		[CATransaction setCompletionBlock:completion];
		
		[vc overrideOptions:newOptions];
		[vc mergeOptions:newOptions];
		
		[CATransaction commit];
	}
}

- (void)setDefaultOptions:(NSDictionary*)optionsDict completion:(RNNTransitionCompletionBlock)completion {
	[self assertReady];
	RNNNavigationOptions* defaultOptions = [[RNNNavigationOptions alloc] initWithDict:optionsDict];
	[_controllerFactory setDefaultOptions:defaultOptions];
	
	UIViewController *rootViewController = UIApplication.sharedApplication.delegate.window.rootViewController;
	[RNNDefaultOptionsHelper recrusivelySetDefaultOptions:defaultOptions onRootViewController:rootViewController];
	
	completion();
}

- (void)push:(NSString*)componentId commandId:(NSString*)commandId layout:(NSDictionary*)layout completion:(RNNTransitionCompletionBlock)completion rejection:(RCTPromiseRejectBlock)rejection {
	[self assertReady];
	
	UIViewController<RNNLayoutProtocol> *newVc = [_controllerFactory createLayout:layout];
	UIViewController *fromVC = [_store findComponentForId:componentId];
	
	if ([[newVc.resolveOptions.preview.reactTag getWithDefaultValue:@(0)] floatValue] > 0) {
		UIViewController* vc = [_store findComponentForId:componentId];
		
		if([vc isKindOfClass:[RNNRootViewController class]]) {
			RNNRootViewController* rootVc = (RNNRootViewController*)vc;
			rootVc.previewController = newVc;
			[newVc renderTreeAndWait:NO perform:nil];
			
			rootVc.previewCallback = ^(UIViewController *vcc) {
				RNNRootViewController* rvc  = (RNNRootViewController*)vcc;
				[self->_eventEmitter sendOnPreviewCompleted:componentId previewComponentId:newVc.layoutInfo.componentId];
				if ([newVc.resolveOptions.preview.commit getWithDefaultValue:NO]) {
					[CATransaction begin];
					[CATransaction setCompletionBlock:^{
						[self->_eventEmitter sendOnNavigationCommandCompletion:push commandId:commandId params:@{@"componentId": componentId}];
						completion();
					}];
					[rvc.navigationController pushViewController:newVc animated:YES];
					[CATransaction commit];
				}
			};
			
			CGSize size = CGSizeMake(rootVc.view.frame.size.width, rootVc.view.frame.size.height);
			
			if (newVc.resolveOptions.preview.width.hasValue) {
				size.width = [newVc.resolveOptions.preview.width.get floatValue];
			}
			
			if (newVc.resolveOptions.preview.height.hasValue) {
				size.height = [newVc.resolveOptions.preview.height.get floatValue];
			}
			
			if (newVc.resolveOptions.preview.width.hasValue || newVc.resolveOptions.preview.height.hasValue) {
				newVc.preferredContentSize = size;
			}
			
			RCTExecuteOnMainQueue(^{
				UIView *view = [[ReactNativeNavigation getBridge].uiManager viewForReactTag:newVc.resolveOptions.preview.reactTag.get];
				[rootVc registerForPreviewingWithDelegate:(id)rootVc sourceView:view];
			});
		}
	} else {
		id animationDelegate = (newVc.resolveOptions.animations.push.hasCustomAnimation || newVc.resolveOptions.customTransition.animations) ? newVc : nil;
		[newVc renderTreeAndWait:([newVc.resolveOptions.animations.push.waitForRender getWithDefaultValue:NO] || animationDelegate) perform:^{
			[_stackManager push:newVc onTop:fromVC animated:[newVc.resolveOptions.animations.push.enable getWithDefaultValue:YES] animationDelegate:animationDelegate completion:^{
				[_eventEmitter sendOnNavigationCommandCompletion:push commandId:commandId params:@{@"componentId": componentId}];
				completion();
			} rejection:rejection];
		}];
	}
}

- (void)setStackRoot:(NSString*)componentId commandId:(NSString*)commandId children:(NSArray*)children completion:(RNNTransitionCompletionBlock)completion rejection:(RCTPromiseRejectBlock)rejection {
	[self assertReady];
	
 	NSArray<RNNLayoutProtocol> *childViewControllers = [_controllerFactory createChildrenLayout:children];
	for (UIViewController<RNNLayoutProtocol>* viewController in childViewControllers) {
		[viewController renderTreeAndWait:NO perform:nil];
	}
	RNNNavigationOptions* options = [childViewControllers.lastObject getCurrentChild].resolveOptions;
	UIViewController *fromVC = [_store findComponentForId:componentId];
	__weak typeof(RNNEventEmitter*) weakEventEmitter = _eventEmitter;
	[_stackManager setStackChildren:childViewControllers fromViewController:fromVC animated:[options.animations.setStackRoot.enable getWithDefaultValue:YES] completion:^{
		[weakEventEmitter sendOnNavigationCommandCompletion:setStackRoot commandId:commandId params:@{@"componentId": componentId}];
		completion();
	} rejection:rejection];
}

- (void)pop:(NSString*)componentId commandId:(NSString*)commandId mergeOptions:(NSDictionary*)mergeOptions completion:(RNNTransitionCompletionBlock)completion rejection:(RCTPromiseRejectBlock)rejection {
	[self assertReady];
	
	RNNRootViewController *vc = (RNNRootViewController*)[_store findComponentForId:componentId];
	RNNNavigationOptions *options = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	[vc overrideOptions:options];
	
	UINavigationController *nvc = vc.navigationController;
	
	if ([nvc topViewController] == vc) {
		if (vc.resolveOptions.animations.pop) {
			nvc.delegate = vc;
		} else {
			nvc.delegate = nil;
		}
	} else {
		NSMutableArray * vcs = nvc.viewControllers.mutableCopy;
		[vcs removeObject:vc];
		[nvc setViewControllers:vcs animated:[vc.resolveOptions.animations.pop.enable getWithDefaultValue:YES]];
	}
	
	[_stackManager pop:vc animated:[vc.resolveOptions.animations.pop.enable getWithDefaultValue:YES] completion:^{
		[_store removeComponent:componentId];
		[_eventEmitter sendOnNavigationCommandCompletion:pop commandId:commandId params:@{@"componentId": componentId}];
		completion();
	} rejection:rejection];
}

- (void)popTo:(NSString*)componentId commandId:(NSString*)commandId mergeOptions:(NSDictionary *)mergeOptions completion:(RNNTransitionCompletionBlock)completion rejection:(RCTPromiseRejectBlock)rejection {
	[self assertReady];
	RNNRootViewController *vc = (RNNRootViewController*)[_store findComponentForId:componentId];
	RNNNavigationOptions *options = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	[vc overrideOptions:options];
	
	[_stackManager popTo:vc animated:[vc.resolveOptions.animations.pop.enable getWithDefaultValue:YES] completion:^(NSArray *poppedViewControllers) {
		[_eventEmitter sendOnNavigationCommandCompletion:popTo commandId:commandId params:@{@"componentId": componentId}];
		[self removePopedViewControllers:poppedViewControllers];
		completion();
	} rejection:rejection];
}

- (void)popToRoot:(NSString*)componentId commandId:(NSString*)commandId mergeOptions:(NSDictionary *)mergeOptions completion:(RNNTransitionCompletionBlock)completion rejection:(RCTPromiseRejectBlock)rejection {
	[self assertReady];
	RNNRootViewController *vc = (RNNRootViewController*)[_store findComponentForId:componentId];
	RNNNavigationOptions *options = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	[vc overrideOptions:options];
	
	[CATransaction begin];
	[CATransaction setCompletionBlock:^{
		[_eventEmitter sendOnNavigationCommandCompletion:popToRoot commandId:commandId params:@{@"componentId": componentId}];
		completion();
	}];
	
	[_stackManager popToRoot:vc animated:[vc.resolveOptions.animations.pop.enable getWithDefaultValue:YES] completion:^(NSArray *poppedViewControllers) {
		[self removePopedViewControllers:poppedViewControllers];
	} rejection:^(NSString *code, NSString *message, NSError *error) {
		
	}];
	
	[CATransaction commit];
}

- (void)showModal:(NSDictionary*)layout commandId:(NSString *)commandId completion:(RNNTransitionWithComponentIdCompletionBlock)completion {
	[self assertReady];
	
	UIViewController<RNNParentProtocol> *newVc = [_controllerFactory createLayout:layout];
	
	[newVc renderTreeAndWait:[newVc.resolveOptions.animations.showModal.waitForRender getWithDefaultValue:NO] perform:^{
		[_modalManager showModal:newVc animated:[newVc.getCurrentChild.resolveOptions.animations.showModal.enable getWithDefaultValue:YES] hasCustomAnimation:newVc.getCurrentChild.resolveOptions.animations.showModal.hasCustomAnimation completion:^(NSString *componentId) {
			[_eventEmitter sendOnNavigationCommandCompletion:showModal commandId:commandId params:@{@"layout": layout}];
			completion(componentId);
		}];
	}];
}

- (void)dismissModal:(NSString*)componentId commandId:(NSString*)commandId mergeOptions:(NSDictionary *)mergeOptions completion:(RNNTransitionCompletionBlock)completion rejection:(RNNTransitionRejectionBlock)reject {
	[self assertReady];
	
	UIViewController<RNNParentProtocol> *modalToDismiss = (UIViewController<RNNParentProtocol>*)[_store findComponentForId:componentId];
	
	if (!modalToDismiss.isModal) {
		[RNNErrorHandler reject:reject withErrorCode:1013 errorDescription:@"component is not a modal"];
		return;
	}
	
	RNNNavigationOptions *options = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	[modalToDismiss.getCurrentChild overrideOptions:options];
	
	[self removePopedViewControllers:modalToDismiss.navigationController.viewControllers];
	
	[CATransaction begin];
	[CATransaction setCompletionBlock:^{
		[_eventEmitter sendOnNavigationCommandCompletion:dismissModal commandId:commandId params:@{@"componentId": componentId}];
	}];
	
	[_modalManager dismissModal:modalToDismiss completion:completion];
	
	[CATransaction commit];
}

- (void)dismissAllModals:(NSDictionary *)mergeOptions commandId:(NSString*)commandId completion:(RNNTransitionCompletionBlock)completion {
	[self assertReady];
	
	[CATransaction begin];
	[CATransaction setCompletionBlock:^{
		[_eventEmitter sendOnNavigationCommandCompletion:dismissAllModals commandId:commandId params:@{}];
		completion();
	}];
	RNNNavigationOptions* options = [[RNNNavigationOptions alloc] initWithDict:mergeOptions];
	[_modalManager dismissAllModalsAnimated:[options.animations.dismissModal.enable getWithDefaultValue:YES]];
	
	[CATransaction commit];
}

- (void)showOverlay:(NSDictionary *)layout commandId:(NSString*)commandId completion:(RNNTransitionCompletionBlock)completion {
	[self assertReady];
	
	UIViewController<RNNParentProtocol>* overlayVC = [_controllerFactory createLayout:layout];
	[overlayVC renderTreeAndWait:NO perform:^{
		UIWindow* overlayWindow = [[RNNOverlayWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
		overlayWindow.rootViewController = overlayVC;
		[_overlayManager showOverlayWindow:overlayWindow];
		[_eventEmitter sendOnNavigationCommandCompletion:showOverlay commandId:commandId params:@{@"layout": layout}];
		completion();
	}];
}

- (void)dismissOverlay:(NSString*)componentId commandId:(NSString*)commandId completion:(RNNTransitionCompletionBlock)completion rejection:(RNNTransitionRejectionBlock)reject {
	[self assertReady];
	UIViewController* viewController = [_store findComponentForId:componentId];
	if (viewController) {
		[_overlayManager dismissOverlay:viewController];
		[_eventEmitter sendOnNavigationCommandCompletion:dismissOverlay commandId:commandId params:@{@"componentId": componentId}];
		completion();
	} else {
		[RNNErrorHandler reject:reject withErrorCode:1010 errorDescription:@"ComponentId not found"];
	}
}

#pragma mark - private

- (void)removePopedViewControllers:(NSArray*)viewControllers {
	for (UIViewController *popedVC in viewControllers) {
		[_store removeComponentByViewControllerInstance:popedVC];
	}
}

- (void)assertReady {
	if (!_store.isReadyToReceiveCommands) {
		[[NSException exceptionWithName:@"BridgeNotLoadedError"
								 reason:@"Bridge not yet loaded! Send commands after Navigation.events().onAppLaunched() has been called."
							   userInfo:nil]
		 raise];
	}
}

#pragma mark - RNNModalManagerDelegate

- (void)dismissedModal:(UIViewController<RNNParentProtocol> *)viewController {
	[_eventEmitter sendModalsDismissedEvent:viewController.layoutInfo.componentId numberOfModalsDismissed:@(1)];
}

- (void)dismissedMultipleModals:(NSArray *)viewControllers {
	if (viewControllers && viewControllers.count) {
		[_eventEmitter sendModalsDismissedEvent:((UIViewController<RNNParentProtocol> *)viewControllers.lastObject).layoutInfo.componentId numberOfModalsDismissed:@(viewControllers.count)];
	}
}

@end
