//
//  XMPhotosRequestManager.h
//  XMPhotosRequestManager
//
//  Created by mxmhao on 2018/5/2.
//  Copyright © 2018年 mxm. All rights reserved.
//
//  相册导出管理类

#import <Photos/Photos.h>

NS_ASSUME_NONNULL_BEGIN

@class XMPhotosRequestManager;

@protocol XMPhotosRequestManagerDelegate <NSObject>

@optional

/**
 即将导出asset。<br/>Asset is about to export.

 @param manager XMPhotosRequestManager
 @param asset 将要导出的PHAsset。<br/>The PHAsset to be exported.
 */
- (void)manager:(XMPhotosRequestManager *)manager willRequest:(PHAsset *)asset;

/**
 视频导出之前调用，你可以设置一些参数，但不能设置exportSession.outputURL。<br/>
 Call before video export.You can customize the Settings properties but exclude exportSession.outputURL.

 @param manager XMPhotosRequestManager
 @param exportSession AVAssetExportSession
 */
- (void)manager:(XMPhotosRequestManager *)manager customPropertyForExportSession:(AVAssetExportSession *)exportSession;

/**
 当图片导出完成，但尚未保存到本地，会调用此方法。<br/>
 This method is called when the image export is complete but has not been saved to the local.

 @param manager XMPhotosRequestManager
 @param imageData Image data
 @param asset PHAsset
 @param dataUTI UniformTypeIdentifier
 @param orientation UIImageOrientation
 @return Image data after editing.
 */
- (nullable NSData *)manager:(XMPhotosRequestManager *)manager editImageData:(NSData *)imageData asset:(PHAsset *)asset dataUTI:(NSString *)dataUTI orientation:(UIImageOrientation)orientation;

/**
 当图片导出完成，且保存到本地，会调用此方法。<br/>
 This method is called when the image export is completed and saved to the local.

 @param manager XMPhotosRequestManager
 @param asset PHAsset
 @param cachePath The absolute path of the cache file.
 */
- (void)manager:(XMPhotosRequestManager *)manager exportCompleted:(PHAsset *)asset cachePath:(NSString *)cachePath;

/**
 Called when the image export fails.

 @param manager XMPhotosRequestManager
 @param asset PHAsset
 @param error NSError
 */
- (void)manager:(XMPhotosRequestManager *)manager exportFailed:(PHAsset *)asset error:(NSError *)error;

@end

@interface XMPhotosRequestManager : NSObject

/** delegate */
@property (nonatomic, weak) id<XMPhotosRequestManagerDelegate> delegate;
/** file export cache directory */
@property (nonatomic, copy, readonly, nonnull) NSString *cacheDir;
/** PHImageRequestOptions. Default is nil */
@property (nonatomic, strong) PHImageRequestOptions *imageOptions;
/** PHVideoRequestOptions. Default is nil */
@property (nonatomic, strong) PHVideoRequestOptions *videoOptions;
/** AVAssetExportPreset e.g. AVAssetExportPresetHighestQuality. Default is AVAssetExportPresetPassthrough. */
@property (nonatomic, copy) NSString *videoExportPreset;
/**
 每次完成导出n个就自动暂停，0表示不自动暂停，默认是4。可以调用-startRequest继续导出。<br/>
 Automatically pause when the (n) exports are completed.
 0 means no automatic pause. Default is 4.
 Call -startRequest can continue to export.
 */
@property (nonatomic, assign) NSUInteger autoPauseWhenCompleteNumber;
/**
 是否已自动暂停。可以调用-startRequest继续导出。<br/>
 Has it been automatic paused? Call -startRequest can continue to export.
 */
@property (nonatomic, assign, readonly) BOOL isAutoPaused;

- (instancetype)initWithCacheDir:(NSString *)cacheDir NS_DESIGNATED_INITIALIZER;

- (void)addPHAssets:(NSArray<PHAsset *> *)phassets;
- (void)deletePHAssets:(NSArray<PHAsset *> *)phassets;

/** start request */
- (void)startRequest;

/** stop request will delete all PHAssets. */
- (void)stopRequest;

- (void)pause:(PHAsset *)asset;
- (void)pauseAll;

- (void)resume:(PHAsset *)asset;
- (void)resumeAll;

@end

NS_ASSUME_NONNULL_END
