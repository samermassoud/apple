//
//  AppCoordinator+Repositories.swift
//  eduVPN
//
//  Created by Aleksandr Poddubny on 30/05/2019.
//  Copyright © 2019 SURFNet. All rights reserved.
//

import Foundation
import Moya
import NVActivityIndicatorView
import PromiseKit

extension AppCoordinator {

    private func showActivityIndicator(messageKey: String) {
        NVActivityIndicatorPresenter.sharedInstance.startAnimating(ActivityData(), nil)
        setActivityIndicatorMessage(key: messageKey)
    }
    
    private func setActivityIndicatorMessage(key messageKey: String) {
        NVActivityIndicatorPresenter.sharedInstance.setMessage(NSLocalizedString(messageKey, comment: ""))
    }
    
    private func hideActivityIndicator() {
        NVActivityIndicatorPresenter.sharedInstance.stopAnimating(nil)
    }
    
    func refresh(instance: Instance) -> Promise<Void> {
        showActivityIndicator(messageKey: "Fetching instance configuration")
        
        return InstancesRepository.shared.refresher.refresh(instance: instance)
            .then { api -> Promise<Void> in
                let api = self.persistentContainer.viewContext.object(with: api.objectID) as! Api //swiftlint:disable:this force_cast
                guard let authorizingDynamicApiProvider = DynamicApiProvider(api: api) else {
                    return .value(())
                }
                
                self.navigationController.popToRootViewController(animated: true)
                return self.refreshProfiles(for: authorizingDynamicApiProvider)
            }
            .ensure {
                self.providerTableViewController.refresh()
                self.hideActivityIndicator()
            }
    }
    
    func fetchProfile(for profile: Profile, retry: Bool = false) -> Promise<URL> {
        guard let api = profile.api else {
            precondition(false, "This should never happen")
            return Promise(error: AppCoordinatorError.apiMissing)
        }
        
        guard let dynamicApiProvider = DynamicApiProvider(api: api) else {
            return Promise(error: AppCoordinatorError.apiProviderCreateFailed)
        }
        
        setActivityIndicatorMessage(key: "Loading certificate")
        
        return loadCertificate(for: api)
            .then { _ -> Promise<Response> in
                self.setActivityIndicatorMessage(key: "Requesting profile config")
                return dynamicApiProvider.request(apiService: .profileConfig(profileId: profile.profileId!))
            }
            .map { response -> URL in
                guard var ovpnFileContent = String(data: response.data, encoding: .utf8) else {
                    throw AppCoordinatorError.ovpnConfigTemplate
                }
                
                ovpnFileContent = self.forceTcp(on: ovpnFileContent)
                try self.validateRemote(on: ovpnFileContent)
                ovpnFileContent = self.merge(key: api.certificateModel!.privateKeyString, certificate: api.certificateModel!.certificateString, into: ovpnFileContent)
                
                let filename = "\(profile.displayNames?.localizedValue ?? "")-\(api.instance?.displayNames?.localizedValue ?? "") \(profile.profileId ?? "").ovpn"
                return try self.saveToOvpnFile(content: ovpnFileContent, to: filename)
            }
            .recover { error throws -> Promise<URL> in
                NVActivityIndicatorPresenter.sharedInstance.stopAnimating(nil)
                
                if retry {
                    self.showError(error)
                    throw error
                }
                
                func retryFetchProile() -> Promise<URL> {
                    self.authorizingDynamicApiProvider = dynamicApiProvider
                    return dynamicApiProvider.authorize(presentingViewController: self.navigationController).then { _ -> Promise<URL> in
                        return self.fetchProfile(for: profile, retry: true)
                    }
                    
                }
                
                if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
                    return retryFetchProile()
                }
                
                switch error {
                    
                case ApiServiceError.tokenRefreshFailed, ApiServiceError.noAuthState :
                    return retryFetchProile()
                    
                default:
                    self.showError(error)
                    throw error
                    
                }
        }
    }
    
    private func refreshProfiles(for dynamicApiProvider: DynamicApiProvider) -> Promise<Void> {
        showActivityIndicator(messageKey: "Refreshing profiles")
        
        return ProfilesRepository.shared.refresher.refresh(for: dynamicApiProvider)
            .recover { error throws -> Promise<Void> in
                NVActivityIndicatorPresenter.sharedInstance.stopAnimating(nil)
                
                switch error {
                    
                case ApiServiceError.tokenRefreshFailed:
                    self.authorizingDynamicApiProvider = dynamicApiProvider
                    return dynamicApiProvider.authorize(presentingViewController: self.navigationController)
                        .then { _ -> Promise<Void> in self.refreshProfiles(for: dynamicApiProvider) }
                        .recover { error throws in
                            self.showError(error)
                            throw error
                    }
                    
                case ApiServiceError.noAuthState:
                    self.authorizingDynamicApiProvider = dynamicApiProvider
                    return dynamicApiProvider.authorize(presentingViewController: self.navigationController)
                        .then { _ -> Promise<Void> in self.refreshProfiles(for: dynamicApiProvider) }
                        .recover { error throws in
                            self.showError(error)
                            throw error
                    }
                    
                default:
                    self.showError(error)
                    throw error
                    
                }
        }
    }
}
