#import <Foundation/Foundation.h>
#import "Trees.h"
#import "Review.h"

/// The decisions: what every mode keeps, what each mode removes, and the removal and restore themselves.
/// Shared by the menu bar app and the CLI.

typedef NS_ENUM(NSInteger, WFMode) { WFModeIdle = 0, WFModeProactive = 1, WFModeEager = 2 };
NSArray<NSString *> *WFModeNames(void);          // idle, proactive, eager
NSString *WFModeLabel(WFMode m);
NSInteger WFModeFrom(NSString *s);               // -1 when unknown
WFMode WFCurrentMode(void);                      // the setting, Eager by default
void WFSetMode(WFMode m);
id WFPref(NSString *key);
void WFSetPref(NSString *key, id value);
BOOL WFPrefBool(NSString *key, BOOL dflt);
NSInteger WFPrefInt(NSString *key, NSInteger dflt);
NSString *WFModel(void);                         // the model setting, "auto" by default

/// Why a worktree stays whatever the mode, or nil when the mode may decide.
/// Work reasons first: main checkout, missing folder, protected, locked, uncommitted or untracked files, commits only here,
/// a process or server inside, an agent session or a file change in the last day, made in the last day.
/// Then review reasons when r is given: no recent review, the review failed, work after the review, not in the review.
NSString *WFMustKeep(WFTree *t, WFReview *r);
/// The work reasons only. Removal checks these on fresh facts right before it acts, whatever asked for it.
NSString *WFWorkKeeps(WFTree *t);

/// For every linked worktree: remove or keep under this mode, and the one-line reason. Idle removes nothing.
/// Each entry: tree, remove (BOOL), why.
NSArray<NSDictionary *> *WFPlan(NSArray<WFTree *> *trees, WFReview *r, WFMode mode);
/// The worktrees Eager's judge looks at: free to decide and not already clearly stale.
NSArray<WFTree *> *WFJudgeSubjects(NSArray<WFTree *> *trees, WFReview *r);
/// What Clean Up in the menu and `workforest clean-up` remove: free to decide, and the review calls it stale with confidence.
NSArray<WFTree *> *WFCandidates(NSArray<WFTree *> *trees, WFReview *r);
/// A review, then in Eager mode the judge. Blocks.
WFReview *WFRunReview(NSArray<WFTree *> *trees, NSString *model, WFMode mode, NSString *trigger);
/// True once WorkForest has watched long enough for a mode to act: a day after the app first ran, by default.
BOOL WFGraceOver(void);
/// Starts the grace period, once: the app's launch and a real `workforest auto` call it.
void WFStartWatching(void);
NSString *WFGraceWords(void);
NSTimeInterval WFGraceLeft(void);                // seconds until modes may act, 0 once they may

/// Keep: the user's word that a worktree stays for a while, a week from the menu. Every mode and Clean Up respect it.
NSDate *WFKeptUntil(NSString *path);             // nil when not kept, or the keep has passed
void WFSetKept(NSString *path, NSDate *until);   // nil ends the keep

/// Removes one worktree: fresh facts, the work checks again, ignored files that are not caches saved, `git worktree remove`
/// without --force, and `git branch -d` when the branch is merged. Returns the removed.json record, or nil with *error.
NSDictionary *WFRemove(NSString *path, NSString *by, NSString *why, NSString **error);
/// Recreates a removed worktree at its commit and puts the saved files back. Returns nil on success, else the problem.
NSString *WFRestore(NSString *idOrPath);
NSArray<NSDictionary *> *WFRemoved(void);         // newest first
void WFClearRemoved(void);
/// Carries out the mode's plan. Returns what was done, for review.json and the notification.
NSArray<NSDictionary *> *WFAutoRemove(NSArray<WFTree *> *trees, WFReview *r, WFMode mode);

/// Short words for a worktree's git state: "merged (squash) · upstream gone · 2 unpushed".
NSString *WFStateWords(WFTree *t);
NSString *WFSessionWords(NSDictionary *s);
/// active (holds work or is in use), merged, stale, quiet or missing, for the menu sections.
NSString *WFCategory(WFTree *t, WFReview *r);
