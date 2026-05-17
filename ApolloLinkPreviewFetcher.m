#import "ApolloLinkPreviewFetcher.h"

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloState.h"

static const NSUInteger ApolloLinkPreviewMaxHTMLBytes = 2 * 1024 * 1024;

typedef void (^ApolloLinkPreviewCompletion)(ApolloLinkPreview *preview);

static dispatch_queue_t ApolloLinkPreviewFetcherQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.apollo.linkpreviews.fetcher", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableDictionary<NSString *, NSMutableArray<ApolloLinkPreviewCompletion> *> *ApolloLinkPreviewPendingFetches(void) {
    static NSMutableDictionary *pending;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [NSMutableDictionary dictionary];
    });
    return pending;
}

// Decode every &#NNN; and &#xHH; numeric entity to its actual Unicode scalar.
// Walks the string in one pass so we don't run a regex over every shared input.
static NSString *ApolloLinkPreviewDecodeNumericEntities(NSString *string) {
    if (string.length == 0) return string;
    NSRange amp = [string rangeOfString:@"&#"];
    if (amp.location == NSNotFound) return string;

    NSMutableString *out = [NSMutableString stringWithCapacity:string.length];
    NSScanner *scanner = [NSScanner scannerWithString:string];
    scanner.charactersToBeSkipped = nil;
    NSCharacterSet *hexDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSCharacterSet *decDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];

    while (!scanner.atEnd) {
        NSString *chunk = nil;
        if ([scanner scanUpToString:@"&#" intoString:&chunk]) {
            [out appendString:chunk];
        }
        if (scanner.atEnd) break;

        NSUInteger savedLocation = scanner.scanLocation;
        // Consume the "&#" prefix.
        scanner.scanLocation = savedLocation + 2;

        BOOL isHex = NO;
        if (scanner.scanLocation < string.length) {
            unichar maybeX = [string characterAtIndex:scanner.scanLocation];
            if (maybeX == 'x' || maybeX == 'X') {
                isHex = YES;
                scanner.scanLocation += 1;
            }
        }

        NSString *digits = nil;
        BOOL gotDigits = [scanner scanCharactersFromSet:(isHex ? hexDigits : decDigits) intoString:&digits];
        BOOL terminated = NO;
        if (gotDigits && scanner.scanLocation < string.length && [string characterAtIndex:scanner.scanLocation] == ';') {
            terminated = YES;
            scanner.scanLocation += 1;
        }

        if (!gotDigits || !terminated) {
            // Malformed entity; copy the literal "&" and resume scanning right after it.
            [out appendString:@"&"];
            scanner.scanLocation = savedLocation + 1;
            continue;
        }

        unsigned int scalar = 0;
        NSScanner *numScanner = [NSScanner scannerWithString:digits];
        BOOL parsed = isHex ? [numScanner scanHexInt:&scalar] : [numScanner scanInt:(int *)&scalar];
        if (!parsed || scalar == 0 || scalar > 0x10FFFF) {
            // Garbage value; drop the entity entirely.
            continue;
        }

        if (scalar <= 0xFFFF) {
            [out appendFormat:@"%C", (unichar)scalar];
        } else {
            uint32_t v = scalar - 0x10000;
            unichar high = (unichar)(0xD800 + (v >> 10));
            unichar low = (unichar)(0xDC00 + (v & 0x3FF));
            [out appendFormat:@"%C%C", high, low];
        }
    }

    return out;
}

static NSString *ApolloLinkPreviewCleanString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return nil;
    NSString *clean = ApolloLinkPreviewDecodeNumericEntities(string);
    clean = [clean stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    clean = [clean stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    clean = [clean stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    // &amp; last so we don't double-decode embedded entities.
    clean = [clean stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRegularExpression *whitespace = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    clean = [whitespace stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    return clean.length > 0 ? clean : nil;
}

// Returns YES when the supplied URL points at a subreddit listing or a user
// profile / overview rather than an individual post. Reddit's anti-bot wall
// will hand any unauthenticated scrape a "Please wait for verification" page
// for these, so we'd rather punt back to Apollo's native subreddit card.
static BOOL ApolloLinkPreviewIsRedditListingURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return NO;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part.lowercaseString];
    }
    if (parts.count == 0) return YES;

    NSString *first = parts[0];
    if (![first isEqualToString:@"r"] && ![first isEqualToString:@"user"] && ![first isEqualToString:@"u"]) {
        return NO;
    }
    if (parts.count < 2) return YES;
    if ([parts containsObject:@"comments"]) return NO;

    // /r/foo, /r/foo/, /r/foo/new, /r/foo/about, /user/bar, /user/bar/submitted, ...
    return YES;
}

// Sniffs the supplied HTML for the giveaway signatures of an anti-bot
// challenge page (Reddit's "Please wait for verification", Cloudflare's
// "Just a moment", Akamai, etc.). When we see one we mark the preview as
// noMetadata so Apollo's classic card shows through.
static BOOL ApolloLinkPreviewIsBlockedPage(NSString *title, NSString *html) {
    NSArray<NSString *> *titleNeedles = @[
        @"please wait for verification",
        @"just a moment",
        @"attention required",
        @"one more step",
        @"access denied",
        @"are you a robot",
        @"verifying you are human",
    ];
    NSString *lowerTitle = title.lowercaseString;
    for (NSString *needle in titleNeedles) {
        if (lowerTitle.length > 0 && [lowerTitle containsString:needle]) return YES;
    }

    if (html.length > 0 && html.length < 16 * 1024) {
        NSString *lowerHTML = html.lowercaseString;
        if ([lowerHTML containsString:@"verifying you are human"]) return YES;
        if ([lowerHTML containsString:@"cf-challenge"]) return YES;
        if ([lowerHTML containsString:@"cf_chl_opt"]) return YES;
    }
    return NO;
}

static NSString *ApolloLinkPreviewTruncatedString(NSString *string, NSUInteger maxLength) {
    NSString *clean = ApolloLinkPreviewCleanString(string);
    if (clean.length <= maxLength) return clean;
    return [[clean substringToIndex:maxLength] stringByAppendingString:@"..."];
}

static BOOL ApolloLinkPreviewURLIsHTTP(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static NSString *ApolloLinkPreviewHost(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static BOOL ApolloLinkPreviewHostIs(NSURL *url, NSString *host) {
    NSString *lowerHost = ApolloLinkPreviewHost(url);
    return [lowerHost isEqualToString:host] || [lowerHost hasSuffix:[@"." stringByAppendingString:host]];
}

static NSString *ApolloRedditPostIDFromURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }

    if ([host isEqualToString:@"redd.it"] && clean.count > 0) return clean.firstObject;
    NSUInteger commentsIndex = [clean indexOfObject:@"comments"];
    if (commentsIndex != NSNotFound && commentsIndex + 1 < clean.count) return clean[commentsIndex + 1];
    return nil;
}

static NSURL *ApolloLinkPreviewURLFromString(NSString *string, NSURL *baseURL) {
    NSString *clean = ApolloLinkPreviewCleanString(string);
    if (clean.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:clean relativeToURL:baseURL];
    url = url.absoluteURL;
    return ApolloLinkPreviewURLIsHTTP(url) ? url : nil;
}

static NSString *ApolloLinkPreviewTitleFromURL(NSURL *url) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        NSString *decoded = part.stringByRemovingPercentEncoding ?: part;
        decoded = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        decoded = ApolloLinkPreviewCleanString(decoded);
        if (decoded.length == 0) continue;
        if ([decoded.lowercaseString isEqualToString:@"en"] || [decoded.lowercaseString isEqualToString:@"wiki"]) continue;
        if ([decoded.lowercaseString isEqualToString:@"usage"] || [decoded.lowercaseString isEqualToString:@"matches"]) continue;
        [parts addObject:decoded.capitalizedString];
    }

    if (parts.count == 0) return ApolloLinkPreviewHost(url);
    NSUInteger start = parts.count > 3 ? parts.count - 3 : 0;
    return [[parts subarrayWithRange:NSMakeRange(start, parts.count - start)] componentsJoinedByString:@" "];
}

static NSURL *ApolloLinkPreviewFallbackIconURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    if (host.length == 0) return nil;
    if (ApolloLinkPreviewHostIs(url, @"wikipedia.org")) {
        return [NSURL URLWithString:@"https://www.wikipedia.org/portal/wikipedia.org/assets/img/Wikipedia-logo-v2.png"];
    }

    NSString *escapedHost = [host stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (escapedHost.length == 0) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/s2/favicons?domain=%@&sz=128", escapedHost]];
}

static void ApolloLinkPreviewApplyFallbackIcon(ApolloLinkPreview *preview, NSURL *url) {
    preview.imageURL = ApolloLinkPreviewFallbackIconURL(url);
    preview.imageSize = CGSizeMake(128.0, 128.0);
    preview.imageIsFallbackIcon = YES;
}

static ApolloLinkPreview *ApolloLinkPreviewFallbackPreviewForURL(NSURL *url, NSString *reason) {
    NSString *title = ApolloLinkPreviewTitleFromURL(url);
    if (title.length == 0) return nil;

    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.siteName = ApolloLinkPreviewHost(url);
    preview.title = title;
    preview.desc = ApolloLinkPreviewCleanString(reason.length > 0 ? reason : url.absoluteString);
    ApolloLinkPreviewApplyFallbackIcon(preview, url);
    preview.fetchedAt = [NSDate date];
    return preview;
}

static NSURL *ApolloTheNumbersPosterURLFromHTML(NSString *html, NSURL *baseURL) {
    if (html.length == 0 || !ApolloLinkPreviewHostIs(baseURL, @"the-numbers.com")) return nil;

    NSRegularExpression *imgRegex = [NSRegularExpression regularExpressionWithPattern:@"<img\\s+[^>]*>"
                                                                               options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:nil];
    NSRegularExpression *srcRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bsrc\\s*=\\s*(['\"])(.*?)\\1"
                                                                              options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                error:nil];
    NSArray<NSTextCheckingResult *> *matches = [imgRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *tag = [html substringWithRange:match.range];
        NSTextCheckingResult *srcMatch = [srcRegex firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
        if (!srcMatch || srcMatch.numberOfRanges < 3) continue;

        NSString *src = [tag substringWithRange:[srcMatch rangeAtIndex:2]];
        NSString *lower = src.lowercaseString ?: @"";
        if (![lower containsString:@"/images/movie-posters/"]) continue;
        if ([lower containsString:@"/site-images/"] || [lower hasSuffix:@".svg"]) continue;

        NSURL *posterURL = ApolloLinkPreviewURLFromString(src, baseURL);
        if (posterURL.absoluteString.length > 0) return posterURL;
    }
    return nil;
}

static NSString *ApolloTheNumbersSynopsisFromHTML(NSString *html) {
    if (html.length == 0) return nil;
    NSRegularExpression *synopsisRegex = [NSRegularExpression regularExpressionWithPattern:@"<h2[^>]*>\\s*Synopsis\\s*</h2>\\s*<p[^>]*>(.*?)</p>"
                                                                                   options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                     error:nil];
    NSTextCheckingResult *match = [synopsisRegex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!match || match.numberOfRanges < 2) return nil;

    NSString *raw = [html substringWithRange:[match rangeAtIndex:1]];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    raw = [tags stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@" "];
    return ApolloLinkPreviewTruncatedString(raw, 220);
}

static NSString *ApolloYouTubeVideoIDFromURL(NSURL *url) {
    NSString *host = ApolloLinkPreviewHost(url);
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }

    if ([host isEqualToString:@"youtu.be"] && clean.count > 0) return clean.firstObject;
    if (ApolloLinkPreviewHostIs(url, @"youtube.com")) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"v"] && item.value.length > 0) return item.value;
        }
        NSUInteger shortsIndex = [clean indexOfObject:@"shorts"];
        if (shortsIndex != NSNotFound && shortsIndex + 1 < clean.count) return clean[shortsIndex + 1];
        NSUInteger embedIndex = [clean indexOfObject:@"embed"];
        if (embedIndex != NSNotFound && embedIndex + 1 < clean.count) return clean[embedIndex + 1];
    }
    return nil;
}

static NSString *ApolloWikipediaPageTitleFromURL(NSURL *url) {
    if (!ApolloLinkPreviewHostIs(url, @"wikipedia.org")) return nil;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSUInteger wikiIndex = [parts indexOfObject:@"wiki"];
    if (wikiIndex == NSNotFound || wikiIndex + 1 >= parts.count) return nil;
    NSArray<NSString *> *titleParts = [parts subarrayWithRange:NSMakeRange(wikiIndex + 1, parts.count - wikiIndex - 1)];
    NSString *title = [titleParts componentsJoinedByString:@"/"];
    return title.length > 0 ? title : nil;
}

static NSMutableURLRequest *ApolloLinkPreviewRequest(NSURL *url, NSTimeInterval timeout) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : @"ApolloLinkPreviews/1.0";
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/html,application/json;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    return request;
}

@interface ApolloLinkPreviewFetcher ()
+ (void)fetchPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)finishURL:(NSURL *)url preview:(ApolloLinkPreview *)preview;
+ (void)fetchYouTubePreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)imageURLIsUsable:(NSURL *)imageURL completion:(void (^)(BOOL usable))completion;
+ (void)fetchWikipediaPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchRedditPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchGitHubPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
+ (void)fetchHTMLPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion;
@end

@implementation ApolloLinkPreviewFetcher

+ (void)requestPreviewForURL:(NSURL *)url completion:(void (^)(ApolloLinkPreview *preview))completion {
    if (!ApolloLinkPreviewURLIsHTTP(url)) {
        if (completion) completion(nil);
        return;
    }

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    NSString *logHost = url.host.lowercaseString ?: @"";
    if ([logHost hasPrefix:@"www."]) logHost = [logHost substringFromIndex:4];
    ApolloLog(@"[LinkPreviews] requestPreview host=%@ cached=%@", logHost, cached ? @"YES" : @"NO");
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    NSString *key = url.absoluteString ?: @"";
    dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
        NSMutableDictionary *pending = ApolloLinkPreviewPendingFetches();
        NSMutableArray *completions = pending[key];
        if (completions) {
            if (completion) [completions addObject:[completion copy]];
            return;
        }

        pending[key] = completion ? [NSMutableArray arrayWithObject:[completion copy]] : [NSMutableArray array];
        [self fetchPreviewForURL:url completion:^(ApolloLinkPreview *preview) {
            [self finishURL:url preview:preview];
        }];
    });
}

+ (BOOL)isTwitterURL:(NSURL *)url {
    NSString *host = ApolloLinkPreviewHost(url);
    return [host isEqualToString:@"x.com"] || [host hasSuffix:@".x.com"]
        || [host isEqualToString:@"twitter.com"] || [host hasSuffix:@".twitter.com"];
}

+ (void)fetchPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    if ([self isTwitterURL:url]) {
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.noMetadata = YES;
        preview.fetchedAt = [NSDate date];
        completion(preview);
    } else if (ApolloLinkPreviewHostIs(url, @"youtube.com") || ApolloLinkPreviewHostIs(url, @"youtu.be")) {
        [self fetchYouTubePreviewForURL:url completion:completion];
    } else if (ApolloWikipediaPageTitleFromURL(url).length > 0) {
        [self fetchWikipediaPreviewForURL:url completion:completion];
    } else if (ApolloLinkPreviewHostIs(url, @"reddit.com") || ApolloLinkPreviewHostIs(url, @"redd.it")) {
        [self fetchRedditPreviewForURL:url completion:completion];
    } else if (ApolloLinkPreviewHostIs(url, @"github.com")) {
        [self fetchGitHubPreviewForURL:url completion:completion];
    } else {
        [self fetchHTMLPreviewForURL:url completion:completion];
    }
}

+ (void)finishURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    if (!preview) {
        ApolloLog(@"[LinkPreviews] no cache for empty preview host=%@", ApolloLinkPreviewHost(url));
        NSString *key = url.absoluteString ?: @"";
        dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
            NSMutableArray *completions = ApolloLinkPreviewPendingFetches()[key];
            [ApolloLinkPreviewPendingFetches() removeObjectForKey:key];
            for (ApolloLinkPreviewCompletion completion in completions) {
                completion(nil);
            }
        });
        return;
    }

    if (![preview hasUsefulMetadata]) {
        [[ApolloLinkPreviewCache sharedCache] markNoMetadataForURL:url];
    } else {
        preview.fetchedAt = preview.fetchedAt ?: [NSDate date];
        [[ApolloLinkPreviewCache sharedCache] storePreview:preview forURL:url];
    }

    NSString *key = url.absoluteString ?: @"";
    dispatch_async(ApolloLinkPreviewFetcherQueue(), ^{
        NSMutableArray *completions = ApolloLinkPreviewPendingFetches()[key];
        [ApolloLinkPreviewPendingFetches() removeObjectForKey:key];
        for (ApolloLinkPreviewCompletion completion in completions) {
            completion(preview);
        }
    });
}

+ (void)fetchYouTubePreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:url.absoluteString],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
    ];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(components.URL, 10.0);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ApolloLog(@"[LinkPreviews] YouTube oEmbed failed %@ err=%@", url.absoluteString, error.localizedDescription);
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"YouTube";
        preview.title = ApolloLinkPreviewCleanString(json[@"title"]);
        preview.desc = ApolloLinkPreviewCleanString(json[@"author_name"]);
        NSString *videoID = ApolloYouTubeVideoIDFromURL(url);
        if (videoID.length > 0) {
            NSURL *hq720URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hq720.jpg", videoID]];
            [self imageURLIsUsable:hq720URL completion:^(BOOL usable) {
                if (usable) {
                    preview.imageURL = hq720URL;
                    preview.imageSize = CGSizeMake(1280.0, 720.0);
                } else {
                    preview.imageURL = ApolloLinkPreviewURLFromString(json[@"thumbnail_url"], url);
                    preview.imageSize = CGSizeMake([json[@"thumbnail_width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_width"] doubleValue] : 0.0,
                                                   [json[@"thumbnail_height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_height"] doubleValue] : 0.0);
                    ApolloLog(@"[LinkPreviews] YouTube hq720 unavailable %@ fallback=%@", url.absoluteString, preview.imageURL.absoluteString ?: @"(none)");
                }
                preview.fetchedAt = [NSDate date];
                completion(preview);
            }];
            return;
        } else {
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"thumbnail_url"], url);
            preview.imageSize = CGSizeMake([json[@"thumbnail_width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_width"] doubleValue] : 0.0,
                                           [json[@"thumbnail_height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail_height"] doubleValue] : 0.0);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)imageURLIsUsable:(NSURL *)imageURL completion:(void (^)(BOOL usable))completion {
    if (imageURL.absoluteString.length == 0) {
        completion(NO);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:imageURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    request.HTTPMethod = @"HEAD";
    [request setValue:@"image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = [[httpResponse allHeaderFields][@"Content-Type"] lowercaseString] ?: @"";
        BOOL usable = !error && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
            && (contentType.length == 0 || [contentType containsString:@"image"]);
        completion(usable);
    }] resume];
}

+ (void)fetchWikipediaPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSString *pageTitle = ApolloWikipediaPageTitleFromURL(url);
    NSString *encodedTitle = [pageTitle stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (encodedTitle.length == 0) {
        completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
        return;
    }

    NSString *scheme = url.scheme.length > 0 ? url.scheme : @"https";
    NSString *summaryURLString = [NSString stringWithFormat:@"%@://%@/api/rest_v1/page/summary/%@", scheme, url.host, encodedTitle];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:summaryURLString], 10.0);
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            ApolloLog(@"[LinkPreviews] Wikipedia summary failed %@ status=%ld err=%@",
                      url.absoluteString, (long)httpResponse.statusCode, error.localizedDescription);
            completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Wikipedia";
        preview.title = ApolloLinkPreviewCleanString(json[@"displaytitle"]) ?: ApolloLinkPreviewCleanString(json[@"title"]) ?: ApolloLinkPreviewTitleFromURL(url);
        preview.desc = ApolloLinkPreviewTruncatedString(json[@"extract"], 220);
        NSString *image = json[@"thumbnail"][@"source"] ?: json[@"originalimage"][@"source"];
        preview.imageURL = ApolloLinkPreviewURLFromString(image, url);
        if (preview.imageURL.absoluteString.length > 0) {
            preview.imageSize = CGSizeMake([json[@"thumbnail"][@"width"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail"][@"width"] doubleValue] : 0.0,
                                           [json[@"thumbnail"][@"height"] respondsToSelector:@selector(doubleValue)] ? [json[@"thumbnail"][@"height"] doubleValue] : 0.0);
        } else {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)fetchRedditPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSString *postID = ApolloRedditPostIDFromURL(url);
    if (postID.length == 0) {
        if (ApolloLinkPreviewIsRedditListingURL(url)) {
            // Subreddit / user-profile / overview links: Reddit's HTML is gated
            // by a verification challenge that returns garbage metadata. Punt
            // back to Apollo's native card (which already paints a subreddit
            // icon + name) instead of trying to scrape.
            ApolloLog(@"[LinkPreviews] Reddit listing URL skipped %@", url.absoluteString);
            ApolloLinkPreview *preview = [ApolloLinkPreview new];
            preview.noMetadata = YES;
            preview.fetchedAt = [NSDate date];
            completion(preview);
            return;
        }
        [self fetchHTMLPreviewForURL:url completion:completion];
        return;
    }

    NSString *urlString = sLatestRedditBearerToken.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/comments/%@/.json?raw_json=1", postID]
        : [NSString stringWithFormat:@"https://www.reddit.com/comments/%@.json?raw_json=1", postID];
    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:urlString], 10.0);
    if (sLatestRedditBearerToken.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            ApolloLog(@"[LinkPreviews] Reddit JSON failed %@ err=%@", url.absoluteString, error.localizedDescription);
            completion(nil);
            return;
        }

        NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *post = nil;
        if ([json isKindOfClass:[NSArray class]] && json.count > 0) {
            NSArray *children = json[0][@"data"][@"children"];
            if ([children isKindOfClass:[NSArray class]] && children.count > 0) {
                post = children[0][@"data"];
            }
        }

        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"Reddit";
        preview.title = ApolloLinkPreviewCleanString(post[@"title"]);
        preview.desc = ApolloLinkPreviewTruncatedString(post[@"selftext"], 200);
        NSString *image = post[@"preview"][@"images"][0][@"source"][@"url"];
        if (![image isKindOfClass:[NSString class]] || image.length == 0) {
            NSString *thumbnail = post[@"thumbnail"];
            image = ([thumbnail hasPrefix:@"http://"] || [thumbnail hasPrefix:@"https://"]) ? thumbnail : nil;
        }
        preview.imageURL = ApolloLinkPreviewURLFromString(image, url);
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (void)fetchGitHubPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count < 2) {
        [self fetchHTMLPreviewForURL:url completion:completion];
        return;
    }

    NSString *owner = clean[0];
    NSString *repo = clean[1];
    NSString *apiURLString = nil;
    if (clean.count >= 4 && ([clean[2] isEqualToString:@"issues"] || [clean[2] isEqualToString:@"pull"])) {
        apiURLString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/issues/%@", owner, repo, clean[3]];
    } else {
        apiURLString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@", owner, repo];
    }

    NSMutableURLRequest *request = ApolloLinkPreviewRequest([NSURL URLWithString:apiURLString], 10.0);
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion(nil);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = @"GitHub";
        if (json[@"full_name"]) {
            preview.title = ApolloLinkPreviewCleanString(json[@"full_name"]);
            preview.desc = ApolloLinkPreviewTruncatedString(json[@"description"], 200);
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"owner"][@"avatar_url"], url);
        } else {
            preview.title = ApolloLinkPreviewCleanString(json[@"title"]);
            preview.desc = ApolloLinkPreviewTruncatedString(json[@"body"], 200);
            preview.imageURL = ApolloLinkPreviewURLFromString(json[@"user"][@"avatar_url"], url);
        }
        preview.fetchedAt = [NSDate date];
        completion(preview);
    }] resume];
}

+ (NSDictionary<NSString *, NSString *> *)metaValuesFromHTML:(NSString *)html {
    if (html.length == 0) return @{};

    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    NSRegularExpression *metaRegex = [NSRegularExpression regularExpressionWithPattern:@"<meta\\s+[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attrRegex = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z:-]+)\\s*=\\s*(['\"])(.*?)\\2"
                                                                               options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:nil];
    NSArray<NSTextCheckingResult *> *metaMatches = [metaRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    for (NSTextCheckingResult *metaMatch in metaMatches) {
        NSString *tag = [html substringWithRange:metaMatch.range];
        NSMutableDictionary<NSString *, NSString *> *attrs = [NSMutableDictionary dictionary];
        NSArray<NSTextCheckingResult *> *attrMatches = [attrRegex matchesInString:tag options:0 range:NSMakeRange(0, tag.length)];
        for (NSTextCheckingResult *attrMatch in attrMatches) {
            if (attrMatch.numberOfRanges < 4) continue;
            NSString *name = [[tag substringWithRange:[attrMatch rangeAtIndex:1]] lowercaseString];
            NSString *value = [tag substringWithRange:[attrMatch rangeAtIndex:3]];
            attrs[name] = value;
        }

        NSString *key = attrs[@"property"] ?: attrs[@"name"];
        NSString *content = attrs[@"content"];
        if (key.length > 0 && content.length > 0) {
            values[key.lowercaseString] = content;
        }
    }

    NSRegularExpression *titleRegex = [NSRegularExpression regularExpressionWithPattern:@"<title[^>]*>(.*?)</title>"
                                                                                options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                  error:nil];
    NSTextCheckingResult *titleMatch = [titleRegex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (titleMatch && titleMatch.numberOfRanges > 1) {
        values[@"title"] = [html substringWithRange:[titleMatch rangeAtIndex:1]];
    }
    return values;
}

+ (void)fetchHTMLPreviewForURL:(NSURL *)url completion:(ApolloLinkPreviewCompletion)completion {
    NSMutableURLRequest *request = ApolloLinkPreviewRequest(url, 12.0);
    [request setValue:@"bytes=0-65535" forHTTPHeaderField:@"Range"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = [[httpResponse allHeaderFields][@"Content-Type"] lowercaseString];
        if (error || !data || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 || data.length > ApolloLinkPreviewMaxHTMLBytes || (contentType.length > 0 && ![contentType containsString:@"text/html"])) {
            ApolloLog(@"[LinkPreviews] HTML fetch failed %@ status=%ld type=%@ bytes=%lu err=%@",
                      url.absoluteString, (long)httpResponse.statusCode, contentType ?: @"",
                      (unsigned long)data.length, error.localizedDescription);
            completion(ApolloLinkPreviewFallbackPreviewForURL(url, contentType.length > 0 ? contentType : nil));
            return;
        }

        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (html.length == 0) {
            html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }

        NSDictionary<NSString *, NSString *> *meta = [self metaValuesFromHTML:html];
        ApolloLinkPreview *preview = [ApolloLinkPreview new];
        preview.siteName = ApolloLinkPreviewCleanString(meta[@"og:site_name"]) ?: ApolloLinkPreviewHost(url);
        preview.title = ApolloLinkPreviewCleanString(meta[@"og:title"]) ?: ApolloLinkPreviewCleanString(meta[@"twitter:title"]) ?: ApolloLinkPreviewCleanString(meta[@"title"]);
        preview.desc = ApolloLinkPreviewTruncatedString(meta[@"og:description"] ?: meta[@"twitter:description"] ?: meta[@"description"], 200);
        preview.imageURL = ApolloLinkPreviewURLFromString(meta[@"og:image"] ?: meta[@"twitter:image"] ?: meta[@"twitter:image:src"], url);
        preview.fetchedAt = [NSDate date];

        if (ApolloLinkPreviewHostIs(url, @"the-numbers.com")) {
            NSURL *posterURL = ApolloTheNumbersPosterURLFromHTML(html, url);
            NSString *synopsis = ApolloTheNumbersSynopsisFromHTML(html);
            if (posterURL.absoluteString.length > 0) {
                preview.imageURL = posterURL;
                preview.imageSize = CGSizeMake(300.0, 450.0);
                preview.imageIsFallbackIcon = NO;
                ApolloLog(@"[LinkPreviews] The Numbers poster extracted %@", posterURL.absoluteString);
            }
            if (synopsis.length > 0) preview.desc = synopsis;
        }

        // If we landed on a Cloudflare / Reddit verification gate, treat the
        // result as empty so Apollo's native card paints instead of "Please
        // wait for verification" everywhere.
        if (ApolloLinkPreviewIsBlockedPage(preview.title, html)) {
            ApolloLog(@"[LinkPreviews] blocked-page sniff matched %@ title=%@", url.absoluteString, preview.title);
            completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            return;
        }

        if (preview.title.length == 0 && preview.desc.length == 0 && preview.imageURL.absoluteString.length == 0) {
            completion(ApolloLinkPreviewFallbackPreviewForURL(url, nil));
            return;
        }

        if (preview.imageURL.absoluteString.length == 0 && (preview.title.length > 0 || preview.desc.length > 0)) {
            ApolloLinkPreviewApplyFallbackIcon(preview, url);
        }

        completion(preview);
    }] resume];
}

@end
