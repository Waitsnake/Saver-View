/* Copyright 2001 by Brian Nenninger

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

#import "SSSController.h"
#import "SSSFullScreenWindow.h"

// default initial window position if not specified
NSRect defaultContentRect() {
  NSRect screenFrame = [[NSScreen mainScreen] frame];
  return NSMakeRect(screenFrame.origin.x+50, screenFrame.origin.y+screenFrame.size.height-300, 320, 240);
}

// keep track of the last directory a background image was opened from
NSString *gLastImageDirectory = nil;

////////////////////////////////////////////////////////////////////////////////////////

@implementation SSSController

@class ScreenSaverView;

NSString *PAUSED_STRING = @": Paused"; // should be localized

-(id)initWithSaverClass:(Class)aClass title:(NSString *)t contentRect:(NSRect)contentRect {
  if (!aClass) return nil;
  self = [super init];
  if (!self) return nil;
  screenSaverClass = aClass;
  title = [t retain];

  window = [[NSWindow alloc] initWithContentRect:contentRect
                styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask)
                  backing:[screenSaverClass backingStoreType]
                    defer:YES];

  if (!window) return nil;
  
  [self finishInit];
  return self;
}

-(id)initWithSaverClass:(Class)aClass title:(NSString *)t {
  NSRect contentRect = defaultContentRect();
  return [self initWithSaverClass:aClass title:t contentRect:contentRect];
}

-(id)initFullScreen:(NSScreen *)screen withSaverClass:(Class)aClass title:(NSString *)t {
  if (!aClass) return nil;
  self = [super init];
  if (!self) return nil;
  screenSaverClass = aClass;
  title = [t retain];
  
  // SSSFullScreenWindow subclass of NSWindow is used to allow the borderless window
  // to become key and main
  window = [[SSSFullScreenWindow alloc] initWithContentRect:[screen frame]
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:[screenSaverClass backingStoreType]
                                                      defer:YES];

  if (!window) return nil;

  [self finishInit];
  return self;
}

-(void)finishInit {
  isPaused = isAppHidden = isScreenSaverRunning = NO;
  backgroundImageRep = nil;
  [window setMinSize:NSMakeSize(120,90)];
  [window setDelegate:self];
  checkedMenuItems = [[NSMutableArray array] retain];
  
  // set up application hide/unhide notifications
  [[NSNotificationCenter defaultCenter] addObserver:self 
                                          selector:@selector(appHidden:)
                                              name:NSApplicationWillHideNotification
                                            object:nil];
                                            
  [[NSNotificationCenter defaultCenter] addObserver:self 
                                          selector:@selector(appUnhidden:)
                                              name:NSApplicationDidUnhideNotification
                                            object:nil];
  
  // screen saver activation/deactivation notifications
  [[NSNotificationCenter defaultCenter] addObserver:self 
                                          selector:@selector(screenSaverActivated:)
                                              name:@"ScreenSaverActivated"
                                            object:nil];
                                            
  [[NSNotificationCenter defaultCenter] addObserver:self 
                                          selector:@selector(screenSaverDeactivated:)
                                              name:@"ScreenSaverDeactivated"
                                            object:nil];

}

-(void)dealloc {
  [title release];
  [backgroundImageRep release];
  [checkedMenuItems release];
  // remove self as observer
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  //NSLog(@"Deallocating SSSController");
  [super dealloc];
}

-(NSImageRep *)backgroundImageRep {
  return backgroundImageRep;
}

-(void)setBackgroundImageRep:(NSImageRep *)imageRep {
  if (backgroundImageRep!=imageRep) {
    [backgroundImageRep release];
    backgroundImageRep = [imageRep retain];
  }
}

// technically these accessors should be synchronized
-(NSString *)lastImageDirectory {
  if (gLastImageDirectory) return gLastImageDirectory;
  else return NSHomeDirectory();
}

-(void)setLastImageDirectory:(NSString *)dir {
  if (gLastImageDirectory!=dir) {
    [gLastImageDirectory release];
    gLastImageDirectory = [dir retain];
  }
}

-(NSWindow *)window {
  return window;
}

-(BOOL)isFullScreen {
  return ([window styleMask]==NSBorderlessWindowMask);
}

-(void)showWindow {
  NSRect contentViewRect = [[window contentView] frame];
  [window setTitle:title];
  // the ScreenSaverView subclass in the is the content view of the window
  screenSaverView = [[[screenSaverClass alloc] initWithFrame:contentViewRect isPreview:NO] autorelease];
  [window setContentView:screenSaverView];
  [window makeKeyAndOrderFront:nil];
  // force view to first responder in case this window was already front
  [window makeFirstResponder:screenSaverView]; 
}

-(void)start {
  if (![screenSaverView isAnimating]) {
    // Start the module's animation timer
    [screenSaverView startAnimation];
    [screenSaverView displayIfNeeded];
    if (backgroundImageRep) {
      // if we draw the image immediately, the ScreenSaverView will overwrite it, so we draw the
      // image in a future run loop iteration 
      [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(drawBackgroundImage:)
      userInfo:nil repeats:NO];
    }
  }
}

-(void)drawBackgroundImage:(NSTimer *)timer {
  [screenSaverView lockFocus];
  [backgroundImageRep drawInRect:[screenSaverView frame]];
  [screenSaverView unlockFocus];
  [screenSaverView displayIfNeeded];
}

-(void)stop {
  // This stops the module's animation timer. Some modules also reset their
  // internal state, which can make the single step feature behave oddly.
  if ([screenSaverView isAnimating]) [screenSaverView stopAnimation];
}

/* Starts the animation unless a condition exists in which it should not start 
(animation was paused, app is hidden, real screensaver is running, already running)
*/
-(void)startIfPossible {
  if (!isPaused && !isAppHidden && !isScreenSaverRunning && ![screenSaverView isAnimating]) {
    [self start];
  }
}

/* AppKit is fairly determined not to let borderless windows be closed; overridding performClose:
doesn't work so we need a differently named method.
*/
-(void)reallyClose:(id)sender {
  [window close];
}


//// menu actions

-(void)togglePause:(id)sender {
  BOOL isPausing = [screenSaverView isAnimating];
  if (isPausing) {
    [window setTitle:[title stringByAppendingString:PAUSED_STRING]];
    isPaused = YES;
    [self stop];
  }
  else {
    [window setTitle:title];
    isPaused = NO;
    [self startIfPossible];
  }
}

-(void)restart:(id)sender {
  // create a new ScreenSaverView and start over
 [self stop];
 isPaused = NO;
 [self showWindow];
 [self startIfPossible];
}

-(void)singleStepAnimation:(id)sender {
  // This doesn't work in all modules, since when this method is called the module
  // thinks that it is not animating. Seems to work in everything but the slideshows.
  if ([screenSaverView isAnimating]) {
    [self stop];
    [window setTitle:[title stringByAppendingString:PAUSED_STRING]];
  }
  [screenSaverView lockFocus];
  [screenSaverView animateOneFrame];
  [screenSaverView unlockFocus];
  // needed for non-OpenGL modules to update the display
  [screenSaverView displayIfNeeded];
}


//// window layer actions
-(void)moveToFrontLayer:(id)sender {
  [window setLevel:NSFloatingWindowLevel];
}

-(void)moveToStandardLayer:(id)sender {
  [window setLevel:NSNormalWindowLevel];
}

-(void)moveToBackLayer:(id)sender {
  [window setLevel:-1];
}

//// window size methods

/* Full screen windows have no borders, so when the user makes a window full screen
we actually destroy the current window, create a borderless full screen window, and
copy the necessary state. The same applies for making a full screen window not full screen.
*/
-(void)makeFullScreen:(id)sender {
  if (![self isFullScreen]) {
    id newController;
    int level = [window level];
    [window close];
    // we should only be autoreleased at this point
    newController = [[SSSController alloc] initFullScreen:[window screen] 
                                           withSaverClass:screenSaverClass
                                                    title:title];
    [newController setBackgroundImageRep:[self backgroundImageRep]];
    [[newController window] setLevel:level];
    [newController showWindow];
    [newController start];
  }
}

-(NSRect)defaultFrameForWidth:(int)w height:(int)h screen:(NSScreen *)screen {
  NSRect screenFrame = [screen frame];
  return NSMakeRect(screenFrame.origin.x+50, screenFrame.origin.y+screenFrame.size.height-60-h, w, h);
}

// width and height are of the content view, not the window itself
-(void)setWindowWidth:(int)w height:(int)h {
  if ([self isFullScreen]) {
    id newController;
    int level = [window level];
    NSScreen *windowScreen = [window screen];
    NSRect newRect = [self defaultFrameForWidth:w height:h screen:windowScreen];
    [window close];
    // we should only be autoreleased at this point
    newController = [[SSSController alloc] initWithSaverClass:screenSaverClass 
                                                        title:title 
                                                  contentRect:newRect];

    [newController setBackgroundImageRep:[self backgroundImageRep]];
    [[newController window] setLevel:level];
    [newController showWindow];
    [newController start];
  }
  else {
    NSRect rect = [window frame];
    NSRect contentRect = NSMakeRect(rect.origin.x, rect.origin.y+rect.size.height-h, w, h);
    // convert content view size to frame size
    [window setFrame:[NSWindow frameRectForContentRect:contentRect styleMask:[window styleMask]]
             display:NO];
  }
}

-(void)makeSize160:(id)sender {
  [self setWindowWidth:160 height:120];
}

-(void)makeSize320:(id)sender {
  [self setWindowWidth:320 height:240];
}

-(void)makeSize480:(id)sender {
  [self setWindowWidth:480 height:360];
}

-(void)makeSize640:(id)sender {
  [self setWindowWidth:640 height:480];
}

-(void)makeSize800:(id)sender {
  [self setWindowWidth:800 height:600];
}

-(void)selectBackgroundImage:(id)sender {
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  int result = [openPanel runModalForDirectory:[self lastImageDirectory] file:nil types:nil];
  if (result==NSOKButton) {
    NSString *filename  = [[openPanel filenames] lastObject];
    NSString *directory = [filename stringByDeletingLastPathComponent];
    NSData *imageData = [NSData dataWithContentsOfFile:[[openPanel filenames] lastObject]];
    NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:imageData];
    [self setLastImageDirectory:directory];
    [self setBackgroundImageRep:imageRep];
    [self restart:nil];
  }  
}

//// menu state

/* -validateMenuItem  sets checkmarks for the front/standard/back window layer items 
and the window size items. It calls setMenuItem:isChecked: to do this, which keeps 
track of checked items so they can be unchecked when the window is no longer main. 
There's probably a better way to do this.
*/
-(BOOL)validateMenuItem:(id <NSMenuItem>)menuItem {
  SEL action = [menuItem action];
  if (action==@selector(makeFullScreen:)) {
    [self setMenuItem:menuItem isChecked:[self isFullScreen]];
  }
  if (action==@selector(selectBackgroundImage:)) {
    // don't allow selecting background images for OpenGL modules
    if ([[[screenSaverView subviews] lastObject] isKindOfClass:[NSOpenGLView class]]) return NO;
    else return YES;
  }
  if (action==@selector(showConfigurationSheet:)) {
    return [screenSaverView hasConfigureSheet];
  }
  if (action==@selector(moveToFrontLayer:)) {
    [self setMenuItem:menuItem isChecked:([window level]>NSNormalWindowLevel)];
  }
  if (action==@selector(moveToStandardLayer:)) {
    [self setMenuItem:menuItem isChecked:([window level]==NSNormalWindowLevel)];
  }
  if (action==@selector(moveToBackLayer:)) {
    [self setMenuItem:menuItem isChecked:([window level]<NSNormalWindowLevel)];
  }
  if (action==@selector(makeSize160:)) {
    [self checkMenuItem:menuItem ifContentViewHasWidth:160 height:120];
  }
  if (action==@selector(makeSize320:)) {
    [self checkMenuItem:menuItem ifContentViewHasWidth:320 height:240];
  }
  if (action==@selector(makeSize480:)) {
    [self checkMenuItem:menuItem ifContentViewHasWidth:480 height:360];
  }
  if (action==@selector(makeSize640:)) {
    [self checkMenuItem:menuItem ifContentViewHasWidth:640 height:480];
  }
  if (action==@selector(makeSize800:)) {
    [self checkMenuItem:menuItem ifContentViewHasWidth:800 height:600];
  }
  return YES;
}

-(void)checkMenuItem:(id <NSMenuItem>)menuItem ifContentViewHasWidth:(int)w height:(int)h {
  // always uncheck if full screen
  BOOL checked = ![self isFullScreen] && NSEqualSizes([[window contentView] frame].size,NSMakeSize(w,h));
  [self setMenuItem:menuItem isChecked:checked];
}

-(void)setMenuItem:(id <NSMenuItem>)menuItem isChecked:(BOOL)checked {
  if (checked) {
    [checkedMenuItems addObject:menuItem];
    [menuItem setState:NSOnState];
  }
  else {
    [checkedMenuItems removeObject:menuItem];
    [menuItem setState:NSOffState];
  }
}

//// configuration sheet methods

-(void)showConfigurationSheet:(id)sender {
  [NSApp beginSheet:[screenSaverView configureSheet]
     modalForWindow:window 
      modalDelegate:self
     didEndSelector:@selector(configureSheetEnded:returnCode:contextInfo:)
        contextInfo:nil];
}

-(void)configureSheetEnded:(NSWindow *)sheet returnCode:(int)code contextInfo:(void *)info {
  // needed to make the sheet go away
  [sheet orderOut:nil];
  // the saver module should restart itself if needed
}

//// window delegate methods
-(void)windowDidResize:(NSNotification *)note {
  // restart when the window is resized
  isPaused = NO;
  [self restart:nil];
}

-(void)windowDidBecomeMain:(NSNotification *)note {
  // give keypresses to the ScreenSaverView
  [window makeFirstResponder:screenSaverView];
}

-(void)windowDidResignMain:(NSNotification *)note {
  // remove all checkboxes that this window set
  NSEnumerator *itemEnum = [checkedMenuItems objectEnumerator];
  NSMenuItem *menuItem;
  while (menuItem = [itemEnum nextObject]) {
    [menuItem setState:NSOffState];
  }
  [checkedMenuItems removeAllObjects];
}

//// notification methods
// stop animations when app is hidden, restart when unhidden if it was previously running
-(void)appHidden:(NSNotification *)note {
  isAppHidden = YES;
  [self stop];
}

-(void)appUnhidden:(NSNotification *)note {
  isAppHidden = NO;
  [self startIfPossible];
}

// stop when real screensaver kicks in
-(void)screenSaverActivated:(NSNotification *)note {
  isScreenSaverRunning = YES;
  [self stop];
}

-(void)screenSaverDeactivated:(NSNotification *)note {
  isScreenSaverRunning = NO;
  [self startIfPossible];
}

/* free ourselves when the window closes
*/
-(void)windowWillClose:(NSNotification *)note {
  if ([screenSaverView isAnimating]) [self stop];
  [self autorelease];
}

@end
