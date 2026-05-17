#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface ApolloLinkPreview : NSObject

@property (nonatomic, copy) NSString *siteName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *desc;
@property (nonatomic, strong) NSURL *imageURL;
@property (nonatomic) CGSize imageSize;
@property (nonatomic) BOOL imageIsFallbackIcon;
@property (nonatomic, strong) NSDate *fetchedAt;
@property (nonatomic) BOOL noMetadata;

+ (instancetype)previewFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
- (BOOL)hasUsefulMetadata;

@end
