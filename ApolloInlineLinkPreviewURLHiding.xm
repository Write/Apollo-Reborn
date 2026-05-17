#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloState.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

@class ASDisplayNode;

@interface ASDisplayNode : NSObject
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)setNeedsDisplay;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

static NSString * const ApolloLinkPreviewDidCacheNotification = @"ApolloLinkPreviewDidCacheNotification";

static const void *kApolloLPURLHidingOriginalTextKey = &kApolloLPURLHidingOriginalTextKey;
static const void *kApolloLPURLHidingReentrancyKey = &kApolloLPURLHidingReentrancyKey;

static BOOL ApolloLPURLHidingEnabled(void) {
    return sLinkPreviewBodyMode != ApolloLinkPreviewModeOff || sLinkPreviewCommentsMode != ApolloLinkPreviewModeOff;
}

static NSHashTable *ApolloLPURLHidingTextNodes(void) {
    static NSHashTable *nodes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nodes = [NSHashTable weakObjectsHashTable];
    });
    return nodes;
}

static dispatch_queue_t ApolloLPURLHidingQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.apollo.linkpreviews.urlhiding", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL ApolloLPURLIsHTTP(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSURL *ApolloLPURLFromStandaloneParagraph(NSAttributedString *attributedText, NSRange paragraphRange) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || paragraphRange.length == 0) return nil;

    NSString *string = attributedText.string ?: @"";
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger start = paragraphRange.location;
    NSUInteger end = NSMaxRange(paragraphRange);
    while (start < end && [trimSet characterIsMember:[string characterAtIndex:start]]) start++;
    while (end > start && [trimSet characterIsMember:[string characterAtIndex:end - 1]]) end--;
    if (end <= start) return nil;

    NSRange trimmedRange = NSMakeRange(start, end - start);
    id linkAttr = [attributedText attribute:NSLinkAttributeName atIndex:trimmedRange.location effectiveRange:NULL];
    if (!linkAttr) return nil;

    __block BOOL linkCoversTrimmedRange = YES;
    [attributedText enumerateAttribute:NSLinkAttributeName
                               inRange:trimmedRange
                               options:0
                            usingBlock:^(id value, __unused NSRange range, BOOL *stop) {
        if (!value) {
            linkCoversTrimmedRange = NO;
            *stop = YES;
        }
    }];
    if (!linkCoversTrimmedRange) return nil;

    NSString *urlText = [string substringWithRange:trimmedRange];
    NSURL *url = [NSURL URLWithString:urlText];
    if (!ApolloLPURLIsHTTP(url)) return nil;
    return url;
}

static BOOL ApolloLPAttributedTextContainsURL(NSAttributedString *attributedText, NSURL *url) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || url.absoluteString.length == 0) return NO;
    return [attributedText.string rangeOfString:url.absoluteString options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSAttributedString *ApolloLPAttributedTextByHidingStandalonePreviewURLs(NSAttributedString *attributedText, NSArray<NSURL *> **candidateURLsOut, NSUInteger *hiddenCountOut) {
    if (candidateURLsOut) *candidateURLsOut = @[];
    if (hiddenCountOut) *hiddenCountOut = 0;
    if (!ApolloLPURLHidingEnabled() || ![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) {
        return attributedText;
    }

    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];
    NSMutableArray<NSValue *> *rangesToRemove = [NSMutableArray array];
    NSString *string = attributedText.string ?: @"";
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                               options:NSStringEnumerationByParagraphs
                            usingBlock:^(__unused NSString *substring, NSRange substringRange, NSRange enclosingRange, __unused BOOL *stop) {
        NSURL *url = ApolloLPURLFromStandaloneParagraph(attributedText, substringRange);
        if (!url) return;
        [candidateURLs addObject:url];
        if ([[ApolloLinkPreviewCache sharedCache] cachedPreviewIsRichForURL:url]) {
            [rangesToRemove addObject:[NSValue valueWithRange:enclosingRange]];
        }
    }];

    if (candidateURLsOut) *candidateURLsOut = [candidateURLs copy];
    if (hiddenCountOut) *hiddenCountOut = rangesToRemove.count;
    if (rangesToRemove.count == 0) return attributedText;

    NSMutableAttributedString *rewrittenText = [attributedText mutableCopy];
    for (NSValue *value in [rangesToRemove reverseObjectEnumerator]) {
        NSRange range = value.rangeValue;
        if (NSMaxRange(range) <= rewrittenText.length) {
            [rewrittenText deleteCharactersInRange:range];
        }
    }
    return rewrittenText;
}

static void ApolloLPRegisterURLHidingTextNode(id textNode, NSAttributedString *originalText, NSArray<NSURL *> *candidateURLs) {
    if (!textNode || ![originalText isKindOfClass:[NSAttributedString class]] || candidateURLs.count == 0) return;
    objc_setAssociatedObject(textNode, kApolloLPURLHidingOriginalTextKey, [originalText copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(ApolloLPURLHidingQueue(), ^{
        [ApolloLPURLHidingTextNodes() addObject:textNode];
    });
}

static void ApolloLPApplyURLHidingToTextNode(id textNode, NSAttributedString *incomingText) {
    if (!textNode || ![incomingText isKindOfClass:[NSAttributedString class]]) return;

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(incomingText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(textNode, incomingText, candidateURLs);
    if (rewritten == incomingText) return;

    objc_setAssociatedObject(textNode, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), rewritten);
    } @catch (__unused NSException *exception) {
    }
    objc_setAssociatedObject(textNode, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    ApolloLog(@"[LinkPreviews] hid %lu standalone rich-preview URL paragraph(s)", (unsigned long)hiddenCount);
}

static void ApolloLPReapplyURLHidingForCachedURL(NSURL *url) {
    if (!ApolloLPURLHidingEnabled() || !ApolloLPURLIsHTTP(url)) return;

    dispatch_async(ApolloLPURLHidingQueue(), ^{
        NSArray *snapshot = ApolloLPURLHidingTextNodes().allObjects;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id textNode in snapshot) {
                NSAttributedString *originalText = objc_getAssociatedObject(textNode, kApolloLPURLHidingOriginalTextKey);
                if (!ApolloLPAttributedTextContainsURL(originalText, url)) continue;
                ApolloLPApplyURLHidingToTextNode(textNode, originalText);
            }
        });
    });
}

static void ApolloLPInstallURLHidingObserver(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloLinkPreviewDidCacheNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        NSURL *url = notification.userInfo[@"url"];
        if ([url isKindOfClass:[NSURL class]]) {
            ApolloLPReapplyURLHidingForCachedURL(url);
        }
    }];
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if ([objc_getAssociatedObject(self, kApolloLPURLHidingReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(attributedText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(self, attributedText, candidateURLs);
    if (rewritten != attributedText) {
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(rewritten); } @catch (__unused NSException *exception) {}
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if ([objc_getAssociatedObject(self, kApolloLPURLHidingReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(attributedText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(self, attributedText, candidateURLs);
    if (rewritten != attributedText) {
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(rewritten); } @catch (__unused NSException *exception) {}
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}

%end

%ctor {
    ApolloLPInstallURLHidingObserver();
}
