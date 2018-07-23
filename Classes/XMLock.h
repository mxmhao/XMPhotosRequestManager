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
 清空obj的数据
 
 @param lock XMLock
 @param obj NSMutableArray, NSMutableDictionary, NSMutableSet, <br/>NSMutableOrderedSet, NSHashTable, NSMapTable, NSCache
 */
NS_INLINE
void RemoveAllObjectsOnThreadSecure(XMLock lock, id obj)
{
    XM_Lock(lock);
    [obj removeAllObjects];
    XM_UnLock(lock);
}


/**
 删除集合arr的obj
 
 @param lock XMLock
 @param arr NSMutableArray, NSMutableSet, NSMutableOrderedSet, <br/>NSHashTable, NSCountedSet
 @param obj 要删除的obj
 */
NS_INLINE
void RemoveObjectOnThreadSecure(XMLock lock, id arr, id obj)
{
    XM_Lock(lock);
    [arr removeObject:obj];
    XM_UnLock(lock);
}

/**
 集合arr添加obj
 
 @param lock XMLock
 @param arr NSMutableArray, NSMutableSet, NSMutableOrderedSet, <br/>NSHashTable, NSCountedSet, NSAutoreleasePool
 @param obj 要添加的obj
 */
NS_INLINE
void AddObjectOnThreadSecure(XMLock lock, id arr, id obj)
{
    XM_Lock(lock);
    [arr addObject:obj];
    XM_UnLock(lock);
}

//NSUserDefaults是线程安全的，不要使用此方法
/**
 根据key删除obj
 
 @param lock XMLock
 @param dic NSMutableDictionary, NSMapTable, NSCache, <br/>NSUbiquitousKeyValueStore
 @param key 键
 */
NS_INLINE
void RemoveObjectForKeyOnThreadSecure(XMLock lock, id dic, id key)
{
    XM_Lock(lock);
    [dic removeObjectForKey:key];
    XM_UnLock(lock);
}

//NSUserDefaults是线程安全的，不要使用此方法
/**
 设置<key, obj>
 
 @param lock XMLock
 @param dic NSMutableDictionary, NSMapTable, NSCache, <br/>NSUbiquitousKeyValueStore
 @param key 键
 @param obj 值
 */
NS_INLINE
void SetObjectForKeyOnThreadSecure(XMLock lock, id dic, id key, id obj)
{
    XM_Lock(lock);
    [dic setObject:obj forKey:key];
    XM_UnLock(lock);
}

/*
 NS_INLINE
 void DeleteObjectsForKeysThreadSecure(XMLock lock, id dic, NSArray *keys)
 {
 //这些都可以写
 XM_Lock(lock);
 [dic removeObjectsInArray:keys];
 [dic removeObjectsAtIndexes:[NSIndexSet indexSet]];
 [dic removeObjectsInRange:NSMakeRange(0, 0)];
 [dic removeObjectAtIndex:1];
 [dic insertObject:[NSObject new] atIndex:1];
 [dic insertObjects:keys atIndexes:[NSIndexSet indexSet]];
 [dic addObjectsFromArray:keys];
 XM_UnLock(lock);
 }//*/

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
