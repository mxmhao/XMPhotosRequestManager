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
    PHAssetStatusExporting,
    PHAssetStatusPaused,
    PHAssetStatusCompleted
};

@interface PHAsset (AbsolutPath)

@property (nonatomic, assign) PHAssetStatus status;//状态
@property (nonatomic, strong) NSNumber *rid;//请求id

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

- (void)setRid:(NSNumber *)rid
{
    objc_setAssociatedObject(self, @selector(rid), rid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber *)rid
{
    return objc_getAssociatedObject(self, @selector(rid));
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
    NSMutableArray<NSNumber *> *_imageRequestIDs;
    NSMutableArray<NSNumber *> *_videoRequestIDs;
    NSMutableDictionary<NSNumber *, AVAssetExportSession *> *_exportSessions;//当前正在导出session
    XMLock _lock_image;
    XMLock _lock_video;
    XMLock _lock_asset;
    XMLock _lock_filename;
    
    NSUInteger _exportedCount;
    XMLock _lock_exported;
    NSFileManager *_fm;
    
    CIContext *_ciContext;
}

- (CIContext *)cicontext
{
    return _ciContext;
}

- (instancetype)initWithCacheDir:(NSString *)cacheDir
{
    BOOL isDir = NO;
    NSAssert([[NSFileManager defaultManager] fileExistsAtPath:cacheDir isDirectory:&isDir] || !isDir, @"CacheDir does not exist!");//文件夹不存在
    
    self = [super init];
    if (self) {
        _cacheDir = [cacheDir copy];
        _autoPauseWhenCompleteNumber = 4;
        _exportedCount = 0;
        _videoExportPreset = AVAssetExportPresetPassthrough;
        _assets = [NSMutableArray arrayWithCapacity:5];
        _imageRequestIDs = [NSMutableArray arrayWithCapacity:3];
        _videoRequestIDs = [NSMutableArray arrayWithCapacity:2];
        _exportSessions = [NSMutableDictionary dictionaryWithCapacity:2];
        _lock_image = XM_CreateLock();
        _lock_video = XM_CreateLock();
        _lock_asset = XM_CreateLock();
        _lock_exported = XM_CreateLock();
        _lock_filename = XM_CreateLock();
        
        _fm = [NSFileManager defaultManager];
//        _queue = dispatch_queue_create("com.xm_prm.queue", DISPATCH_QUEUE_SERIAL);//串行队列
    }
    return self;
}

#pragma mark - 外部方法
- (void)addPHAssets:(NSArray<PHAsset *> *)phassets
{
    if (nil == phassets || phassets.count == 0) return;
    for (PHAsset *asset in phassets) {
        if ([asset hasNotStatus]) {
            asset.status = PHAssetStatusWaiting;
        }
    }
    XM_OnThreadSafe(_lock_asset, [_assets addObjectsFromArray:phassets]);
}

- (void)deletePHAssets:(NSArray<PHAsset *> *)phassets
{
    if (nil == phassets || phassets.count == 0) return;
    //检测有没正在导出的，若有，就取消
    PHImageManager *im = [PHImageManager defaultManager];
    NSMutableArray *imageIds = [NSMutableArray array];
    NSMutableArray *videoIds = [NSMutableArray array];
    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableIndexSet *mis = [NSMutableIndexSet indexSet];
    
    NSIndexSet *is = nil;
    for (PHAsset *asset in phassets) {
        NSNumber *rid = asset.rid;
        if (nil == rid) continue;
        
        AVAssetExportSession *es = _exportSessions[rid];
        if (nil != es) {
            [es cancelExport];
            [sessions addObject:rid];
        }
        [asset clearStatus];
        XM_Lock(_lock_asset);
        is = [_assets indexesOfObjectsPassingTest:^BOOL(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            *stop = obj == asset;
            return *stop;
        }];
        if (nil != is && is.count > 0) {
            [mis addIndexes:is];
        }
        XM_UnLock(_lock_asset);
        
        if (asset.mediaType == PHAssetMediaTypeImage) {
            [im cancelImageRequest:rid.intValue];
            [imageIds addObject:rid];
            continue;
        }
        if (asset.mediaType == PHAssetMediaTypeVideo) {
            [im cancelImageRequest:rid.intValue];
            [videoIds addObject:rid];
        }
    }
    
    XM_OnThreadSafe(_lock_asset, [_assets removeObjectsAtIndexes:mis]);//remove
    XM_OnThreadSafe(_lock_image, [_imageRequestIDs removeObjectsInArray:imageIds]);
    XM_Lock(_lock_video);
    [_videoRequestIDs removeObjectsInArray:videoIds];
    [_exportSessions removeObjectsForKeys:sessions];
    XM_UnLock(_lock_video);
}

- (void)startRequest
{
    XM_Lock(_lock_exported);
    _isAutoPaused = NO;
    _exportedCount = 0;
    XM_UnLock(_lock_exported);
    [self concurrentExportAssets];
}

- (void)stopRequest
{
    [self cancelAll];
    
    XM_Lock(_lock_asset);
    for (PHAsset * asset in _assets) {
        [asset clearStatus];
    }
    [_assets removeAllObjects];
    XM_UnLock(_lock_asset);
}

- (void)pause:(PHAsset *)asset
{
    XM_Lock(_lock_asset);
    BOOL contains = NO;
    for (PHAsset *obj in _assets) {
        if (obj == asset) {
            contains = YES;
            break;
        }
    }
    XM_UnLock(_lock_asset);
    if (!contains || PHAssetStatusPaused == asset.status || PHAssetStatusCompleted == asset.status) return;
    
    asset.status = PHAssetStatusPaused;
    PHImageManager *im = [PHImageManager defaultManager];
    XM_Lock(_lock_image);
    NSNumber *rid = asset.rid;
    if (nil != rid) {
        [_imageRequestIDs removeObject:rid];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [im cancelImageRequest:rid.intValue];//貌似主线程调用会与其回调block形成死锁
        });
    }
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    rid = asset.rid;
    if (nil != rid) {
        [_videoRequestIDs removeObject:rid];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [im cancelImageRequest:rid.intValue];//貌似主线程调用会与其回调block形成死锁
        });
    }
    
    AVAssetExportSession *es = _exportSessions[asset.rid];
    if (nil != es) {
        [_exportSessions removeObjectForKey:asset.rid];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [es cancelExport];//貌似主线程调用会与其回调block形成死锁
        });
    }
    XM_UnLock(_lock_video);
}

- (void)pauseAll
{//这里的顺序不能变
    XM_Lock(_lock_asset);
    [_assets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (PHAssetStatusExporting == obj.status || PHAssetStatusWaiting == obj.status) {
            obj.status = PHAssetStatusPaused;
        }
    }];
    XM_UnLock(_lock_asset);
    
    [self cancelAll];
}

- (void)resume:(PHAsset *)asset
{
    XM_Lock(_lock_asset);
    BOOL contains = NO;
    for (PHAsset *obj in _assets) {
        if (obj == asset) {
            contains = YES;
            break;
        }
    }
    XM_UnLock(_lock_asset);
    if (!contains || PHAssetStatusPaused != asset.status) return;
    
    asset.status = PHAssetStatusWaiting;
    [self concurrentExportAssets];
}

- (void)resumeAll
{
    XM_Lock(_lock_asset);
    [_assets enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (PHAssetStatusPaused == obj.status) {
            obj.status = PHAssetStatusWaiting;
        }
    }];
    XM_UnLock(_lock_asset);
    
    [self concurrentExportAssets];
}

#pragma mark - 内部方法
- (void)cancelAll
{
    PHImageManager *im = [PHImageManager defaultManager];
    XM_Lock(_lock_image);
    for (NSNumber *num in _imageRequestIDs) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [im cancelImageRequest:num.intValue];//貌似主线程调用会与其回调block形成死锁
        });
    }
    [_imageRequestIDs removeAllObjects];
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    for (NSNumber *num in _videoRequestIDs) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [im cancelImageRequest:num.intValue];//貌似主线程调用会与其回调block形成死锁
        });
    }
    [_videoRequestIDs removeAllObjects];
    
    [_exportSessions enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSNumber * _Nonnull key, AVAssetExportSession * _Nonnull obj, BOOL * _Nonnull stop) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [obj cancelExport];//貌似主线程调用会与其回调block形成死锁
        });
    }];
    [_exportSessions removeAllObjects];
    XM_UnLock(_lock_video);
}

- (void)deleteImageRequestId:(NSNumber *)num
{
    XM_OnThreadSafe(_lock_image, [_imageRequestIDs removeObject:num]);
}

- (void)deleteVideoRequestId:(NSNumber *)num
{
    XM_OnThreadSafe(_lock_video, [_videoRequestIDs removeObject:num]);
}

- (void)deleteExportSessionForKey:(NSNumber *)key
{
    XM_OnThreadSafe(_lock_video, [_exportSessions removeObjectForKey:key]);
}

- (void)deleteExportingPHAsset:(PHAsset *)asset
{
    if (PHAssetStatusExporting == asset.status) {
        [asset clearStatus];
        XM_Lock(_lock_asset);
        NSIndexSet *is = [_assets indexesOfObjectsPassingTest:^BOOL(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            *stop = obj == asset;
            return *stop;
        }];
        [_assets removeObjectsAtIndexes:is];
        XM_UnLock(_lock_asset);
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
    XM_Lock(_lock_image);
    NSUInteger icount = _imageRequestIDs.count;
    XM_UnLock(_lock_image);
    
    XM_Lock(_lock_video);
    NSUInteger vcount = _videoRequestIDs.count + _exportSessions.count;
    XM_UnLock(_lock_video);
    if (icount >= ImageMaxConcurrent && vcount >= VideoMaxConcurrent) return;
    
    XM_Lock(_lock_asset);
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
    XM_UnLock(_lock_asset);
    
    for (PHAsset *obj in arr) {
        [self exportAsset:obj];
    }
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
        XM_Lock(_lock_asset);
        for (NSUInteger i = 0, count = _assets.count; i < count; ++i) {
            asset = _assets[i];
            if (PHAssetStatusWaiting == asset.status) {//没有暂停
                break;
            }
            asset = nil;
        }
        XM_UnLock(_lock_asset);
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
    NSString *absolutePath = [_cacheDir stringByAppendingPathComponent:filename];
    XM_Lock(_lock_filename);
    BOOL exist = [_fm fileExistsAtPath:absolutePath];
    XM_UnLock(_lock_filename);
    if (!exist) return absolutePath;
    
    XM_Lock(_lock_filename);
    NSString *name = [filename stringByDeletingPathExtension];//获得文件名(不带后缀)
    NSString *suffix = [filename pathExtension];//获得文件的后缀名(不带'.')
    NSString *format = nil;
    if (nil == suffix || suffix.length == 0) {//没有后缀
        format = [name stringByAppendingString:@"(%lu)"];
    } else {
        format = [name stringByAppendingFormat:@"(%@).%@", @"%lu", suffix];
    }//format = @"name(%lu)" 或者 @"name(%lu).suffix"
    for (NSUInteger i = 0; i <= NSUIntegerMax; ++i) {
        filename = [NSString stringWithFormat:format, (unsigned long)i];
        absolutePath = [_cacheDir stringByAppendingPathComponent:filename];
        if (![_fm fileExistsAtPath:absolutePath]) {
            break;
        }
        filename = nil;
    }
//    if (nil == filename) {//那就只能用UUID做文件名了
//    }
    XM_UnLock(_lock_filename);
    
    return absolutePath;
}

- (void)exportImageAsset:(PHAsset *)asset
{
    [self incrementExportedCount];
    if ([_delegate respondsToSelector:@selector(manager:willRequest:)]) {
        [_delegate manager:self willRequest:asset];
    }
    __weak typeof(self) this = self;
    PHImageRequestID requestId = [[PHImageManager defaultManager] requestImageDataForAsset:asset options:_imageOptions resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, UIImageOrientation orientation, NSDictionary * _Nullable info) {
        [this deleteExportingPHAsset:asset];
        [this deleteImageRequestId:asset.rid];
        
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
        
        //如果是HEIF格式需要转码
        if (@available(iOS 11.0, *)) {
            if (this.convertPhotosInHeifToJPG && [XMPhotosRequestManager isHEIF:asset]) {
                CIImage *ciImage = [CIImage imageWithData:imageData];
                imageData = [this.cicontext JPEGRepresentationOfImage:ciImage colorSpace:ciImage.colorSpace options:@{}];
//            dataUTI = AVFileTypeJPEG;
            }
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
    asset.rid = @(requestId);
    XM_OnThreadSafe(_lock_image, [_imageRequestIDs addObject:asset.rid]);
}

- (void)exportVideoAsset:(PHAsset *)asset
{//AVAssetExportPresetHighestQuality
    [self incrementExportedCount];
    if ([_delegate respondsToSelector:@selector(manager:willRequest:)]) {
        [_delegate manager:self willRequest:asset];
    }
    __weak typeof(self) this = self;
    PHImageRequestID requestId = [[PHImageManager defaultManager] requestExportSessionForVideo:asset options:_videoOptions exportPreset:_videoExportPreset resultHandler:^(AVAssetExportSession * _Nullable exportSession, NSDictionary * _Nullable info) {
        [this deleteVideoRequestId:asset.rid];
        
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
        
        //4、开始导出
        [this startExportSession:exportSession PHAsset:asset];
    }];
    asset.rid = @(requestId);
    XM_OnThreadSafe(_lock_video, [_videoRequestIDs addObject:asset.rid]);
}

- (void)startExportSession:(AVAssetExportSession *)exportSession PHAsset:(PHAsset *)asset
{
    XM_OnThreadSafe(_lock_video, [_exportSessions setObject:exportSession forKey:asset.rid]);
    exportSession.outputURL = [NSURL fileURLWithPath:[self absolutePathForCachePHAsset:asset]];//导出地址
    __weak typeof(exportSession) es = exportSession;
    __weak typeof(self) this = self;
    //启动导出
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        [this deleteExportSessionForKey:asset.rid];
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
    BOOL isHEIF = NO;
    if (@available(iOS 11.0, *)) {
        NSArray *arr = [PHAssetResource assetResourcesForAsset:phAsset];
        NSString *UTI = nil;
        for (PHAssetResource *resource in arr) {
            UTI = resource.uniformTypeIdentifier;
            if ([UTI isEqualToString:AVFileTypeHEIF] || [UTI isEqualToString:AVFileTypeHEIC]) {
                isHEIF = YES;
                break;
            }
        }
    }/* else {//小于iOS11就返回NO
      NSString *UTI = [phAsset valueForKey:@"uniformTypeIdentifier"];
      isHEIF = [UTI isEqualToString:@"public.heif"] || [UTI isEqualToString:@"public.heic"];
      
      }*/
    return isHEIF;
}

- (void)readImageinfo:(NSData *)imageData
{
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    CFDictionaryRef imageProperty = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
    CFDictionaryRef exif = CFDictionaryGetValue(imageProperty, kCGImagePropertyExifDictionary);//获取图片的exif信息
    NSLog(@"%@", imageProperty);
    
    CFRelease(imageSource);
    CFRelease(imageProperty);
    CFRelease(exif);
}

/*
 - (NSData *)writeMeta:(NSData *)imageData with:(PHAsset *)asset
 {
 CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
 CFDictionaryRef imageProperty = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
 NSLog(@"old: %@", imageProperty);
 
 CFMutableDictionaryRef metaDataDict = NULL;
 CFStringRef date = (__bridge const CFStringRef)[_dft stringFromDate:asset.creationDate];
 
 //--------修改 exif 中的时间 -------------
 CFDictionaryRef exif = CFDictionaryGetValue(imageProperty, kCGImagePropertyExifDictionary);//获取图片的exif信息
 if (NULL == CFDictionaryGetValue(exif, kCGImagePropertyExifDateTimeOriginal)) {
 CFMutableDictionaryRef exifNew = CFDictionaryCreateMutableCopy(kCFAllocatorDefault,  CFDictionaryGetCount(exif), exif);
 CFDictionarySetValue(exifNew, kCGImagePropertyExifDateTimeOriginal, date);
 CFDictionarySetValue(exifNew, kCGImagePropertyExifDateTimeDigitized, date);
 
 metaDataDict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault,  CFDictionaryGetCount(imageProperty), imageProperty);
 CFDictionarySetValue(metaDataDict, kCGImagePropertyExifDictionary, exifNew);
 CFRelease(exifNew);
 }
 
 //------------修改 tiff 中的时间------------
 CFDictionaryRef tiff = CFDictionaryGetValue(imageProperty, kCGImagePropertyTIFFDictionary);//获取图片的exif信息
 if (NULL == CFDictionaryGetValue(tiff, kCGImagePropertyTIFFDateTime)) {
 CFMutableDictionaryRef tiffNew = CFDictionaryCreateMutableCopy(kCFAllocatorDefault,  CFDictionaryGetCount(tiff), tiff);
 CFDictionarySetValue(tiffNew, kCGImagePropertyTIFFDateTime, date);
 
 if (NULL == metaDataDict) {
 metaDataDict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault,  CFDictionaryGetCount(imageProperty), imageProperty);
 }
 CFDictionarySetValue(metaDataDict, kCGImagePropertyTIFFDictionary, tiffNew);
 CFRelease(tiffNew);
 }
 
 //-------------------生成图片------------------------
 CFRelease(imageProperty);
 if (NULL == metaDataDict) {
 CFRelease(imageSource);
 return imageData;
 }
 NSLog(@"new: %@", metaDataDict);
 CFStringRef UTI = CGImageSourceGetType(imageSource);
 NSMutableData *newImageData = [NSMutableData data];
 CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)newImageData, UTI, 1,NULL);
 
 CGImageDestinationAddImageFromSource(destination, imageSource, 0, metaDataDict);
 CGImageDestinationFinalize(destination);
 
 //
 CFRelease(imageSource);
 CFRelease(metaDataDict);
 CFRelease(destination);
 
 return newImageData;
 }*/

@end
