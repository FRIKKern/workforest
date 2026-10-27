#import <Foundation/Foundation.h>

/// rules.json: where to look for worktrees, which ones are never removed, and which folders are caches.
/// Written with defaults on first run; new defaults merge in on upgrade and never remove an entry of yours.
@interface WFRules : NSObject
+ (instancetype)shared;
@property (readonly) NSURL *fileURL;
- (void)reload;
/// Folders scanned for repos, expanded. $WORKFOREST_ROOTS (colon separated) replaces them, for tests.
@property (readonly) NSArray<NSString *> *roots;
@property (readonly) NSInteger depth;              // how many folder levels below a root to look for repos
/// Never removed: a path under a protected folder, or a branch with a protected name such as main.
- (BOOL)protectsPath:(NSString *)path branch:(NSString *)branch;
- (BOOL)ignoresPath:(NSString *)path;
- (void)setProtected:(BOOL)on path:(NSString *)path;
/// Folder names that hold rebuildable files: node_modules, .next, build output. Their size is reclaimable,
/// their changes are not work, and they are not saved before a removal.
@property (readonly) NSSet<NSString *> *caches;
@end
