//
//  CMStore.m
//  cloudmine-ios
//
//  Copyright (c) 2012 CloudMine, LLC. All rights reserved.
//  See LICENSE file included with SDK for details.
//

#import "CMStore.h"
#import <objc/runtime.h>
#import "SPLowVerbosity.h"

#import "CMObjectDecoder.h"
#import "CMObjectEncoder.h"
#import "CMObjectSerialization.h"
#import "CMAPICredentials.h"
#import "CMObject.h"
#import "CMMimeType.h"

#define _CMAssertAPICredentialsInitialized NSAssert([[CMAPICredentials sharedInstance] appSecret] != nil && [[[CMAPICredentials sharedInstance] appSecret] length] > 0 && [[CMAPICredentials sharedInstance] appIdentifier] != nil && [[[CMAPICredentials sharedInstance] appIdentifier] length] > 0, @"The CMAPICredentials singleton must be initialized before using a CloudMine Store")

#define _CMAssertUserConfigured NSAssert(user && user.isLoggedIn, @"You must set the user of this store to a logged in CMUser before querying for user-level objects.")

#define _CMUserOrNil (userLevel ? user : nil)

#define _CMTryMethod(obj, method) (obj ? [obj method] : nil)

#pragma mark - Notification strings
NSString * const CMStoreObjectDeletedNotification = @"CMStoreObjectDeletedNotification";

#pragma mark -

@interface CMStore (Private)
- (void)_allObjects:(CMStoreObjectFetchCallback)callback userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options;
- (void)_allObjects:(CMStoreObjectFetchCallback)callback ofClass:(Class)klass userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options;
- (void)_objectsWithKeys:(NSArray *)keys callback:(CMStoreObjectFetchCallback)callback userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options;
- (void)_searchObjects:(CMStoreObjectFetchCallback)callback query:(NSString *)query userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options;
- (void)_fileWithName:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileFetchCallback)callback;
- (void)_saveObjects:(NSArray *)objects userLevel:(BOOL)userLevel callback:(CMStoreObjectUploadCallback)callback additionalOptions:(CMStoreOptions *)options;
- (void)_saveFileAtURL:(NSURL *)url named:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileUploadCallback)callback;
- (void)_saveFileWithData:(NSData *)data named:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileUploadCallback)callback;
- (NSString *)_mimeTypeForFileAtURL:(NSURL *)url withCustomName:(NSString *)name;
- (void)_deleteObjects:(NSArray *)objects userLevel:(BOOL)userLevel callback:(CMStoreDeleteCallback)callback;
- (void)_deleteFileNamed:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreDeleteCallback)callback;
- (void)cacheObjectsInMemory:(NSArray *)objects atUserLevel:(BOOL)userLevel;
@end

@implementation CMStore
@synthesize webService;
@synthesize user;
@synthesize lastError;

#pragma mark - Initializers

+ (CMStore *)store {
    return [[CMStore alloc] init];
}

+ (CMStore *)storeWithUser:(CMUser *)theUser {
    return [[CMStore alloc] initWithUser:theUser];
}

- (id)init {
    return [self initWithUser:nil];
}

- (id)initWithUser:(CMUser *)theUser {
    if (self = [super init]) {
        self.webService = [[CMWebService alloc] init];
        self.user = theUser;
        lastError = nil;
        _cachedAppObjects = [[NSMutableDictionary alloc] init];
        _cachedUserObjects = theUser ? [[NSMutableDictionary alloc] init] : nil;
    }
    return self;
}

- (void)setUser:(CMUser *)theUser {
    @synchronized(self) {
        if (_cachedUserObjects) {
            [_cachedUserObjects enumerateKeysAndObjectsUsingBlock:^(id key, CMObject *obj, BOOL *stop) {
                obj.store = nil;
            }];
            [_cachedUserObjects removeAllObjects];
        } else {
            _cachedUserObjects = [[NSMutableDictionary alloc] init];
        }
        user = theUser;
    }
}

#pragma mark - Store state

- (CMObjectOwnershipLevel)objectOwnershipLevel:(CMObject *)theObject {
    if ([_cachedAppObjects objectForKey:theObject.objectId] != nil) {
        return CMObjectOwnershipAppLevel;
    } else if ([_cachedUserObjects objectForKey:theObject.objectId] != nil) {
        return CMObjectOwnershipUserLevel;
    } else {
        return CMObjectOwnershipUndefinedLevel;
    }
}

#pragma mark - Object retrieval

- (void)allObjectsWithOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    [self _allObjects:callback userLevel:NO additionalOptions:options];
}

- (void)allUserObjectsWithOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    _CMAssertUserConfigured;
    [self _allObjects:callback userLevel:YES additionalOptions:options];
}

- (void)_allObjects:(CMStoreObjectFetchCallback)callback userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options {
    [self _objectsWithKeys:nil callback:callback userLevel:userLevel additionalOptions:options];
}

- (void)objectsWithKeys:(NSArray *)keys additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    [self _objectsWithKeys:keys callback:callback userLevel:NO additionalOptions:options];
}

- (void)userObjectsWithKeys:(NSArray *)keys additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    _CMAssertUserConfigured;
    [self _objectsWithKeys:keys callback:callback userLevel:YES additionalOptions:options];
}
- (void)_objectsWithKeys:(NSArray *)keys callback:(CMStoreObjectFetchCallback)callback userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options {
    NSParameterAssert(callback);
    _CMAssertAPICredentialsInitialized;

    __unsafe_unretained CMStore *blockSelf = self;
    [webService getValuesForKeys:keys
              serverSideFunction:_CMTryMethod(options, serverSideFunction)
                   pagingOptions:_CMTryMethod(options, pagingDescriptor)
                            user:_CMUserOrNil
                  successHandler:^(NSDictionary *results, NSDictionary *errors) {
                      NSArray *objects = [CMObjectDecoder decodeObjects:results];
                      [blockSelf cacheObjectsInMemory:objects atUserLevel:userLevel];
                      callback(objects, errors);
                  } errorHandler:^(NSError *error) {
                      NSLog(@"Error occurred during object request: %@", [error description]);
                      lastError = error;
                      callback(nil, nil);
                  }
     ];
}

#pragma mark Object querying by type

- (void)allObjectsOfClass:(Class)klass additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    [self _allObjects:callback ofClass:klass userLevel:NO additionalOptions:options];
}

- (void)allUserObjectsOfClass:(Class)klass additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    _CMAssertUserConfigured;

    [self _allObjects:callback ofClass:klass userLevel:YES additionalOptions:options];
}

- (void)_allObjects:(CMStoreObjectFetchCallback)callback ofClass:(Class)klass userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options {
    NSParameterAssert(callback);
    NSParameterAssert(klass);
    NSAssert([klass respondsToSelector:@selector(className)], @"You must pass a class (%@) that extends CMObject and responds to +className.", klass);
    _CMAssertAPICredentialsInitialized;

    [self _searchObjects:callback
                   query:$sprintf(@"[%@ = \"%@\"]", CMInternalClassStorageKey, [klass className])
               userLevel:userLevel
       additionalOptions:options];
}

#pragma mark General object querying

- (void)searchObjects:(NSString *)query additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    [self _searchObjects:callback query:query userLevel:NO additionalOptions:options];
}

- (void)searchUserObjects:(NSString *)query additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectFetchCallback)callback {
    _CMAssertUserConfigured;

    [self _searchObjects:callback query:query userLevel:YES additionalOptions:options];
}

- (void)_searchObjects:(CMStoreObjectFetchCallback)callback query:(NSString *)query userLevel:(BOOL)userLevel additionalOptions:(CMStoreOptions *)options {
    NSParameterAssert(callback);
    _CMAssertAPICredentialsInitialized;

    if (!query || [query length] == 0) {
        NSLog(@"No query provided, so executing standard all-object retrieval");
        return [self _allObjects:callback userLevel:userLevel additionalOptions:options];
    }

    __unsafe_unretained CMStore *blockSelf = self;
    [webService searchValuesFor:query
             serverSideFunction:_CMTryMethod(options, serverSideFunction)
                  pagingOptions:_CMTryMethod(options, pagingDescriptor)
                           user:_CMUserOrNil
                 successHandler:^(NSDictionary *results, NSDictionary *errors) {
                     NSArray *objects = [CMObjectDecoder decodeObjects:results];
                     [blockSelf cacheObjectsInMemory:objects atUserLevel:userLevel];
                     callback(objects, errors);
                 } errorHandler:^(NSError *error) {
                     NSLog(@"Error occurred during object request: %@", [error description]);
                     lastError = error;
                     callback(nil, nil);
                 }
     ];
}

#pragma mark Object uploading

- (void)saveAll:(CMStoreObjectUploadCallback)callback {
    [self saveAllWithOptions:nil callback:callback];
}

- (void)saveAllWithOptions:(CMStoreOptions *)options callback:(CMStoreObjectUploadCallback)callback {
    __unsafe_unretained CMStore *selff = self;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    dispatch_async(queue, ^{
        [selff saveAllAppObjectsWithOptions:options callback:callback];
    });

    if (user) {
        dispatch_async(queue, ^{
            [selff saveAllUserObjectsWithOptions:options callback:callback];
        });
    }
}

- (void)saveAllAppObjects:(CMStoreObjectUploadCallback)callback {
    [self saveAllAppObjectsWithOptions:nil callback:callback];
}

- (void)saveAllAppObjectsWithOptions:(CMStoreOptions *)options callback:(CMStoreObjectUploadCallback)callback {
    [self _saveObjects:[_cachedAppObjects allValues] userLevel:NO callback:callback additionalOptions:options];
}

- (void)saveAllUserObjects:(CMStoreObjectUploadCallback)callback {
    [self saveAllUserObjectsWithOptions:nil callback:callback];
}

- (void)saveAllUserObjectsWithOptions:(CMStoreOptions *)options callback:(CMStoreObjectUploadCallback)callback {
    [self _saveObjects:[_cachedUserObjects allValues] userLevel:YES callback:callback additionalOptions:options];
}

- (void)saveUserObject:(CMObject *)theObject callback:(CMStoreObjectUploadCallback)callback {
    [self saveUserObject:theObject additionalOptions:nil callback:callback];
}

- (void)saveUserObject:(CMObject *)theObject additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectUploadCallback)callback {
    _CMAssertUserConfigured;
    [self _saveObjects:$set(theObject) userLevel:YES callback:callback additionalOptions:options];
}

- (void)saveObject:(CMObject *)theObject callback:(CMStoreObjectUploadCallback)callback {
    [self saveObject:theObject additionalOptions:nil callback:callback];
}

- (void)saveObject:(CMObject *)theObject additionalOptions:(CMStoreOptions *)options callback:(CMStoreObjectUploadCallback)callback {
    [self _saveObjects:$set(theObject) userLevel:NO callback:callback additionalOptions:options];
}

- (void)_saveObjects:(NSArray *)objects userLevel:(BOOL)userLevel callback:(CMStoreObjectUploadCallback)callback additionalOptions:(CMStoreOptions *)options {
    NSParameterAssert(objects);
    _CMAssertAPICredentialsInitialized;
    [self cacheObjectsInMemory:objects atUserLevel:userLevel];

    [webService updateValuesFromDictionary:[CMObjectEncoder encodeObjects:objects]
                        serverSideFunction:_CMTryMethod(options, serverSideFunction)
                                      user:_CMUserOrNil
                            successHandler:^(NSDictionary *results, NSDictionary *errors) {
                                callback(results);
                            } errorHandler:^(NSError *error) {
                                NSLog(@"Error occurred during object uploading: %@", [error description]);
                                lastError = error;
                                callback(nil);
                            }
     ];
}

#pragma mark File uploading

- (void)saveFileAtURL:(NSURL *)url named:(NSString *)name callback:(CMStoreFileUploadCallback)callback {
    [self _saveFileAtURL:url named:name userLevel:NO callback:callback];
}

- (void)saveUserFileAtURL:(NSURL *)url named:(NSString *)name callback:(CMStoreFileUploadCallback)callback {
    _CMAssertUserConfigured;
    [self _saveFileAtURL:url named:name userLevel:YES callback:callback];
}

- (void)_saveFileAtURL:(NSURL *)url named:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileUploadCallback)callback {
    NSParameterAssert(url);
    NSParameterAssert(name);
    _CMAssertAPICredentialsInitialized;

    [webService uploadFileAtPath:[url path]
                           named:name
                      ofMimeType:[self _mimeTypeForFileAtURL:url withCustomName:name]
                            user:_CMUserOrNil
                  successHandler:^(CMFileUploadResult result) {
                      callback(result);
                  } errorHandler:^(NSError *error) {
                      NSLog(@"Error ocurred during file uploading: %@", [error description]);
                      lastError = error;
                      callback(CMFileUploadFailed);
                  }
     ];
}

- (void)saveFileWithData:(NSData *)data named:(NSString *)name callback:(CMStoreFileUploadCallback)callback {
    [self _saveFileWithData:data named:name userLevel:NO callback:callback];
}

- (void)saveUserFileWithData:(NSData *)data named:(NSString *)name callback:(CMStoreFileUploadCallback)callback {
    _CMAssertUserConfigured;
    [self _saveFileWithData:data named:name userLevel:YES callback:callback];
}

- (void)_saveFileWithData:(NSData *)data named:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileUploadCallback)callback {
    NSParameterAssert(data);
    NSParameterAssert(name);
    _CMAssertAPICredentialsInitialized;

    [webService uploadBinaryData:data
                           named:name
                      ofMimeType:[self _mimeTypeForFileAtURL:nil withCustomName:name]
                            user:_CMUserOrNil
                  successHandler:^(CMFileUploadResult result) {
                      callback(result);
                  } errorHandler:^(NSError *error) {
                      NSLog(@"Error ocurred during in-memory file uploading: %@", [error description]);
                      lastError = error;
                      callback(CMFileUploadFailed);
                  }
     ];
}

- (NSString *)_mimeTypeForFileAtURL:(NSURL *)url withCustomName:(NSString *)name {
    NSString *mimeType = nil;
    NSArray *components = nil;

    if (url != nil) {
        components = [[url lastPathComponent] componentsSeparatedByString:@"."];
        if ([components count] > 1) {
            mimeType = [CMMimeType mimeTypeForExtension:[components objectAtIndex:1]];
        }
    }

    if (mimeType == nil && name != nil) {
        components = [name componentsSeparatedByString:@"."];
        if ([components count] > 1) {
            mimeType = [CMMimeType mimeTypeForExtension:[components objectAtIndex:1]];
        }
    }

    return mimeType;
}

#pragma mark Object and file deletion

- (void)deleteObject:(id<CMSerializable>)theObject callback:(CMStoreDeleteCallback)callback {
    NSParameterAssert(theObject);
    [self _deleteObjects:$array(theObject) userLevel:NO callback:callback];
}

- (void)deleteUserObject:(id<CMSerializable>)theObject callback:(CMStoreDeleteCallback)callback {
    NSParameterAssert(theObject);
    _CMAssertUserConfigured;
    [self _deleteObjects:$array(theObject) userLevel:YES callback:callback];
}

- (void)deleteObjects:(NSArray *)objects callback:(CMStoreDeleteCallback)callback {
    [self _deleteObjects:objects userLevel:NO callback:callback];
}

- (void)deleteUserObjects:(NSArray *)objects callback:(CMStoreDeleteCallback)callback {
    _CMAssertUserConfigured;
    [self _deleteObjects:objects userLevel:YES callback:callback];
}

- (void)deleteFileNamed:(NSString *)name callback:(CMStoreDeleteCallback)callback {
    [self _deleteFileNamed:name userLevel:NO callback:callback];
}

- (void)deleteUserFileNamed:(NSString *)name callback:(CMStoreDeleteCallback)callback {
    _CMAssertUserConfigured;
    [self _deleteFileNamed:name userLevel:YES callback:callback];
}

- (void)_deleteFileNamed:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreDeleteCallback)callback {
    NSParameterAssert(name);
    _CMAssertAPICredentialsInitialized;

    [webService deleteValuesForKeys:$array(name)
                               user:_CMUserOrNil
                     successHandler:^(NSDictionary *results, NSDictionary *errors) {
                         callback(YES);
                     } errorHandler:^(NSError *error) {
                         NSLog(@"An error occurred when deleting the file named \"%@\": %@", name, [error description]);
                         lastError = error;
                         callback(NO);
                     }
     ];
}

- (void)_deleteObjects:(NSArray *)objects userLevel:(BOOL)userLevel callback:(CMStoreDeleteCallback)callback {
    NSParameterAssert(objects);
    _CMAssertAPICredentialsInitialized;

    // Remove the objects from the cache first.
    NSMutableDictionary *deletedObjects = [NSMutableDictionary dictionaryWithCapacity:objects.count];
    [objects enumerateObjectsUsingBlock:^(CMObject *obj, NSUInteger idx, BOOL *stop) {
        SEL delMethod = userLevel ? @selector(removeObject:) : @selector(removeUserObject:);
        [deletedObjects setObject:obj forKey:obj.objectId];
        [self performSelector:delMethod withObject:obj];
    }];

    NSArray *keys = [deletedObjects allKeys];
    [webService deleteValuesForKeys:keys
                               user:_CMUserOrNil
                     successHandler:^(NSDictionary *results, NSDictionary *errors) {
                         callback(YES);
                     } errorHandler:^(NSError *error) {
                         NSLog(@"An error occurred when deleting objects with keys (%@): %@", keys, [error description]);
                         lastError = error;
                         callback(NO);
                     }
     ];

    [[NSNotificationCenter defaultCenter] postNotificationName:CMStoreObjectDeletedNotification
                                                        object:self
                                                      userInfo:deletedObjects];
}

#pragma mark Binary file loading

- (void)fileWithName:(NSString *)name callback:(CMStoreFileFetchCallback)callback {
    [self _fileWithName:name userLevel:NO callback:callback];
}

- (void)userFileWithName:(NSString *)name callback:(CMStoreFileFetchCallback)callback {
    _CMAssertUserConfigured;

    [self _fileWithName:name userLevel:YES callback:callback];
}

- (void)_fileWithName:(NSString *)name userLevel:(BOOL)userLevel callback:(CMStoreFileFetchCallback)callback {
    NSParameterAssert(name);
    NSParameterAssert(callback);

    [webService getBinaryDataNamed:name
                              user:_CMUserOrNil
                    successHandler:^(NSData *data, NSString *mimeType) {
                        CMFile *file = [[CMFile alloc] initWithData:data
                                                              named:name
                                                    belongingToUser:userLevel ? user : nil
                                                           mimeType:mimeType];
                        [file writeToCache];
                        callback(file);
                    } errorHandler:^(NSError *error) {
                        NSLog(@"Error occurred during file request: %@", [error description]);
                        lastError = error;
                        callback(nil);
                    }
     ];
}

#pragma mark - In-memory caching

- (void)cacheObjectsInMemory:(NSArray *)objects atUserLevel:(BOOL)userLevel {
    NSAssert(userLevel ? (user != nil) : true, @"Failed trying to cache remote objects in-memory for user when user is not configured (%@)", self);

    @synchronized(self) {
        SEL addMethod = userLevel ? @selector(addUserObject:) : @selector(addObject:);
        for (CMObject *obj in objects) {
            [self performSelector:addMethod withObject:obj];
        }
    }
}

- (void)addUserObject:(CMObject *)theObject {
    NSAssert(user != nil, @"Attempted to add object (%@) to store (%@) belonging to user when user is not set.", theObject, self);
    @synchronized(self) {
        [_cachedUserObjects setObject:theObject forKey:theObject.objectId];
    }
    theObject.store = self;
}

- (void)addObject:(CMObject *)theObject {
    @synchronized(self) {
        [_cachedAppObjects setObject:theObject forKey:theObject.objectId];
    }
    theObject.store = self;
}

- (void)removeObject:(CMObject *)theObject {
    @synchronized(self) {
        [_cachedAppObjects removeObjectForKey:theObject.objectId];
    }
    theObject.store = nil;
}

- (void)removeUserObject:(CMObject *)theObject {
    @synchronized(self) {
        [_cachedUserObjects removeObjectForKey:theObject.objectId];
    }
    theObject.store = nil;
}

@end
