#import <Foundation/Foundation.h>
#import "Trees.h"

/// What the model decided about one worktree.
@interface WFVerdict : NSObject
@property (copy) NSString *verdict;        // active | stale | unsure
@property (copy) NSString *about, *reason;
@property (copy) NSString *what, *why, *state, *recommendation;   // one sentence each, from the facts WorkForest gathered
@property (copy) NSString *keepEvidence;   // the concrete fact that the work is still wanted, or empty when there is none
@property BOOL judged;                     // the Eager judge decided: stale means remove, active means keep
@property double confidence;
@end

/// One finished review, saved to review.json so the app and the CLI share it.
@interface WFReview : NSObject
@property (strong) NSDate *at;
@property (copy) NSString *model, *error;  // model is the one that answered: haiku, gpt-6-luna, ...
@property (copy) NSString *note;           // why the first choice was skipped, for example "Haiku: usage limit reached"
@property NSInteger tokens, treeCount;
@property double seconds, costUSD;         // costUSD is the list price the CLI reports; a subscription is not billed per call
@property (strong) NSDictionary<NSString *, WFVerdict *> *verdicts;   // by worktree path
@property (copy) NSString *summary;        // what is going on across all worktrees, in a few sentences
@property (copy) NSString *trigger;        // what woke the review: schedule, new worktree, age mark, low disk, manual
@property (copy) NSString *mode;           // idle | proactive | eager, when the review ran
@property (copy) NSString *judgeError;     // the Eager judge failed; its worktrees fall back to the first verdict
@property (strong) NSArray<NSDictionary *> *actions;   // what the mode removed after this review
+ (instancetype)load;                      // nil when there is none
- (void)save;
@end

/// Asks a model which worktrees are still wanted: Claude through the claude CLI, or OpenAI's Luna through the codex
/// CLI, both on the user's own login. The model gets no tools: it reads the facts below and answers in a fixed schema.
/// The model "auto" tries Haiku first and uses Luna when claude is missing, signed out or out of usage.
@interface WFReviewer : NSObject
+ (NSString *)claudePath;                  // $WORKFOREST_CLAUDE, the workforest.claudePath setting, or the usual install paths
+ (NSString *)codexPath;                   // $WORKFOREST_CODEX, the workforest.codexPath setting, or the usual install paths
/// Exactly what is sent, redacted. Never file contents.
+ (NSArray<NSDictionary *> *)factsFor:(NSArray<WFTree *> *)trees;
/// The model's id for a worktree: the path with the home folder as ~.
+ (NSString *)idFor:(WFTree *)t;
/// Blocks until the CLI answers or times out. Call it off the main thread in the app.
+ (WFReview *)review:(NSArray<WFTree *> *)trees model:(NSString *)model;
/// Eager mode's second look. The burden of proof is on the worktree: the judge keeps it only with a concrete fact
/// that someone still wants it. Replaces those worktrees' verdicts in r with judged ones. Blocks.
+ (void)judge:(NSArray<WFTree *> *)trees review:(WFReview *)r model:(NSString *)model;
@end

/// The Model menu: auto, the claude aliases and luna. Anything else typed into the setting is passed through as is,
/// to codex when it starts with gpt- and to claude otherwise.
NSArray<NSArray<NSString *> *> *WFModels(void);   // [alias, label]
NSString *WFModelLabel(NSString *alias);
