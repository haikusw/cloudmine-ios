//
//  CMUserCredentials.m
//  cloudmine-ios
//
//  Copyright (c) 2012 CloudMine, LLC. All rights reserved.
//  See LICENSE file included with SDK for details.
//

#import "CMUser.h"

@implementation CMUser
@synthesize userId, password;

- (id)initWithUserId:(NSString *)theUserId andPassword:(NSString *)thePassword {
    if (self = [super init]) {
        self.userId = theUserId;
        self.password = thePassword;
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder {
    return [self initWithUserId:[coder decodeObjectForKey:@"userId"] andPassword:[coder decodeObjectForKey:@"password"]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.userId forKey:@"userId"];
    [coder encodeObject:self.password forKey:@"password"];
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[CMUser class]]) {
        return NO;
    }
    
    return ([[object userId] isEqualToString:userId] && [[object password] isEqualToString:password]);
}

@end
