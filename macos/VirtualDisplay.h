#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Undocumented CoreGraphics interfaces. Keep these isolated from the video pipeline.
@interface CGVirtualDisplayDescriptor : NSObject
@property (copy) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (nullable instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (copy) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end
