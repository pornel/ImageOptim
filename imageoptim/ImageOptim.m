#import "ImageOptim.h"
#import "FilesQueue.h"
#import "RevealButtonCell.h"
#import "File.h"
#import "Workers/Worker.h"
#import "PrefsController.h"
#include <mach/mach_host.h>
#include <mach/host_info.h>
#import <Quartz/Quartz.h>
#import "Utilities.h"

@implementation ImageOptim

NSDictionary *statusImages;

@synthesize selectedIndexes,filesQueue;

- (void)setSelectedIndexes:(NSIndexSet *)indexSet
{
	//Get information from ArrayController
    if (indexSet != selectedIndexes) {
		selectedIndexes = [indexSet copy];
		[previewPanel reloadData];
	}
}

+ (void)migrateOldPreferences
{
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

    BOOL migrated = [userDefaults boolForKey:@"PrefsMigrated"];
    if (!migrated) {
        NSString *const oldKeys[] = {
            @"AdvPng.Bundle", @"AdvPng.Enabled", @"AdvPng.Level", @"AdvPng.Path", @"Gifsicle.Bundle", @"Gifsicle.Enabled", @"Gifsicle.Path",
            @"JpegOptim.Bundle", @"JpegOptim.Enabled", @"JpegOptim.MaxQuality", @"JpegOptim.Path", @"JpegOptim.StripComments", @"JpegOptim.StripExif",
            @"JpegTran.Bundle", @"JpegTran.Enabled", @"JpegTran.Path", @"OptiPng.Bundle", @"OptiPng.Enabled", @"OptiPng.Level", @"OptiPng.Path",
            @"PngCrush.Bundle", @"PngCrush.Chunks", @"PngCrush.Enabled", @"PngCrush.Path", @"PngOut.Bundle", @"PngOut.Enabled",
            @"PngOut.InterruptIfTakesTooLong", @"PngOut.Level", @"PngOut.Path", @"PngOut.RemoveChunks",
        };

        for(int i=0; i < sizeof(oldKeys)/sizeof(oldKeys[0]); i++) {
            id oldValue = [userDefaults objectForKey:oldKeys[i]];
            if (oldValue) {
                NSString *newKey = [oldKeys[i] stringByReplacingOccurrencesOfString:@"." withString:@""];
                id newValue = [userDefaults objectForKey:newKey];
                if (![oldValue isEqual:newValue]) {
                    [userDefaults setObject:oldValue forKey:newKey];
                } else {
                    [userDefaults removeObjectForKey:oldKeys[i]]; // FIXME: remove unconditionally after a while
                }
            }
        }
        [userDefaults setBool:YES forKey:@"PrefsMigrated"];
    }
}

+(void)initialize
{
	NSMutableDictionary *defs = [NSMutableDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"defaults" ofType:@"plist"]];

	int maxTasks = [self numberOfCPUs]+1;
	if (maxTasks > 8) maxTasks++;
    
    // get the singleton instantiated
    Utilities *tmp __attribute__((unused)) = [Utilities utilitiesSharedSingleton];

	[defs setObject:[NSNumber numberWithInt:maxTasks] forKey:@"RunConcurrentTasks"];
	[defs setObject:[NSNumber numberWithInt:(int)ceil((double)maxTasks/3.9)] forKey:@"RunConcurrentDirscans"];

	[[NSUserDefaults standardUserDefaults] registerDefaults:defs];

    [self migrateOldPreferences];
}

NSString *formatSize(long long byteSize, NSNumberFormatter *formatter)
{
    NSString *unit;
    double size;

    if (byteSize > 1000*1000LL) {
        size = (double)byteSize / (1000.0*1000.0);
        unit = NSLocalizedString(@"MB", "megabytes suffix");
    } else {
        size = (double)byteSize / 1000.0;
        unit = NSLocalizedString(@"KB", "kilobytes suffix");
    }

    return [[formatter stringFromNumber:[NSNumber numberWithDouble:size]] stringByAppendingString:unit];
};


-(void)initStatusbar
{
    [[statusBarLabel cell] setBackgroundStyle:NSBackgroundStyleRaised];

    static BOOL overallAvg = NO;
    static NSString *defaultText; defaultText = statusBarLabel.stringValue;
    static NSNumberFormatter* formatter; formatter = [NSNumberFormatter new];
    static NSNumberFormatter* percFormatter; percFormatter = [NSNumberFormatter new];

    [formatter setMaximumFractionDigits:1];
    [percFormatter setMaximumFractionDigits:1];
    [formatter setNumberStyle: NSNumberFormatterDecimalStyle];
    [percFormatter setNumberStyle: NSNumberFormatterPercentStyle];

    statusBarUpdateQueue = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(statusBarUpdateQueue, ^{
        NSString *str = defaultText;
        if ([filesController.arrangedObjects count] > 1) {
            NSNumber *bytes = [filesController valueForKeyPath:@"arrangedObjects.@sum.byteSize"],
                 *optimized = [filesController valueForKeyPath:@"arrangedObjects.@sum.byteSizeOptimized"];

            if ([bytes longLongValue] != [optimized longLongValue]) {
                long long bytesL = [bytes longLongValue], bytesSaved = bytesL - [optimized longLongValue];
                double savedAvg = [[filesController valueForKeyPath:@"arrangedObjects.@avg.percentOptimized"] doubleValue];
                double savedTotal = 100.0*(1.0-[optimized doubleValue]/[bytes doubleValue]);

                NSString *fmtStr; NSNumber *avgNum;
                if (savedTotal*0.9 > savedAvg) {
                    overallAvg = YES;
                } else if (savedAvg*0.9 > savedTotal){
                    overallAvg = NO;
                }

                if (overallAvg) {
                    fmtStr = NSLocalizedString(@"Saved %@ out of %@. %@ overall (up to %@ per file)","total ratio");
                    avgNum = [NSNumber numberWithDouble:savedTotal/100.0];
                } else {
                    fmtStr = NSLocalizedString(@"Saved %@ out of %@. %@ per file on average (up to %@)","per file avg");
                    avgNum = [NSNumber numberWithDouble:savedAvg/100.0];
                }

                double max = [[filesController valueForKeyPath:@"arrangedObjects.@max.percentOptimized"] doubleValue];

                str = [NSString stringWithFormat:fmtStr,
                         formatSize(bytesSaved, formatter),
                         formatSize(bytesL, formatter),
                         [percFormatter stringFromNumber: avgNum],
                         [percFormatter stringFromNumber: [NSNumber numberWithDouble:max/100.0]]];
            }
        }
        [statusBarLabel setStringValue:str];
    });
    dispatch_resume(statusBarUpdateQueue);

    [filesController addObserver:self forKeyPath:@"arrangedObjects.@count" options:NSKeyValueObservingOptionNew context:nil];
    [filesController addObserver:self forKeyPath:@"arrangedObjects.@avg.percentOptimized" options:NSKeyValueObservingOptionNew context:nil];
    [filesController addObserver:self forKeyPath:@"arrangedObjects.@sum.byteSizeOptimized" options:NSKeyValueObservingOptionNew context:nil];
}

-(void)awakeFromNib
{
	filesQueue = [[FilesQueue alloc] initWithTableView:tableView progressBar:progressBar andController:filesController];

	RevealButtonCell* cell=[[tableView tableColumnWithIdentifier:@"filename"]dataCell];
	[cell setInfoButtonAction:@selector(openInFinder)];
	[cell setTarget:tableView];

    [credits setString:@""];

    // this creates and sets the text for textview
    [self generateCreditsHTML];

    [self initStatusbar];
    [self preloadStatusImages];
}


-(void)generateCreditsHTML{
    
    NSMutableString *html = [[NSMutableString alloc] initWithCapacity:2000];
    
    [html appendString:@"<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">"];
    [html appendString:@"<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"><meta http-equiv=\"Content-Style-Type\" content=\"text/css\">"];
    [html appendString:@"<style type=\"text/css\">p.p1{margin:.0px .0px 12.0px 10.0px;font:11.0px 'Lucida Grande'}p.p3{margin:.0px .0px .0px 10.0px;font:11.0px 'Lucida Grande';min-height:13.0px}li.li2{margin:.0px .0px .0px .0px;font:11.0px 'Lucida Grande'; color: #000000}span.s1{text-decoration:underline;color:#0431f3}span.s2{text-decoration:underline;color:#0432f5}ul.ul1{list-style-type:disc}</style>"];
    [html appendString:@"</head><body>"];
    [html appendString:@"<p class=\"p1\"><span class=\"s1\"><a href=\"http://pornel.net/imageoptim/en\">ImageOptim</a></span> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Kornel Lesiński "];
    [html appendString:NSLocalizedString(@"and contributors is a GUI for 3rd party utilities:", nil)];
    [html appendString:@"</p><ul class=\"ul1\">"];
    [html appendString:@"<li class=\"li2\"><a href=\"http://optipng.sourceforge.net/\"><span class=\"s1\">OptiPNG</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Cosmin Truta,</li>"];
    [html appendString:@"<li class=\"li2\"><a href=\"http://pmt.sourceforge.net/pngcrush/\"><span class=\"s1\">PNGCrush</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Glenn Randers-Pehrson,</li>"];
    [html appendString:@" <li class=\"li2\"><a href=\"http://advancemame.sourceforge.net/doc-advpng.html\"><span class=\"s1\">AdvPNG</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Andrea Mazzoleni, Filipe Estima,</li>"];
    [html appendString:@"<li class=\"li2\"><a href=\"http://www.kokkonen.net/tjko/projects.html\"><span class=\"s1\">Jpegoptim</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Timo Kokkonen,</li>"];
    [html appendString:@"<li class=\"li2\"><a href=\"http://www.lcdf.org/gifsicle/\"><span class=\"s1\">Gifsicle</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Eddie Kohler,</li>"];
    [html appendString:@"<li class=\"li2\">"];
    [html appendString:NSLocalizedString(@"and", nil)];
    [html appendString:@" <a href=\"http://www.advsys.net/ken/utils.htm\"><span class=\"s1\">PNGOUT</span></a> "];
    [html appendString:NSLocalizedString(@"by", nil)];
    [html appendString:@" Ken Silverman.</li>"];
    [html appendString:@"</ul><p class=\"p3\"><br></p><p class=\"p1\">"];
    [html appendString:NSLocalizedString(@"ImageOptim can be redistributed and modified under", nil)];
    [html appendString:@" <a href=\"http://www.gnu.org/licenses/old-licenses/gpl-2.0.html\"><span class=\"s2\">"];
    [html appendString:NSLocalizedString(@"GNU General Public License version 2 or later", nil)];
    [html appendString:@"</span></a>. "];
    [html appendString:NSLocalizedString(@"Bundled PNGOUT is not covered by the GPL and is included with permission of Ardfry Imaging, LLC.", nil)];
    [html appendString:@"</p></body></html>"];
    
    [credits setEditable:YES];
    
    NSAttributedString *tmpStr = [[NSAttributedString alloc]
                                  initWithHTML:[html dataUsingEncoding:NSUTF8StringEncoding]
                                  documentAttributes:nil];
    
    [credits insertText:tmpStr];
    [credits setEditable:NO];
    
    // not sure if this is needed? release and sets to nil.
    // I don't see any other memory man anywhere
    IOWISafeRelease(html);
    IOWISafeRelease(tmpStr);
    
}

-(void)preloadStatusImages {
    statusImages = [NSDictionary dictionaryWithObjectsAndKeys:
                   [NSImage imageNamed:@"err"], @"err",
                   [NSImage imageNamed:@"wait"], @"wait",
                   [NSImage imageNamed:@"progress"], @"progress",
                   [NSImage imageNamed:@"noopt"], @"noopt",
                   [NSImage imageNamed:@"ok"], @"ok",
                   nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    // Defer and coalesce statusbar updates
    dispatch_source_merge_data(statusBarUpdateQueue, 1);
}

+(int)numberOfCPUs
{
	host_basic_info_data_t hostInfo;
	mach_msg_type_number_t infoCount;
	infoCount = HOST_BASIC_INFO_COUNT;
	host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&hostInfo, &infoCount);
	return MIN(32,MAX(1,(hostInfo.max_cpus)));
}

// invoked by Dock
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)path
{
    [filesQueue setRow:-1];
    [filesQueue addPath:path];
	[filesQueue runAdded];
	return YES;
}


-(IBAction)quickLookAction:(id)sender
{
	[filesQueue performSelector:@selector(quickLook)];
}

- (IBAction)startAgain:(id)sender
{
    // alt-click on a button (this is used from menu too, but alternative menu item covers that anyway
    BOOL onlyOptimized = !!([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask);
	[filesQueue startAgainOptimized:onlyOptimized];
}

- (IBAction)startAgainOptimized:(id)sender
{
    [filesQueue startAgainOptimized:YES];
}


- (IBAction)clearComplete:(id)sender
{
	[filesQueue clearComplete];
}


- (IBAction)showPrefs:(id)sender
{
	if (!prefsController) {
		prefsController = [PrefsController new];
	}
	[prefsController showWindow:self];
}

-(IBAction)openHomepage:(id)sender
{
    [self openURL:@"http://imageoptim.com"];
}

-(IBAction)viewSource:(id)sender
{
	[self openURL:@"http://imageoptim.com/source"];
}

-(void)openURL:(NSString *)stringURL
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:stringURL]];
}


-(IBAction)browseForFiles:(id)sender
{
    NSOpenPanel *oPanel = [NSOpenPanel openPanel];

    [oPanel setAllowsMultipleSelection:YES];
	[oPanel setCanChooseDirectories:YES];
	[oPanel setResolvesAliases:YES];
    [oPanel setAllowedFileTypes:[filesQueue fileTypes]];

    [oPanel beginSheetModalForWindow:[tableView window] completionHandler:^(NSInteger returnCode) {
	if (returnCode == NSOKButton) {
		NSWindow *myWindow=[tableView window];
		[myWindow setStyleMask:[myWindow styleMask]| NSResizableWindowMask ];
		[filesQueue setRow:-1];
        [filesQueue addPaths:[oPanel filenames]];
    }
    }];
}

- (void)windowWillClose:(NSNotification *)aNotification
{
    // let the window close immediately, clean in background
    [NSApp performSelectorOnMainThread:@selector(terminate:) withObject:self waitUntilDone:NO];
}

-(void)applicationWillTerminate:(NSNotification*)n {
    [filesQueue cleanup];
}

-(NSString*)version {
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
}

// Quick Look panel support
- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel;
{
    return YES;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel
{
    // This document is now responsible of the preview panel
    // It is allowed to set the delegate, data source and refresh panel.
    previewPanel = panel;
    panel.delegate = self;
    panel.dataSource = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel
{
    // This document loses its responsisibility on the preview panel
    // Until the next call to -beginPreviewPanelControl: it must not
    // change the panel's delegate, data source or refresh it.
    previewPanel = nil;
}

// Quick Look panel data source
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel
{
    return [[filesController selectedObjects] count];
}

- (id <QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index
{
    return [NSURL fileURLWithPath:[[[filesController selectedObjects] objectAtIndex:index]filePath] ];
}

// Quick Look panel delegate
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event
{
    // redirect all key down events to the table view
    if ([event type] == NSKeyDown) {
        [tableView keyDown:event];
        return YES;
    }
    return NO;
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    SEL action = [menuItem action];
	if (action == @selector(startAgain:)) {
		return [filesQueue canStartAgainOptimized:NO];
    } else if (action == @selector(startAgainOptimized:)) {
		return [filesQueue canStartAgainOptimized:YES];
    } else if (action == @selector(clearComplete:)) {
        return [filesQueue canClearComplete];
    }

	return [menuItem isEnabled];
}

// This delegate method provides the rect on screen from which the panel will zoom.
- (NSRect)previewPanel:(QLPreviewPanel *)panel sourceFrameOnScreenForPreviewItem:(id <QLPreviewItem>)item
{
    NSInteger index = [[filesController arrangedObjects] indexOfObject:item];
    if (index == NSNotFound) {
        return NSZeroRect;
    }

    NSRect iconRect = [tableView frameOfCellAtColumn:0 row:index];

    // check that the icon rect is visible on screen
    NSRect visibleRect = [tableView visibleRect];

    if (!NSIntersectsRect(visibleRect, iconRect)) {
        return NSZeroRect;
    }

    // convert icon rect to screen coordinates
    iconRect = [tableView convertRectToBase:iconRect];
    iconRect.origin = [[tableView window] convertBaseToScreen:iconRect.origin];

    return iconRect;
}

// This delegate method provides a transition image between the table view and the preview panel
- (id)previewPanel:(QLPreviewPanel *)panel transitionImageForPreviewItem:(id <QLPreviewItem>)item contentRect:(NSRect *)contentRect
{
	return [[NSWorkspace sharedWorkspace] iconForFile:[(NSURL *)item path]];
}


@end
