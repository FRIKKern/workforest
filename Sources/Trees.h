#import <Foundation/Foundation.h>

/// One git worktree: a main checkout or a linked worktree, with what LocoHost-style scanning finds out about it.
@interface WFTree : NSObject
@property (copy) NSString *path;                 // the worktree folder, the key
@property (copy) NSString *repo;                 // the main worktree's folder
@property (copy) NSString *commonDir;            // the shared .git folder
@property (copy) NSString *branch;               // nil when detached
@property (copy) NSString *head;                 // commit SHA
@property BOOL isMain, locked, prunable, detached;
@property (copy) NSString *lockReason;
@property (readonly) NSString *name;             // folder name
@property (readonly) NSString *repoName;         // main worktree's folder name

// Git, from facts
@property (strong) NSDate *lastCommit;
@property (copy) NSString *lastSubject, *lastAuthor;
@property NSInteger dirty, untracked;            // tracked files changed; untracked entries outside .gitignore
@property NSInteger stashes;                     // stash entries made on this branch
@property NSInteger unpushed;                    // commits on no remote and not in the default branch
@property NSInteger orphanCommits;               // detached: commits no branch or remote holds
@property NSInteger notInDefault;                // commits the default branch does not have
@property (copy) NSString *merged;               // ancestor | tree | patch | squash | pr, nil when not merged
@property (copy) NSString *pr;                   // "#123 merged 3d ago" from gh, when asked for
@property (copy) NSString *upstream;             // origin/x, "gone" when the remote branch was deleted, "none" when never pushed
@property NSInteger ahead, behind;
@property (copy) NSString *defaultBranch;
@property (strong) NSDate *fetched;              // when the repo last fetched: FETCH_HEAD's time
@property (strong) NSDate *created;              // when the worktree folder was made
@property BOOL factsRead;

// Disk, from a walk of the folder
@property uint64_t diskBytes, cacheBytes;        // allocated size; the part in cache folders such as node_modules
@property NSInteger files;
@property (strong) NSDate *touched;              // newest file outside .git and caches
@property (strong) NSDate *sizedAt;              // nil until walked

// Activity
@property (strong) NSArray<NSString *> *processes;   // "zsh (pid 123)" with a working directory inside
@property (strong) NSArray<NSDictionary *> *servers; // LocoHost localhosts running inside: port, framework, state
@property (strong) NSDictionary *session;            // agent, title, first_prompt, last_active_minutes_ago, match
@property BOOL isProtected;

@property (readonly) NSDate *lastWork;           // the latest of the last commit, the newest file and the last agent session activity
@property (readonly) NSTimeInterval quiet;       // seconds since lastWork
- (NSDictionary *)json;
@end

/// Finds every worktree under the scan roots and reads its facts. Git runs read-only with GIT_OPTIONAL_LOCKS=0.
@interface WFScanner : NSObject
/// wait YES reads everything now (the CLI). wait NO returns at once, reads in the background and calls done on the main queue.
- (void)scan:(BOOL)wait done:(void (^)(void))done;
@property (readonly) NSArray<WFTree *> *trees;   // linked worktrees first by repo, main worktrees included
@property (readonly) NSDate *scannedAt;
@property (readonly) BOOL scanning;
/// Fresh facts for one worktree, including a new disk walk, sessions and processes. Used right before removing it.
+ (WFTree *)fresh:(NSString *)path;
/// The worktree at or containing this path, from a scan.
- (WFTree *)treeAt:(NSString *)path;
@end
