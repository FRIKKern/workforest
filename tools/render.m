// Renders the WorkForest menu and the hover card of five made-up worktrees offscreen to PNG, light and dark.
// Nothing is scanned: the worktrees and the review are built here. Run tools/render.sh, see docs/RENDER.md.
#import <Cocoa/Cocoa.h>
#import "Trees.h"
#import "Review.h"
#import "Forest.h"

@interface WorkForest : NSObject
@property (strong) WFScanner *scanner;
@property (strong) WFReview *review;
- (NSMenu *)buildMenu;
- (NSMenuItem *)cardFor:(WFTree *)t;
@end

static WFTree *Tree(NSString *repo, NSString *name, NSString *branch, double quietDays, uint64_t mb, uint64_t cacheMb) {
    WFTree *t = [WFTree new];
    t.repo = [@"/Users/dev/code" stringByAppendingPathComponent:repo];
    t.path = [[@"/Users/dev/code" stringByAppendingPathComponent:[repo stringByAppendingString:@".worktrees"]] stringByAppendingPathComponent:name];
    t.branch = branch; t.head = @"abc123"; t.defaultBranch = @"origin/main"; t.upstream = [@"origin/" stringByAppendingString:branch];
    t.lastCommit = [NSDate dateWithTimeIntervalSinceNow:-quietDays * 86400]; t.touched = t.lastCommit; t.created = [NSDate dateWithTimeIntervalSinceNow:-(quietDays + 2) * 86400];
    t.lastAuthor = @"Dev"; t.diskBytes = mb << 20; t.cacheBytes = cacheMb << 20; t.files = 12000; t.sizedAt = NSDate.date; t.factsRead = YES;
    t.processes = @[]; t.servers = @[];
    return t;
}

static void Render(NSView *v, NSString *path, NSAppearance *ap, CGFloat width) {
    NSSize size = NSMakeSize(MAX(width, v.frame.size.width), v.frame.size.height);
    NSBox *bg = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    bg.boxType = NSBoxCustom; bg.borderWidth = 0; bg.fillColor = NSColor.windowBackgroundColor; bg.contentViewMargins = NSZeroSize;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:bg.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.appearance = ap; w.contentView = bg;
    [bg.contentView addSubview:v];
    [w layoutIfNeeded]; [bg layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [bg bitmapImageRepForCachingDisplayInRect:bg.bounds];
    [ap performAsCurrentDrawingAppearance:^{ [bg cacheDisplayInRect:bg.bounds toBitmapImageRep:rep]; }];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

@interface Flipped : NSView @end
@implementation Flipped - (BOOL)isFlipped { return YES; } @end

/// The items of a menu laid out top to bottom with frames, as a menu does: custom views at their own size,
/// separators as thin lines, plain items as title, subtitle and badge.
static NSView *Stack(NSArray<NSMenuItem *> *items) {
    Flipped *c = [[Flipped alloc] initWithFrame:NSMakeRect(0, 0, 400, 10)];
    CGFloat y = 4, w = 0;
    for (NSMenuItem *i in items) {
        NSView *v = nil; CGFloat h = 0;
        if (i.view) {
            BOOL stack = [i.view isKindOfClass:NSStackView.class];   // the card lays itself out; header and text views use frames
            if (stack) [i.view layoutSubtreeIfNeeded];
            NSSize fit = stack ? i.view.fittingSize : NSZeroSize;
            h = MAX(i.view.frame.size.height, fit.height); CGFloat vw = MAX(i.view.frame.size.width, fit.width);
            NSView *holder = [[NSView alloc] initWithFrame:NSMakeRect(0, y, vw, h)];
            i.view.translatesAutoresizingMaskIntoConstraints = YES; i.view.frame = NSMakeRect(0, 0, vw, h);
            [holder addSubview:i.view]; v = holder; w = MAX(w, vw);
        } else if (i.isSeparatorItem) {
            NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(10, y + 4, 330, 1)]; line.boxType = NSBoxSeparator; v = line; h = 9;
            v.frame = NSMakeRect(10, y + 4, 330, 1);
        } else {
            NSString *sub = nil, *badge = nil;
            if (@available(macOS 14.4, *)) { sub = i.subtitle; badge = i.badge.stringValue; }
            NSTextField *t = [NSTextField labelWithString:@""];
            t.attributedStringValue = i.attributedTitle ?: [[NSAttributedString alloc] initWithString:i.title attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:0]}];
            if (!i.enabled) t.textColor = NSColor.tertiaryLabelColor;
            if (i.submenu) t.stringValue = [t.stringValue stringByAppendingString:@"   ›"];
            [t sizeToFit]; t.frame = NSMakeRect(22, y + 3, t.frame.size.width, t.frame.size.height);
            [c addSubview:t]; h = t.frame.size.height + 6; w = MAX(w, NSMaxX(t.frame) + 14);
            if (badge.length) {
                NSTextField *b = [NSTextField labelWithString:badge]; b.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
                b.textColor = NSColor.secondaryLabelColor; [b sizeToFit]; b.frame = NSMakeRect(340 - b.frame.size.width, y + 4, b.frame.size.width, b.frame.size.height); [c addSubview:b];
            }
            if (sub.length) {
                NSTextField *st = [NSTextField labelWithString:sub]; st.font = [NSFont systemFontOfSize:11]; st.textColor = NSColor.secondaryLabelColor;
                [st sizeToFit]; st.frame = NSMakeRect(22, y + h - 3, st.frame.size.width, st.frame.size.height); [c addSubview:st];
                h += st.frame.size.height; w = MAX(w, NSMaxX(st.frame) + 14);
            }
            y += h; continue;
        }
        [c addSubview:v]; y += h;
    }
    c.frame = NSMakeRect(0, 0, MAX(w, 340), y + 4);
    return c;
}

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *out = @(argv[1]);
    WFTree *checkout = Tree(@"acme-web", @"acme-web-checkout-flow", @"feat/checkout-flow", 6, 4900, 3900);
    checkout.merged = @"squash"; checkout.upstream = @"gone"; checkout.notInDefault = 4; checkout.lastSubject = @"Checkout: keep the cart when the address form fails";
    WFTree *search = Tree(@"acme-web", @"acme-web-search-facets", @"feat/search-facets", 0.1, 820, 610);
    search.dirty = 3; search.notInDefault = 2; search.unpushed = 2; search.lastSubject = @"Search: facet counts per category";
    search.session = @{@"agent": @"Claude Code", @"title": @"Add facet filters to search", @"match": @"a session ran in this folder", @"last_active_minutes_ago": @120};
    WFTree *limits = Tree(@"orbit-api", @"orbit-api-rate-limits", @"wip/rate-limits", 9, 310, 240);
    limits.notInDefault = 5; limits.lastSubject = @"WIP: token bucket per API key, parked until the pricing call";
    WFTree *hooks = Tree(@"orbit-api", @"orbit-api-billing-webhooks", @"fix/billing-webhooks", 1.5, 1300, 1100);
    hooks.notInDefault = 1; hooks.lastSubject = @"Billing: retry webhooks with backoff";
    hooks.processes = @[@"node (pid 4120)", @"zsh (pid 4002)"]; hooks.servers = @[@{@"port": @3000, @"framework": @"Vite", @"state": @"recent"}];
    WFTree *docs = Tree(@"acme-web", @"acme-web-docs-refresh", @"docs/refresh", 13, 540, 470);
    docs.merged = @"ancestor"; docs.lastSubject = @"Docs: new install guide";
    NSArray *trees = @[checkout, search, limits, hooks, docs];
    WFTree *main = Tree(@"acme-web", @"acme-web", @"main", 0.2, 900, 700); main.isMain = YES; main.path = main.repo;
    WFTree *main2 = Tree(@"orbit-api", @"orbit-api", @"main", 0.5, 400, 300); main2.isMain = YES; main2.path = main2.repo;

    WFReview *r = [WFReview new];
    r.at = [NSDate dateWithTimeIntervalSinceNow:-9 * 60]; r.model = @"haiku"; r.tokens = 18400; r.seconds = 31; r.treeCount = trees.count; r.trigger = @"new worktree acme-web/search-facets";
    r.summary = @"5 worktrees in 2 repos hold 7.9 GB, 6.3 GB of it caches such as node_modules. The checkout flow branch is squash-merged and its remote branch is gone, and the docs refresh is merged and quiet for two weeks. I would remove both; the rate limits branch is parked on purpose.";
    WFVerdict *(^V)(NSString *, double, NSString *, NSString *, NSString *, BOOL) = ^WFVerdict *(NSString *verdict, double c, NSString *about, NSString *reason, NSString *evidence, BOOL judged) {
        WFVerdict *v = [WFVerdict new]; v.verdict = verdict; v.confidence = c; v.about = about; v.reason = reason; v.keepEvidence = evidence; v.judged = judged; return v; };
    r.verdicts = @{checkout.path: V(@"stale", 0.92, @"Checkout flow fix for acme-web, squash-merged 6 days ago", @"Squash-merged into origin/main, remote branch deleted, and untouched for 6 days.", @"", NO),
                   search.path: V(@"active", 0.9, @"Search facets for acme-web, in progress", @"Three uncommitted changes and a Claude Code session two hours ago.", @"3 uncommitted changes and a session 2 hours ago", NO),
                   limits.path: V(@"active", 0.75, @"Rate limits per API key for orbit-api, parked", @"Not merged, committed 9 days ago, and the branch name says the work is parked on purpose.", @"the branch is wip and the last commit says it is parked until the pricing call", YES),
                   hooks.path: V(@"active", 0.85, @"Webhook retries for orbit-api, running", @"A Vite server and a node process run inside it.", @"a server runs inside", NO),
                   docs.path: V(@"stale", 0.88, @"Docs refresh for acme-web, merged two weeks ago", @"Merged into origin/main and quiet for 13 days.", @"", NO)};
    WorkForest *app = [WorkForest new];
    app.scanner = [WFScanner new];
    [app.scanner setValue:[trees arrayByAddingObjectsFromArray:@[main, main2]] forKey:@"trees"];
    [app.scanner setValue:NSDate.date forKey:@"scannedAt"];
    app.review = r;
    NSMenu *menu = [app buildMenu];
    NSMutableArray *top = [NSMutableArray new];
    for (NSMenuItem *i in menu.itemArray) { [top addObject:i]; if ([i.title isEqualToString:@"Quit WorkForest"]) break; }
    for (NSString *mode in @[@"light", @"dark"]) {
        NSAppearance *ap = [NSAppearance appearanceNamed:[mode isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        Render(Stack(top), [out stringByAppendingFormat:@"/menu-%@.png", mode], ap, 380);
        NSArray *names = @[@"checkout", @"search", @"limits", @"hooks", @"docs"];
        for (NSUInteger k = 0; k < trees.count; k++) {
            // the card as the submenu shows it, with the actions under it
            NSMenuItem *row = nil;
            for (NSMenuItem *i in menu.itemArray) if (i.submenu && [i.submenu.itemArray.firstObject.view isKindOfClass:NSStackView.class] && [app.scanner treeAt:[trees[k] path]] && [[i.submenu.itemArray[2] representedObject] isEqual:[trees[k] path]]) row = i;
            NSArray *items = row ? row.submenu.itemArray : @[[app cardFor:trees[k]]];
            Render(Stack(items), [out stringByAppendingFormat:@"/card-%@-%@.png", names[k], mode], ap, 380);
        }
    }
    printf("rendered to %s\n", out.UTF8String);
    return 0;
}}
