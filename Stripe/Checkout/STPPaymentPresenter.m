//
//  STPPaymentPresenter.m
//  Stripe
//
//  Created by Jack Flintermann on 11/25/14.
//  Copyright (c) 2014 Stripe, Inc. All rights reserved.
//

#import "STPPaymentPresenter.h"
#import <PassKit/PassKit.h>
#import "StripeError.h"
#import "Stripe.h"
#import "Stripe+ApplePay.h"
#import <objc/runtime.h>

static const NSString *STPPaymentPresenterAssociatedObjectKey = @"STPPaymentPresenterAssociatedObjectKey";

@interface STPPaymentPresenter () <STPCheckoutViewControllerDelegate>
@property (weak, nonatomic) UIViewController *presentingViewController;
@property (weak, nonatomic) UIViewController *presentedViewController;
@property (nonatomic) BOOL hasAuthorizedPayment;
@property (nonatomic) NSError *error;
@end

#ifdef STRIPE_ENABLE_APPLEPAY
@interface STPPaymentPresenter (ApplePay) <PKPaymentAuthorizationViewControllerDelegate>
@end
#endif

@implementation STPPaymentPresenter

- (void)requestPaymentFromPresentingViewController:(UIViewController *)presentingViewController {
    if (presentingViewController.presentedViewController && presentingViewController.presentedViewController == self.presentedViewController) {
        NSLog(@"Error: called requestPaymentFromPresentingViewController: while already presenting a payment view controller.");
        return;
    }
    NSCAssert(
        self.checkoutOptions,
        @"Your must provide an instance of STPCheckoutOptions to your STPPaymentManager before calling requestPaymentFromPresentingViewController: on it.");
    NSCAssert(self.delegate, @"Your must specify a delegate for your STPPaymentManager before calling requestPaymentFromPresentingViewController: on it.");
    NSCAssert(presentingViewController, @"You cannot call requestPaymentFromPresentingViewController: with a nil argument.");
    self.presentingViewController = presentingViewController;

    // we really don't want to get dealloc'ed in case the caller doesn't remember to retain this object.
    objc_setAssociatedObject(self.presentingViewController, &STPPaymentPresenterAssociatedObjectKey, self, OBJC_ASSOCIATION_RETAIN);
#ifdef STRIPE_ENABLE_APPLEPAY
    if (self.paymentRequest) {
        if (self.paymentRequest.requiredShippingAddressFields != PKAddressFieldNone) {
            NSError *error = [[NSError alloc] initWithDomain:StripeDomain
                                                        code:STPInvalidRequestError
                                                    userInfo:@{
                                                        NSLocalizedDescriptionKey: NSLocalizedString(
                                                            @"Your payment request has required shipping address fields, which isn't supported by Stripe "
                                                            @"Checkout yet. You should collect that information ahead of time if you want to use this feature.",
                                                            nil),
                                                    }];
            [self finishWithStatus:STPPaymentStatusError error:error];
            return;
        }
        if ([Stripe canSubmitPaymentRequest:self.paymentRequest]) {
            PKPaymentAuthorizationViewController *paymentViewController =
                [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:self.paymentRequest];
            paymentViewController.delegate = self;
            [self.presentingViewController presentViewController:paymentViewController animated:YES completion:nil];
            self.presentedViewController = paymentViewController;
            return;
        }
    }
#endif
    STPCheckoutViewController *checkoutViewController = [[STPCheckoutViewController alloc] initWithOptions:self.checkoutOptions];
    checkoutViewController.delegate = self;
    self.presentedViewController = checkoutViewController;
    [self.presentingViewController presentViewController:checkoutViewController animated:YES completion:nil];
}

- (void)finishWithStatus:(STPPaymentStatus)status error:(NSError *)error {
    [self.delegate paymentPresenter:self didFinishWithStatus:status error:error];
    objc_setAssociatedObject(self.presentingViewController, &STPPaymentPresenterAssociatedObjectKey, nil, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - STPCheckoutViewControllerDelegate

- (void)checkoutController:(__unused STPCheckoutViewController *)controller didFailWithError:(NSError *)error {
    [self finishWithStatus:STPPaymentStatusError error:error];
}

- (void)checkoutControllerDidCancel:(__unused STPCheckoutViewController *)controller {
    [self finishWithStatus:STPPaymentStatusUserCanceled error:nil];
}

- (void)checkoutControllerDidFinish:(__unused STPCheckoutViewController *)controller {
    [self finishWithStatus:STPPaymentStatusSuccess error:nil];
}

- (void)checkoutController:(__unused STPCheckoutViewController *)controller didCreateToken:(STPToken *)token completion:(STPTokenSubmissionHandler)completion {
    [self.delegate paymentPresenter:self didCreateStripeToken:token completion:completion];
}

@end

#ifdef STRIPE_ENABLE_APPLEPAY
#pragma mark - PKPaymentAuthorizatoinViewControllerDelegate

@implementation STPPaymentPresenter (ApplePay)

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                completion:(void (^)(PKPaymentAuthorizationStatus))pkCompletion {
    [Stripe createTokenWithPayment:payment
                        completion:^(STPToken *token, NSError *error) {
                            if (error) {
                                [self finishWithStatus:STPPaymentStatusError error:error];
                                return;
                            }
                            STPTokenSubmissionHandler completion = ^(STPBackendChargeResult status, NSError *error) {
                                self.error = error;
                                if (status == STPBackendChargeResultSuccess) {
                                    self.hasAuthorizedPayment = YES;
                                    pkCompletion(PKPaymentAuthorizationStatusSuccess);
                                } else {
                                    pkCompletion(PKPaymentAuthorizationStatusFailure);
                                }
                            };
                            [self.delegate paymentPresenter:self didCreateStripeToken:token completion:completion];
                        }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller {
    STPPaymentStatus status;
    if (self.error) {
        status = STPPaymentStatusError;
    } else if (self.hasAuthorizedPayment) {
        status = STPPaymentStatusSuccess;
    } else {
        status = STPPaymentStatusUserCanceled;
    }
    [self finishWithStatus:status error:self.error];
}

@end

#endif
