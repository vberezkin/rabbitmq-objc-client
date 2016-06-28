// This source code is dual-licensed under the Mozilla Public License ("MPL"),
// version 1.1 and the Apache License ("ASL"), version 2.0.
//
// The ASL v2.0:
//
// ---------------------------------------------------------------------------
// Copyright 2016 Pivotal Software, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ---------------------------------------------------------------------------
//
// The MPL v1.1:
//
// ---------------------------------------------------------------------------
// The contents of this file are subject to the Mozilla Public License
// Version 1.1 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// https://www.mozilla.org/MPL/
//
// Software distributed under the License is distributed on an "AS IS"
// basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
// License for the specific language governing rights and limitations
// under the License.
//
// The Original Code is RabbitMQ
//
// The Initial Developer of the Original Code is Pivotal Software, Inc.
// All Rights Reserved.
//
// Alternatively, the contents of this file may be used under the terms
// of the Apache Standard license (the "ASL License"), in which case the
// provisions of the ASL License are applicable instead of those
// above. If you wish to allow use of your version of this file only
// under the terms of the ASL License and not to allow others to use
// your version of this file under the MPL, indicate your decision by
// deleting the provisions above and replace them with the notice and
// other provisions required by the ASL License. If you do not delete
// the provisions above, a recipient may use your version of this file
// under either the MPL or the ASL License.
// ---------------------------------------------------------------------------

#import "RMQBasicProperties+MergeDefaults.h"
#import "RMQErrors.h"
#import "RMQMethods+Convenience.h"
#import "RMQAllocatedChannel.h"
#import "RMQConnectionDelegate.h"

@interface RMQAllocatedChannel ()
@property (nonatomic, copy, readwrite) NSNumber *channelNumber;
@property (nonatomic, readwrite) NSNumber *contentBodySize;
@property (nonatomic, readwrite) id <RMQDispatcher> dispatcher;
@property (nonatomic, readwrite) id <RMQDispatcher> recoveryDispatcher;
@property (nonatomic, readwrite) NSMutableDictionary *consumers;
@property (nonatomic, readwrite) NSMutableDictionary *exchanges;
@property (nonatomic, readwrite) NSMutableDictionary *exchangeBindings;
@property (nonatomic, readwrite) NSMutableDictionary *queues;
@property (nonatomic, readwrite) NSMutableDictionary *queueBindings;
@property (nonatomic, readwrite) id<RMQConfirmations> confirmations;
@property (nonatomic, readwrite) NSNumber *prefetchCountPerConsumer;
@property (nonatomic, readwrite) NSNumber *prefetchCountPerChannel;
@property (nonatomic, readwrite) id<RMQConnectionDelegate> delegate;
@property (nonatomic, readwrite) id<RMQNameGenerator> nameGenerator;
@property (nonatomic, readwrite) id<RMQChannelAllocator> allocator;
@end

@implementation RMQAllocatedChannel

- (instancetype)init:(NSNumber *)channelNumber
     contentBodySize:(NSNumber *)contentBodySize
          dispatcher:(id<RMQDispatcher>)dispatcher
  recoveryDispatcher:(id<RMQDispatcher>)recoveryDispatcher
       nameGenerator:(id<RMQNameGenerator>)nameGenerator
           allocator:(nonnull id<RMQChannelAllocator>)allocator
       confirmations:(id<RMQConfirmations>)confirmations {
    self = [super init];
    if (self) {
        self.channelNumber = channelNumber;
        self.contentBodySize = contentBodySize;
        self.dispatcher = dispatcher;
        self.recoveryDispatcher = recoveryDispatcher;
        self.consumers = [NSMutableDictionary new];
        self.exchanges = [NSMutableDictionary new];
        self.exchangeBindings = [NSMutableDictionary new];
        self.queues = [NSMutableDictionary new];
        self.queueBindings = [NSMutableDictionary new];
        self.confirmations = confirmations;
        self.prefetchCountPerConsumer = nil;
        self.prefetchCountPerChannel = nil;
        self.delegate = nil;
        self.nameGenerator = nameGenerator;
        self.allocator = allocator;
    }
    return self;
}

- (instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (RMQExchange *)defaultExchange {
    return [[RMQExchange alloc] initWithName:@""
                                        type:@"direct"
                                     options:RMQExchangeDeclareNoOptions
                                     channel:self];
}

- (void)activateWithDelegate:(id<RMQConnectionDelegate>)delegate {
    [self.dispatcher activateWithChannel:self delegate:delegate];
    [self.recoveryDispatcher activateWithChannel:self delegate:delegate];
    self.delegate = delegate;
}

- (void)open {
    [self.dispatcher sendSyncMethod:[RMQChannelOpen new]];
}

- (void)close {
    [self.dispatcher sendSyncMethod:[RMQChannelClose new]
                  completionHandler:^(RMQFrameset *frameset) {
                      [self.allocator releaseChannelNumber:self.channelNumber];
                  }];
}

- (void)blockingClose {
    [self.dispatcher sendSyncMethodBlocking:[RMQChannelClose new]];
    [self.allocator releaseChannelNumber:self.channelNumber];
}

- (void)prepareForRecovery {
    [self.dispatcher disable];
}

- (void)recover {
    id<RMQDispatcher> oldCommandDispatcher = self.dispatcher;
    self.dispatcher = self.recoveryDispatcher;
    [self open];
    [self recoverPrefetch];
    [self recoverConfirmations];
    [self recoverExchanges];
    [self recoverExchangeBindings]; 
    [self recoverQueuesAndTheirBindings];
    [self recoverConsumers];
    [self.recoveryDispatcher enqueue:^{
        self.dispatcher = oldCommandDispatcher;
        [self.dispatcher enable];
    }];
}

- (void)blockingWaitOn:(Class)method {
    [self.dispatcher blockingWaitOn:method];
}

- (void)confirmSelect {
    [self.confirmations enable];
    [self.dispatcher sendSyncMethod:[RMQConfirmSelect new]];
}

- (void)afterConfirmed:(RMQConfirmationCallback)handler {
    [self.confirmations addCallback:handler];
}

- (RMQQueue *)queue:(NSString *)originalQueueName
            options:(RMQQueueDeclareOptions)options
          arguments:(nonnull NSDictionary<NSString *,RMQValue<RMQFieldValue> *> *)arguments {
    RMQQueue *found = self.queues[originalQueueName];
    if (found) {
        return found;
    } else {
        return [self memoizedQueueDeclare:originalQueueName options:options arguments:[[RMQTable alloc] init:arguments]];
    }
}

- (RMQQueue *)queue:(NSString *)originalQueueName
            options:(RMQQueueDeclareOptions)options {
    return [self queue:originalQueueName options:options arguments:@{}];
}

- (RMQQueue *)queue:(NSString *)queueName {
    return [self queue:queueName options:RMQQueueDeclareNoOptions];
}

- (void)queueDelete:(NSString *)queueName
            options:(RMQQueueDeleteOptions)options {
    [self.queues removeObjectForKey:queueName];
    [self.dispatcher sendSyncMethod:[[RMQQueueDelete alloc] initWithQueue:queueName
                                                                  options:options]];
}

- (void)queueBind:(NSString *)queueName
         exchange:(NSString *)exchangeName
       routingKey:(nonnull NSString *)routingKey {
    [self.dispatcher sendSyncMethod:[[RMQQueueBind alloc] initWithQueue:queueName
                                                               exchange:exchangeName
                                                             routingKey:routingKey]];
    [self.queueBindings[queueName] addObject:@{@"exchange": exchangeName,
                                               @"routing-key": routingKey}];
}

- (void)queueUnbind:(NSString *)queueName
           exchange:(NSString *)exchangeName
         routingKey:(NSString *)routingKey {
    [self.dispatcher sendSyncMethod:[[RMQQueueUnbind alloc] initWithQueue:queueName
                                                                 exchange:exchangeName
                                                               routingKey:routingKey]];
    [self.queueBindings[queueName] removeObject:@{@"exchange": exchangeName,
                                                  @"routing-key": routingKey}];
}

- (RMQConsumer *)basicConsume:(NSString *)queueName
                      options:(RMQBasicConsumeOptions)options
                      handler:(RMQConsumerDeliveryHandler)handler {
    NSString *consumerTag = [self.nameGenerator generateWithPrefix:@"rmq-objc-client.gen-"];
    RMQConsumer *consumer = [[RMQConsumer alloc] initWithQueueName:queueName
                                                           options:options
                                                       consumerTag:consumerTag
                                                           handler:handler
                                                           channel:self];
    [self.dispatcher sendSyncMethod:[[RMQBasicConsume alloc] initWithQueue:queueName
                                                               consumerTag:consumerTag
                                                                   options:options]
                  completionHandler:^(RMQFrameset *frameset) {
                      self.consumers[consumerTag] = consumer;
                  }];
    return consumer;
}

- (void)basicCancel:(NSString *)consumerTag {
    [self.consumers removeObjectForKey:consumerTag];
    [self.dispatcher sendSyncMethod:[[RMQBasicCancel alloc] initWithConsumerTag:[[RMQShortstr alloc] init:consumerTag]
                                                                        options:RMQBasicCancelNoOptions]];
}

- (void)basicPublish:(NSString *)message
          routingKey:(NSString *)routingKey
            exchange:(NSString *)exchange
          properties:(NSArray<RMQValue *> *)properties
             options:(RMQBasicPublishOptions)options {
    RMQBasicPublish *publish = [[RMQBasicPublish alloc] initWithReserved1:[[RMQShort alloc] init:0]
                                                                 exchange:[[RMQShortstr alloc] init:exchange]
                                                               routingKey:[[RMQShortstr alloc] init:routingKey]
                                                                  options:options];
    NSData *contentBodyData = [message dataUsingEncoding:NSUTF8StringEncoding];
    RMQContentBody *contentBody = [[RMQContentBody alloc] initWithData:contentBodyData];

    NSData *bodyData = contentBody.amqEncoded;

    NSArray *mergedProperties = [RMQBasicProperties mergeProperties:properties
                                                       withDefaults:RMQBasicProperties.defaultProperties];
    RMQContentHeader *contentHeader = [[RMQContentHeader alloc] initWithClassID:publish.classID
                                                                       bodySize:@(bodyData.length)
                                                                     properties:mergedProperties];

    NSArray *contentBodies = [self contentBodiesFromData:bodyData
                                              inChunksOf:self.contentBodySize.integerValue];
    RMQFrameset *frameset = [[RMQFrameset alloc] initWithChannelNumber:self.channelNumber
                                                                method:publish
                                                         contentHeader:contentHeader
                                                         contentBodies:contentBodies];

    [self.confirmations addPublication];

    [self.dispatcher sendAsyncFrameset:frameset];
}

-  (void)basicGet:(NSString *)queue
          options:(RMQBasicGetOptions)options
completionHandler:(RMQConsumerDeliveryHandler)userCompletionHandler {
    [self.dispatcher sendSyncMethod:[[RMQBasicGet alloc] initWithReserved1:[[RMQShort alloc] init:0]
                                                                     queue:[[RMQShortstr alloc] init:queue]
                                                                   options:options]
                  completionHandler:^(RMQFrameset *frameset) {
                      RMQBasicGetOk *getOk = (RMQBasicGetOk *)frameset.method;
                      NSString *messageContent = [[NSString alloc] initWithData:frameset.contentData
                                                                       encoding:NSUTF8StringEncoding];
                      RMQMessage *message = [[RMQMessage alloc] initWithContent:messageContent
                                                                    consumerTag:@""
                                                                    deliveryTag:@(getOk.deliveryTag.integerValue)
                                                                    redelivered:getOk.options & RMQBasicGetOkRedelivered
                                                                   exchangeName:getOk.exchange.stringValue
                                                                     routingKey:getOk.routingKey.stringValue
                                                                     properties:frameset.contentHeader.properties];
                      userCompletionHandler(message);
                  }];
}

- (void)basicQos:(NSNumber *)count
          global:(BOOL)isGlobal {
    [self.dispatcher sendSyncMethod:[[RMQBasicQos alloc] initWithPrefetchCount:count
                                                                        global:isGlobal]
                  completionHandler:^(RMQFrameset *frameset) {
                      if (isGlobal) {
                          self.prefetchCountPerChannel = count;
                      } else {
                          self.prefetchCountPerConsumer = count;
                      }
                  }];
}

- (void)ack:(NSNumber *)deliveryTag
    options:(RMQBasicAckOptions)options {
    [self.dispatcher sendAsyncMethod:[[RMQBasicAck alloc] initWithDeliveryTag:[[RMQLonglong alloc] init:deliveryTag.integerValue]
                                                                      options:options]];
}

- (void)ack:(NSNumber *)deliveryTag {
    [self ack:deliveryTag options:RMQBasicAckNoOptions];
}

- (void)reject:(NSNumber *)deliveryTag
       options:(RMQBasicRejectOptions)options {
    [self.dispatcher sendAsyncMethod:[[RMQBasicReject alloc] initWithDeliveryTag:[[RMQLonglong alloc] init:deliveryTag.integerValue]
                                                                         options:options]];
}

- (void)reject:(NSNumber *)deliveryTag {
    [self reject:deliveryTag options:RMQBasicRejectNoOptions];
}

- (void)nack:(NSNumber *)deliveryTag
     options:(RMQBasicNackOptions)options {
    [self.dispatcher sendAsyncMethod:[[RMQBasicNack alloc] initWithDeliveryTag:[[RMQLonglong alloc] init:deliveryTag.integerValue]
                                                                       options:options]];
}

- (void)nack:(NSNumber *)deliveryTag {
    [self nack:deliveryTag options:RMQBasicNackNoOptions];
}

- (void)exchangeDeclare:(NSString *)name
                   type:(NSString *)type
                options:(RMQExchangeDeclareOptions)options {
    [self.dispatcher sendSyncMethod:[[RMQExchangeDeclare alloc] initWithExchange:name
                                                                            type:type
                                                                         options:options]];
}

- (void)exchangeBind:(NSString *)sourceName
         destination:(NSString *)destinationName
          routingKey:(NSString *)routingKey {
    [self.dispatcher sendSyncMethod:[[RMQExchangeBind alloc] initWithDestination:destinationName
                                                                          source:sourceName
                                                                      routingKey:routingKey]];
    [self.exchangeBindings[sourceName] addObject:@{@"destination": destinationName,
                                                   @"routing-key": routingKey}];
}

- (void)exchangeUnbind:(NSString *)sourceName
           destination:(NSString *)destinationName
            routingKey:(NSString *)routingKey {
    [self.dispatcher sendSyncMethod:[[RMQExchangeUnbind alloc] initWithDestination:destinationName
                                                                            source:sourceName
                                                                        routingKey:routingKey]];
    [self.exchangeBindings[sourceName] removeObject:@{@"destination": destinationName,
                                                      @"routing-key": routingKey}];
}

- (RMQExchange *)fanout:(NSString *)name options:(RMQExchangeDeclareOptions)options {
    return [self memoizedExchangeDeclare:name type:@"fanout" options:options];
}

- (RMQExchange *)fanout:(NSString *)name {
    return [self fanout:name options:RMQExchangeDeclareNoOptions];
}

- (RMQExchange *)direct:(NSString *)name options:(RMQExchangeDeclareOptions)options {
    return [self memoizedExchangeDeclare:name type:@"direct" options:options];
}

- (RMQExchange *)direct:(NSString *)name {
    return [self direct:name options:RMQExchangeDeclareNoOptions];
}

- (RMQExchange *)topic:(NSString *)name options:(RMQExchangeDeclareOptions)options {
    return [self memoizedExchangeDeclare:name type:@"topic" options:options];
}

- (RMQExchange *)topic:(NSString *)name {
    return [self topic:name options:RMQExchangeDeclareNoOptions];
}

- (RMQExchange *)headers:(NSString *)name options:(RMQExchangeDeclareOptions)options {
    return [self memoizedExchangeDeclare:name type:@"headers" options:options];
}

- (RMQExchange *)headers:(NSString *)name {
    return [self headers:name options:RMQExchangeDeclareNoOptions];
}

- (void)exchangeDelete:(NSString *)name
               options:(RMQExchangeDeleteOptions)options {
    [self.exchanges removeObjectForKey:name];
    [self.dispatcher sendSyncMethod:[[RMQExchangeDelete alloc] initWithReserved1:[[RMQShort alloc] init:0]
                                                                        exchange:[[RMQShortstr alloc] init:name]
                                                                         options:options]];
}

# pragma mark - RMQFrameHandler

- (void)handleFrameset:(RMQFrameset *)frameset {
    if ([frameset.method isKindOfClass:[RMQBasicDeliver class]]) {
        [self.dispatcher enqueue:^{
            [self handleBasicDeliver:frameset];
        }];
    } else if ([frameset.method isKindOfClass:[RMQBasicCancel class]]) {
        [self.dispatcher enqueue:^{
            [self handleBasicCancel:frameset];
        }];
    } else if ([frameset.method isKindOfClass:[RMQBasicAck class]] ||
               [frameset.method isKindOfClass:[RMQBasicNack class]]) {
        [self.dispatcher enqueue:^{
            [self handleConfirmation:frameset];
        }];
    } else {
        [self.dispatcher handleFrameset:frameset];
    }
}

# pragma mark - Private

- (void)handleConfirmation:(RMQFrameset *)frameset {
    if ([frameset.method isKindOfClass:[RMQBasicAck class]]) {
        [self.confirmations ack:(RMQBasicAck *)frameset.method];
    } else {
        [self.confirmations nack:(RMQBasicNack *)frameset.method];
    }
}

- (void)handleBasicDeliver:(RMQFrameset *)frameset {
    RMQBasicDeliver *deliver = (RMQBasicDeliver *)frameset.method;
    NSString *content = [[NSString alloc] initWithData:frameset.contentData encoding:NSUTF8StringEncoding];
    RMQConsumer *consumer = self.consumers[deliver.consumerTag.stringValue];
    if (consumer) {
        RMQMessage *message = [[RMQMessage alloc] initWithContent:content
                                                      consumerTag:deliver.consumerTag.stringValue
                                                      deliveryTag:@(deliver.deliveryTag.integerValue)
                                                      redelivered:deliver.options & RMQBasicDeliverRedelivered
                                                     exchangeName:deliver.exchange.stringValue
                                                       routingKey:deliver.routingKey.stringValue
                                                       properties:frameset.contentHeader.properties];
        consumer.handler(message);
    }
}

- (void)handleBasicCancel:(RMQFrameset *)frameset {
    RMQBasicCancel *cancel = (RMQBasicCancel *)frameset.method;
    NSString *consumerTag = cancel.consumerTag.stringValue;
    [self.consumers removeObjectForKey:consumerTag];
}

- (RMQExchange *)memoizedExchangeDeclare:(NSString *)name
                                    type:(NSString *)type
                                 options:(RMQExchangeDeclareOptions)options {
    RMQExchange *exchange;
    exchange = self.exchanges[name];
    if (!exchange) {
        [self exchangeDeclare:name type:type options:options];
        exchange = [[RMQExchange alloc] initWithName:name
                                                type:type
                                             options:options
                                             channel:self];
        self.exchanges[name] = exchange;
        self.exchangeBindings[name] = [NSMutableSet new];
    }
    return exchange;
}

- (RMQQueue *)memoizedQueueDeclare:(NSString *)originalQueueName
                           options:(RMQQueueDeclareOptions)options
                         arguments:(RMQTable *)arguments {
    NSString *declaredQueueName = [originalQueueName isEqualToString:@""]
    ? [self.nameGenerator generateWithPrefix:@"rmq-objc-client.gen-"]
    : originalQueueName;

    if (self.queues[declaredQueueName]) {
        NSError *error = [NSError errorWithDomain:RMQErrorDomain
                                             code:RMQErrorChannelQueueNameCollision
                                         userInfo:@{NSLocalizedDescriptionKey: @"Name collision when generating unique name."}];
        [self.delegate channel:self error:error];
        return nil;
    } else {
        RMQQueue *q = [[RMQQueue alloc] initWithName:declaredQueueName
                                             options:options
                                           arguments:arguments
                                             channel:(id<RMQChannel>)self];

        RMQQueueDeclare *method = [[RMQQueueDeclare alloc] initWithQueue:declaredQueueName
                                                                 options:options
                                                               arguments:arguments];
        [self.dispatcher sendSyncMethod:method];

        self.queues[q.name] = q;
        self.queueBindings[q.name] = [NSMutableSet new];
        return q;
    }
}

- (NSArray *)contentBodiesFromData:(NSData *)data inChunksOf:(NSUInteger)chunkSize {
    NSMutableArray *bodies = [NSMutableArray new];
    NSUInteger chunkCount = data.length / chunkSize;
    for (int i = 0; i < chunkCount; i++) {
        NSUInteger offset = i * chunkSize;
        NSData *subData = [data subdataWithRange:NSMakeRange(offset, chunkSize)];
        RMQContentBody *body = [[RMQContentBody alloc] initWithData:subData];
        [bodies addObject:body];
    }
    NSUInteger lastChunkSize = data.length % chunkSize;
    if (lastChunkSize > 0) {
        NSData *lastData = [data subdataWithRange:NSMakeRange(data.length - lastChunkSize, lastChunkSize)];
        [bodies addObject:[[RMQContentBody alloc] initWithData:lastData]];
    }
    return bodies;
}

- (void)recoverPrefetch {
    if (self.prefetchCountPerConsumer) {
        [self basicQos:self.prefetchCountPerConsumer global:NO];
    }
    if (self.prefetchCountPerChannel) {
        [self basicQos:self.prefetchCountPerChannel global:YES];
    }
}

- (void)recoverConfirmations {
    if (self.confirmations.isEnabled) {
        [self.confirmations recover];
        [self.dispatcher sendSyncMethod:[RMQConfirmSelect new]];
    }
}

- (void)recoverExchanges {
    for (RMQExchange *exchange in self.exchanges.allValues) {
        [self exchangeDeclare:exchange.name type:exchange.type options:exchange.options];
    }
}

- (void)recoverExchangeBindings {
    for (RMQExchange *exchange in self.exchanges.allValues) {
        for (NSDictionary *binding in [self.exchangeBindings[exchange.name] copy]) {
            [self exchangeBind:exchange.name destination:binding[@"destination"] routingKey:binding[@"routing-key"]];
        }
    }
}

- (void)recoverQueuesAndTheirBindings {
    for (RMQQueue *queue in self.queues.allValues) {
        [self.dispatcher sendSyncMethod:[[RMQQueueDeclare alloc] initWithQueue:queue.name
                                                                       options:queue.options
                                                                     arguments:queue.arguments]];
        for (NSDictionary *binding in [self.queueBindings[queue.name] copy]) {
            [self queueBind:queue.name exchange:binding[@"exchange"] routingKey:binding[@"routing-key"]];
        }
    }
}

- (void)recoverConsumers {
    for (RMQConsumer *consumer in self.consumers.allValues) {
        [self.dispatcher sendSyncMethod:[[RMQBasicConsume alloc] initWithQueue:consumer.queueName
                                                                   consumerTag:consumer.tag
                                                                       options:consumer.options]];
    }
}

@end
