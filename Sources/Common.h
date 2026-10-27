#import <Foundation/Foundation.h>

NSString *WFFormatBytes(uint64_t bytes);
NSString *WFDuration(NSTimeInterval seconds);      // "45s", "12m", "3h 4m", "5d 2h"
NSString *WFSupportDir(void);                      // ~/Library/Application Support/WorkForest, or $WORKFOREST_HOME
NSString *WFShellQuote(NSString *s);
/// Removes values that look like secrets: key=value pairs with a secret-sounding key, the value after a --token
/// style flag, passwords in URLs, and long opaque strings.
NSString *WFRedact(NSString *s);
/// One line, redacted, the home folder as ~, at most n characters. nil for empty text.
NSString *WFClip(NSString *s, NSUInteger n);
/// A path from the user: ~ expanded, relative to the current folder, symlinks resolved as realpath does.
NSString *WFAbsolute(NSString *path);
/// The path with the home folder as ~.
NSString *WFTilde(NSString *path);

/// git, read-only by default: no optional locks, no prompts, no pager, a time limit. Returns stdout without the
/// trailing newline, or nil when git could not run or timed out. status is git's exit status, -1 when it did not run.
NSString *WFGit(NSString *dir, NSArray<NSString *> *args, int *status);
/// The same with input on stdin and a time limit in seconds.
NSString *WFGitInput(NSString *dir, NSArray<NSString *> *args, NSData *input, NSTimeInterval timeout, int *status);
NSString *WFGitPath(void);                         // nil when no real git is installed
