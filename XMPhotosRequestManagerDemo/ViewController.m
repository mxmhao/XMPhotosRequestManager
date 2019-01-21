//
//  ViewController.m
//  XMPhotosRequestManager
//
//  Created by noontec on 2018/5/2.
//  Copyright © 2018年 mxm. All rights reserved.
//

#import "ViewController.h"
#import <Photos/Photos.h>
#import "XMPhotosRequestManager.h"

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, XMPhotosRequestManagerDelegate>
{
    PHFetchResult<PHAsset *> *_result;
    XMPhotosRequestManager *_prm;
}

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    _result = [PHAsset fetchAssetsWithOptions:nil];
    NSLog(@"count: %lu", (unsigned long)_result.count);
    
    _prm = [[XMPhotosRequestManager alloc] initWithCacheDir:NSTemporaryDirectory()];
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:_result.count];
    
    NSMutableArray *arr1 = [NSMutableArray arrayWithCapacity:_result.count];
    for (NSUInteger i = 0, count = _result.count; i < count; ++i) {
        [arr addObject:_result[i]];
        [arr1 addObject:_result[i].localIdentifier];
//        NSLog(@"%@", _result[i].localIdentifier);
    }
    [arr1 removeObjectsInRange:NSMakeRange(0, 7)];
    [arr1 exchangeObjectAtIndex:0 withObjectAtIndex:1];
    NSLog(@"%@", arr1);
    
    [_prm addPHAssets:arr];
    _prm.delegate = self;
    PHImageRequestOptions *iOptions = [PHImageRequestOptions new];
    
    iOptions.version = PHImageRequestOptionsVersionCurrent;
    iOptions.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
    iOptions.resizeMode = PHImageRequestOptionsResizeModeExact;
    _prm.imageOptions = iOptions;
    
    PHVideoRequestOptions *vOptions = [PHVideoRequestOptions new];
    vOptions.version = PHVideoRequestOptionsVersionCurrent;
    vOptions.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    _prm.videoOptions = vOptions;
    
    [_prm startRequest];
    
    [arr removeAllObjects];
    [[PHAsset fetchAssetsWithLocalIdentifiers:arr1 options:nil] enumerateObjectsUsingBlock:^(PHAsset * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSLog(@"%lu", (unsigned long)idx);
        [arr addObject:obj.localIdentifier];
    }];
    NSLog(@"%@", arr);
    NSLog(@"%d", [arr isEqualToArray:arr1]);
    
//    NSMutableArray;
//    NSMutableDictionary;
//    NSMutableSet;
//    NSMutableOrderedSet;
//    NSHashTable;
//    NSMapTable;
//    NSPointerArray;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _result.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *const identifier = @"cellIdentifier";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    cell.textLabel.text = [_result[indexPath.row] valueForKey:@"filename"];
    cell.detailTextLabel.text = _result[indexPath.row].localIdentifier;
    
    return cell;
}

#pragma mark - XMPhotosRequestManager delegate
- (void)manager:(XMPhotosRequestManager *)manager exportCompleted:(PHAsset *)asset cachePath:(NSString *)cachePath
{
    static int count = 0;
    ++count;
//    NSLog(@"\n%d, %@ 导出：%f, -- isMain: %d", count, [asset valueForKey:@"filename"], CACurrentMediaTime(), [NSThread isMainThread]);
    [[NSFileManager defaultManager] removeItemAtPath:cachePath error:NULL];
    if (manager.isAutoPaused) {
        [manager startRequest];
    }
}

- (void)manager:(XMPhotosRequestManager *)manager customPropertyForExportSession:(AVAssetExportSession *)exportSession
{
    exportSession.outputFileType = AVFileTypeMPEG4;
//    NSLog(@"设置exportSession");
}

- (NSData *)manager:(XMPhotosRequestManager *)manager editImageData:(NSData *)imageData asset:(PHAsset *)asset dataUTI:(NSString *)dataUTI orientation:(UIImageOrientation)orientation
{
//    NSLog(@"编辑imageData");
    return nil;
}

- (void)manager:(XMPhotosRequestManager *)manager exportFailed:(PHAsset *)asset error:(NSError *)error
{
//    NSLog(@"导出失败：%@", error);
}

@end
