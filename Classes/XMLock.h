//
//  XMLock.h
//  XMLock
//
//  Created by mxmhao on 2018/1/16.
//  Copyright © 2018年 mxm. All rights reserved.
//

#ifndef XMLock_h
#define XMLock_h

#import <Foundation/Foundation.h>

#define XM_CreateLock() dispatch_semaphore_create(1)
#define XM_Lock(x) dispatch_semaphore_wait(x, DISPATCH_TIME_FOREVER)
#define XM_UnLock(x) dispatch_semaphore_signal(x)

typedef dispatch_semaphore_t XMLock;

#pragma mark - 通用

/**
 NSMutableArray, NSMutableDictionary, NSMutableSet, <br/>NSMutableOrderedSet, NSHashTable, NSMapTable;
 以上类可以使用

 @param lock XMLock
 @param obj 实例集合类型
 */
NS_INLINE
void RemoveAllObjectsOnThreadSecure(XMLock lock, id obj)
{
    XM_Lock(lock);
    [obj removeAllObjects];
    XM_UnLock(lock);
}

#pragma mark - NSMutableArray
//线程安全，数组删除实例
NS_INLINE
void ArrayThreadSecureDeleteObject(XMLock lock, NSMutableArray *arr, id obj)
{
    XM_Lock(lock);
    [arr removeObject:obj];
    XM_UnLock(lock);
}

NS_INLINE
void ArrayThreadSecureDeleteObjects(XMLock lock, NSMutableArray *arr, NSArray *objs)
{
    XM_Lock(lock);
    [arr removeObjectsInArray:objs];
    XM_UnLock(lock);
}

//线程安全，数组添加实例
NS_INLINE
void ArrayThreadSecureAddObject(XMLock lock, NSMutableArray *arr, id obj)
{
    XM_Lock(lock);
    [arr addObject:obj];
    XM_UnLock(lock);
}

NS_INLINE
void ArrayThreadSecureAddObjects(XMLock lock, NSMutableArray *arr, NSArray *objs)
{
    XM_Lock(lock);
    [arr addObjectsFromArray:objs];
    XM_UnLock(lock);
}

#pragma mark - NSMutableDictionary
//线程安全，字典删除实例
NS_INLINE
void DictionaryThreadSecureDeleteObjectForKey(XMLock lock, NSMutableDictionary *dic, id key)
{
    XM_Lock(lock);
    [dic removeObjectForKey:key];
    XM_UnLock(lock);
}

NS_INLINE
void DictionaryThreadSecureDeleteObjectsForKeys(XMLock lock, NSMutableDictionary *dic, NSArray *keys)
{
    XM_Lock(lock);
    [dic removeObjectsForKeys:keys];
    XM_UnLock(lock);
}

//线程安全，字典添加实例
NS_INLINE
void DictionaryThreadSecureSetObjectForKey(XMLock lock, NSMutableDictionary *dic, id key, id obj)
{
    XM_Lock(lock);
    dic[key] = obj;
    XM_UnLock(lock);
}

#endif /* XMLock_h */
