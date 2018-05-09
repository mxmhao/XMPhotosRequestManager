//
//  XMPhotosRequestManager.m
//  XMPhotosRequestManager
//
//  Created by mxmhao on 2018/5/2.
//  Copyright © 2018年 mxm. All rights reserved.
//
//  相册导出管理类

#import "XMPhotosRequestManager.h"
#import "XMLock.h"
#import <objc/runtime.h>

typedef NS_ENUM(short, PHAssetStatus) {
    PHAssetStatusWaiting = 0,
    PHAssetStatusPaused,
    PHAssetStatusExporting,
    PHAssetStatusCompleted
};

@interface PHAsset (AbsolutPath)

@property (nonatomic, assign) PHAssetStatus status;//状态

- (BOOL)hasNotStatus;
- (void)clearStatus;//清除状态，防止下次重复使用

@end

@implementation PHAsset (AbsolutPath)

- (void)setStatus:(PHAssetStatus)status
{
    objc_setAssociatedObject(self, @selector(status), @(status), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (PHAssetStatus)status
{
    return [objc_getAssociatedObject(self, @selector(status)) shortValue];
}

//没有状态
- (BOOL)hasNotStatus
{
    return nil == objc_getAssociatedObject(self, @selector(status));
}

- (void)clearStatus
{
    objc_setAssociatedObject(self, @selector(status), nil, OBJC_ASSOCIATION_ASSIGN);
}

@end

@implementation XMPhotosRequestManager
{
    NSMutableArray<PHAsset *> *_assets;
    NSMutableDictionary<NSString *, NSNumber *> *_imageRequestIDs;
    NSMutableDictionary<NSString *, NSNumber *> *_videoRequestIDs;
    NSMutableDictionary<NSString *, AVAssetExportSession *> *_exportSessions;//当前正在导出session
    XMLock _lock_image;
    XMLock _lock_video;
    XMLock _lock_assets;
    XMLock _lock_filename;
    
    NSUInteger _exportedCount;
    XMLock _lock_exported;
}

- (instancetype)initWithCacheDir:(NSString *)cacheDir
{
    BOOL isDir = NO;
    NSAssert([[NSFileManager defaultManager] fileExistsAtPath:cacheDir isDirectory:&isDir] || !isDir, @"CacheDir does not exist!");//文件夹不存在
    
    self = [super init];
    if (self) {
        _cacheDir = cacheDir;
        _autoPauseWhenCompleteNumber = 4;
        _exportedCount = 0;
        _videoExportPreset = AVAssetExportPresetPassthrough;
        _assets = [NSMutableArray arrayWithCapacity:5];
        _imageRequestIDs = [NSMutableDictionary dictionaryWithCapacity:3];
        _videoRequestIDs = [NSMutableDictionary dictionaryWithCapacity:2];
        _exportSessions = [NSMutableDictionary dictionaryWithCapacity:2];
        _lock_image = XM_CreateLock();
        _lock_video = XM_CreateLock();
        _lock_assets = XM_CreateLock();
        _lock_exported = XM_CreateLock();
        _lock_filename = XM_CreateLock();
    }
    return self;
}

#pragma mark - 外部方法
- (void)addPHAssets:(NSArray<PHAsset *> *)phassets
{
    [phassets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([obj hasNotStatus]) {
            obj.status = PHAssetStatusWaiting;
        }
    }];
    ArrayThreadSecureAddObjects(_lock_assets, _assets, phassets);
}

- (void)deletePHAssets:(NSArray<PHAsset *> *)phassets
{
    //检测有没正在导出的，若有，就取消
    PHImageManager *im = [PHImageManager defaultManager];
    NSMutableArray *imageIds = [NSMutableArray array];
    NSMutableArray *videoIds = [NSMutableArray array];
    NSMutableArray *sessions = [NSMutableArray array];
    XM_Lock(_lock_image);
    XM_Lock(_lock_video);
    [phassets enumerateObjectsUsingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSNumber *rid = self->_imageRequestIDs[obj.localIdentifier];
        if (nil != rid) {
            [im cancelImageRequest:rid.intValue];
            [imageIds addObject:obj.localIdentifier];
        }
        rid = self->_videoRequestIDs[obj.localIdentifier];
        if (nil != rid) {
            [im cancelImageRequest:rid.intValue];
            [videoIds addObject:obj.localIdentifier];
        }
        AVAssetExportSession *es = self->_exportSessions[obj.localIdentifier];
        if (nil != es) {
            [es cancelExport];
            [sessions addObject:obj.localIdentifier];
        }
        [obj clearStatus];
    }];
    [_imageRequestIDs removeObjectsForKeys:imageIds];
    [_videoRequestIDs removeObjectsForKeys:videoIds];
    [_exportSessions removeObjectsForKeys:sessions];
    XM_UnLock(_lock_video);
    XM_UnLock(_lock_image);
    ArrayThreadSecureDeleteObjects(_lock_assets, _assets, phassets);
}

- (void)startRequest
{
    XM_Lock(_lock_exported);
    _isAutoPaused = NO;
    _exportedCount = 0;
    XM_UnLock(_lock_exported);
    
    XM_Lock(_lock_image);
    NSUInteger count = _imageRequestIDs.count;
    XM_UnLock(_lock_image);
    XM_Lock(_lock_video);
    NSUInteger videoCount = _videoRequestIDs.count + _exportSessions.count;
    XM_UnLock(_lock_video);
    if (count < ImageMaxConcurrent || videoCount < VideoMaxConcurrent) [self concurrentExportAssets];//没有达到最大并发数
}

- (void)stopRequest
{
    XM_Lock(_lock_assets);
    [_assets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj clearStatus];
    }];
    [_assets removeAllObjects];
    XM_UnLock(_lock_assets);
    
    [self cancelAll];
}

- (void)pause:(PHAsset *)asset
{
    XM_Lock(_lock_assets);
    BOOL contains = [_assets containsObject:asset];
    XM_UnLock(_lock_assets);
    if (!contains) return;
    if (PHAssetStatusPaused == asset.status || PHAssetStatusCompleted == asset.status) return;
    
    asset.status = PHAssetStatusPaused;
    PHImageManager *im = [PHImageManager defaultManager];
    XM_Lock(_lock_image);
    NSNumber *rid = _imageRequestIDs[asset.localIdentifier];
    if (nil != rid) {
        [im cancelImageRequest:rid.intValue];
        [_imageRequestIDs removeObjectForKey:asset.localIdentifier];
    }
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    rid = _videoRequestIDs[asset.localIdentifier];
    if (nil != rid) {
        [im cancelImageRequest:rid.intValue];
        [_videoRequestIDs removeObjectForKey:asset.localIdentifier];
    }
    AVAssetExportSession *es = _exportSessions[asset.localIdentifier];
    if (nil != es) {
        [es cancelExport];
        [_exportSessions removeObjectForKey:asset.localIdentifier];
    }
    XM_UnLock(_lock_video);
}

- (void)pauseAll
{
    XM_Lock(_lock_assets);
    [_assets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (PHAssetStatusExporting == obj.status || PHAssetStatusWaiting == obj.status) {
            obj.status = PHAssetStatusPaused;
        }
    }];
    XM_UnLock(_lock_assets);
    
    [self cancelAll];
}

- (void)resume:(PHAsset *)asset
{
    XM_Lock(_lock_assets);
    BOOL contains = [_assets containsObject:asset];
    XM_UnLock(_lock_assets);
    if (!contains) return;
    if (PHAssetStatusPaused != asset.status) return;
    
    asset.status = PHAssetStatusWaiting;
    XM_Lock(_lock_image);
    NSUInteger count = _imageRequestIDs.count;
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    NSUInteger videoCount = _videoRequestIDs.count + _exportSessions.count;
    XM_UnLock(_lock_video);
    
    if (count < ImageMaxConcurrent || videoCount < VideoMaxConcurrent) [self concurrentExportAssets];//没有达到最大并发数
}

- (void)resumeAll
{
    XM_Lock(_lock_assets);
    [_assets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (PHAssetStatusPaused == obj.status) {
            obj.status = PHAssetStatusWaiting;
        }
    }];
    XM_UnLock(_lock_assets);
    
    [self concurrentExportAssets];
}

#pragma mark - 内部方法
- (void)cancelAll
{
    PHImageManager *im = [PHImageManager defaultManager];
    XM_Lock(_lock_image);
    [_imageRequestIDs enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSString * _Nonnull key, NSNumber * _Nonnull obj, BOOL * _Nonnull stop) {
        [im cancelImageRequest:obj.intValue];
    }];
    [_imageRequestIDs removeAllObjects];
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    [_videoRequestIDs enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSString * _Nonnull key, NSNumber * _Nonnull obj, BOOL * _Nonnull stop) {
        [im cancelImageRequest:obj.intValue];
    }];
    [_videoRequestIDs removeAllObjects];
    
    [_exportSessions enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSString * _Nonnull key, AVAssetExportSession * _Nonnull obj, BOOL * _Nonnull stop) {
        [obj cancelExport];
    }];
    [_exportSessions removeAllObjects];
    XM_UnLock(_lock_video);
}

- (void)deleteImageRequestIdForKey:(NSString *)key
{
    DictionaryThreadSecureDeleteObjectForKey(_lock_image, _imageRequestIDs, key);
}

- (void)deleteVideoRequestIdForKey:(NSString *)key
{
    DictionaryThreadSecureDeleteObjectForKey(_lock_video, _videoRequestIDs, key);
}

- (void)deleteExportSessionForKey:(NSString *)key
{
    DictionaryThreadSecureDeleteObjectForKey(_lock_video, _exportSessions, key);
}

- (void)deleteExportingPHAsset:(PHAsset *)asset
{
    if (PHAssetStatusExporting == asset.status) {
        [asset clearStatus];
        ArrayThreadSecureDeleteObject(_lock_assets, _assets, asset);
    }
}

- (void)incrementExportedCount
{
    XM_Lock(_lock_exported);
    ++_exportedCount;
    if (_autoPauseWhenCompleteNumber > 0) {
        _isAutoPaused = _exportedCount >= _autoPauseWhenCompleteNumber;
    }
    XM_UnLock(_lock_exported);
}

- (void)decrementExportedCount
{
    XM_Lock(_lock_exported);
    --_exportedCount;
    if (_autoPauseWhenCompleteNumber > 0) {
        _isAutoPaused = _exportedCount >= _autoPauseWhenCompleteNumber;
    }
    XM_UnLock(_lock_exported);
}

#pragma mark - 导出，自动操作
static int const ImageMaxConcurrent = 2;//图片导出最大并发数
static int const VideoMaxConcurrent = 1;//视频导出最大并发数

/**
 并发导出
 */
- (void)concurrentExportAssets
{
    XM_Lock(_lock_assets);
    NSUInteger concurrentCount = ImageMaxConcurrent + VideoMaxConcurrent;//总并发数
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:concurrentCount];
    PHAsset *asset = nil;
    //挑选等待中的
    for (NSUInteger i = 0, count = _assets.count; i < count; ++i) {
        asset = _assets[i];
        if (PHAssetStatusWaiting == asset.status) {
            [arr addObject:asset];
            if (arr.count >= concurrentCount) {
                break;
            }
        }
    }
    XM_UnLock(_lock_assets);
    [arr enumerateObjectsUsingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self exportAsset:obj];
    }];
}

/**
 单个导出，当asset为nil时，默认会从_assets挑选一个

 @param asset PHAsset
 */
- (void)exportAsset:(PHAsset *)asset
{
    XM_Lock(_lock_exported);
    if (_autoPauseWhenCompleteNumber > 0) {
        _isAutoPaused = _exportedCount >= _autoPauseWhenCompleteNumber;
    }
    XM_UnLock(_lock_exported);
    if (_isAutoPaused) return;
    
    if (nil == asset) {
        XM_Lock(_lock_assets);
        for (NSUInteger i = 0, count = _assets.count; i < count; ++i) {
            asset = _assets[i];
            if (PHAssetStatusWaiting == asset.status) {//没有暂停
                break;
            }
            asset = nil;
        }
        XM_UnLock(_lock_assets);
    }
    if (nil == asset || PHAssetStatusWaiting != asset.status) return;
    
    if (asset.mediaType == PHAssetMediaTypeImage) {
        XM_Lock(_lock_image);
        NSUInteger count = _imageRequestIDs.count;
        XM_UnLock(_lock_image);
        if (count >= ImageMaxConcurrent) return;
    } else if (asset.mediaType == PHAssetMediaTypeVideo) {
        XM_Lock(_lock_video);
        NSUInteger videoCount = _videoRequestIDs.count + _exportSessions.count;
        XM_UnLock(_lock_video);
        if (videoCount >= VideoMaxConcurrent) return;
    }
    asset.status = PHAssetStatusExporting;
    
    if (asset.mediaType == PHAssetMediaTypeImage) {
        [self exportImageAsset:asset];
    } else if (asset.mediaType == PHAssetMediaTypeVideo) {
        [self exportVideoAsset:asset];
    }
}

//获取缓存绝对路径
- (NSString *)absolutePathForCachePHAsset:(PHAsset *)asset
{
    NSString *filename = [asset valueForKey:@"filename"];
//    NSString *filename = [PHAssetResource assetResourcesForAsset:asset].firstObject.originalFilename;
    BOOL isDir = YES;
    NSString *absolutePath = [_cacheDir stringByAppendingPathComponent:filename];
    NSFileManager *fm = [NSFileManager defaultManager];
    XM_Lock(_lock_filename);
    if ([fm fileExistsAtPath:absolutePath isDirectory:&isDir] && !isDir) {
        //获得文件名(不带后缀)
        NSString *name = [filename stringByDeletingPathExtension];
        //获得文件的后缀名(不带'.')
        NSString *suffix = [filename pathExtension];
        NSString *format = nil;
        if (nil == suffix || suffix.length == 0) {
            format = [name stringByAppendingString:@"(%lu)"];
//            suffix = @"";
        } else {
            format = [name stringByAppendingFormat:@"(%@).%@", @"%lu", suffix];
//            suffix = [@"." stringByAppendingString:suffix];
        }
        for (NSUInteger i = 0; i <= NSUIntegerMax; ++i) {
            filename = [NSString stringWithFormat:format, (unsigned long)i];
//            filename = [NSString stringWithFormat:@"%@(%lu)%@", name, (unsigned long)i, suffix];
            absolutePath = [_cacheDir stringByAppendingPathComponent:filename];
            if (!([fm fileExistsAtPath:absolutePath isDirectory:&isDir] && !isDir)) {
                break;
            }
        }
    }
    XM_UnLock(_lock_filename);
    return absolutePath;
}

- (void)exportImageAsset:(PHAsset *)asset
{
    __weak typeof(self) this = self;
    [this incrementExportedCount];
    PHImageRequestID requestId = [[PHImageManager defaultManager] requestImageDataForAsset:asset options:_imageOptions resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, UIImageOrientation orientation, NSDictionary * _Nullable info) {
        [this deleteImageRequestIdForKey:asset.localIdentifier];
        [this deleteExportingPHAsset:asset];
        
        //1、是否取消
        if ([info[PHImageCancelledKey] boolValue]) {
            [this decrementExportedCount];
            [this exportAsset:nil];//导出下一个
            return;//取消
        }
        asset.status = PHAssetStatusCompleted;
        id<XMPhotosRequestManagerDelegate> delegate = this.delegate;
        NSError *error = info[PHImageErrorKey];
        //2、有导出错误
        if (nil != error) {
//            NSLog(@"Image ExportFailed: %@", info[PHImageErrorKey]);
            [this decrementExportedCount];
            if ([delegate respondsToSelector:@selector(manager:exportFailed:error:)]) {
                [delegate manager:this exportFailed:asset error:error];
            }
            [this exportAsset:nil];//导出下一个
            return;//取消
        }
        
        //3、没有导出错误
        //
        if ([delegate respondsToSelector:@selector(manager:editImageData:asset:dataUTI:orientation:)]) {
            NSData *data = [delegate manager:this editImageData:imageData asset:asset dataUTI:dataUTI orientation:orientation];
            if (nil != data) imageData = data;
        }
        
        NSString *cachePath = [this absolutePathForCachePHAsset:asset];
        //4、是否保存到磁盘出错
        error = nil;
        BOOL hasError = ![imageData writeToFile:cachePath options:NSDataWritingAtomic error:&error];
        if (hasError) {
//            NSLog(@"Image ExportFailed: writeToFile fail");
            [this decrementExportedCount];
            [[NSFileManager defaultManager] removeItemAtPath:cachePath error:NULL];
            if ([delegate respondsToSelector:@selector(manager:exportFailed:error:)]) {
                [delegate manager:this exportFailed:asset error:error];
            }
        } else {
//            NSLog(@"Image ExportCompleted");
            if ([delegate respondsToSelector:@selector(manager:exportCompleted:cachePath:)]) {
                [delegate manager:this exportCompleted:asset cachePath:cachePath];
            }
        }
        [this exportAsset:nil];//导出下一个
    }];
    DictionaryThreadSecureSetObjectForKey(_lock_image, _imageRequestIDs, asset.localIdentifier, @(requestId));
}

- (void)exportVideoAsset:(PHAsset *)asset
{//AVAssetExportPresetHighestQuality
    __weak typeof(self) this = self;
    [this incrementExportedCount];
    PHImageRequestID requestId = [[PHImageManager defaultManager] requestExportSessionForVideo:asset options:_videoOptions exportPreset:_videoExportPreset resultHandler:^(AVAssetExportSession * _Nullable exportSession, NSDictionary * _Nullable info) {
        [this deleteVideoRequestIdForKey:asset.localIdentifier];
        //1、是否取消
        if ([info[PHImageCancelledKey] boolValue]) {
            [this decrementExportedCount];
            [this exportAsset:nil];//导出下一个
            return;
        }
        
        id<XMPhotosRequestManagerDelegate> delegate = this.delegate;
        //2、有导出错误
        NSError *error = info[PHImageErrorKey];
        if (nil != error) {
//            NSLog(@"Video ExportFailed: %@", info[PHImageErrorKey]);
            [this deleteExportingPHAsset:asset];
            [this decrementExportedCount];
            asset.status = PHAssetStatusCompleted;
            if ([delegate respondsToSelector:@selector(manager:exportFailed:error:)]) {
                [delegate manager:this exportFailed:asset error:error];
            }
            [this exportAsset:nil];//导出下一个
            return;
        }
        
        //3、设置参数
        exportSession.shouldOptimizeForNetworkUse = YES;//为网络播放做优化
        exportSession.outputFileType = AVFileTypeMPEG4;//输出的文件格式mp4
        if ([delegate respondsToSelector:@selector(manager:customPropertyForExportSession:)]) {
            [delegate manager:this customPropertyForExportSession:exportSession];
        }
        
        exportSession.outputURL = [NSURL fileURLWithPath:[this absolutePathForCachePHAsset:asset]];//导出地址
        //4、开始导出
        [this startExportSession:exportSession PHAsset:asset];
    }];
    DictionaryThreadSecureSetObjectForKey(_lock_video, _videoRequestIDs, asset.localIdentifier, @(requestId));
}

- (void)startExportSession:(AVAssetExportSession *)exportSession PHAsset:(PHAsset *)asset
{
    DictionaryThreadSecureSetObjectForKey(_lock_video, _exportSessions, asset.localIdentifier, exportSession);
    __weak typeof(exportSession) es = exportSession;
    __weak typeof(self) this = self;
    //启动导出
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        [this deleteExportSessionForKey:asset.localIdentifier];
        [this deleteExportingPHAsset:asset];
        
        id<XMPhotosRequestManagerDelegate> delegate = this.delegate;
        switch (es.status) {
            case AVAssetExportSessionStatusCompleted:
//                NSLog(@"Video ExportCompleted");
                asset.status = PHAssetStatusCompleted;
                if ([delegate respondsToSelector:@selector(manager:exportCompleted:cachePath:)]) {
                    [delegate manager:this exportCompleted:asset cachePath:es.outputURL.path];
                }
                break;
                
            case AVAssetExportSessionStatusFailed:
//                NSLog(@"Video ExportFailed: %@", es.error);
                [this decrementExportedCount];
                asset.status = PHAssetStatusCompleted;
                [[NSFileManager defaultManager] removeItemAtURL:es.outputURL error:NULL];
                if ([delegate respondsToSelector:@selector(manager:exportFailed:error:)]) {
                    [delegate manager:this exportFailed:asset error:es.error];
                }
                break;
                
            case AVAssetExportSessionStatusCancelled:
                [this decrementExportedCount];
                [[NSFileManager defaultManager] removeItemAtURL:es.outputURL error:NULL];
                break;
                
            default:break;//其它的类型不会在此block中出现
        }
        
        [this exportAsset:nil];
    }];
}

+ (BOOL)isHEIF:(PHAsset *)phAsset
{
    __block BOOL isHEIF = NO;
    if (@available(iOS 11.0, *)) {
        [[PHAssetResource assetResourcesForAsset:phAsset] enumerateObjectsUsingBlock:^(PHAssetResource * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *UTI = obj.uniformTypeIdentifier;
            if ([UTI isEqualToString:@"public.heif"] || [UTI isEqualToString:@"public.heic"]) {
                isHEIF = YES;
                *stop = YES;
            }
        }];
    }/* else {//小于iOS11就返回NO
        NSString *UTI = [phAsset valueForKey:@"uniformTypeIdentifier"];
        isHEIF = [UTI isEqualToString:@"public.heif"] || [UTI isEqualToString:@"public.heic"];
        
    }*/
    return isHEIF;
}

@end
