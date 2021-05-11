/*
 Copyright 2021 Adobe. All rights reserved.
 This file is licensed to you under the Apache License, Version 2.0 (the "License")
 you may not use this file except in compliance with the License. You may obtain a copy
 of the License at http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under
 the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS
 OF ANY KIND, either express or implied. See the License for the specific language
 governing permissions and limitations under the License.
 */

import Foundation
import AEPCore
import AEPServices

class CampaignFullscreenMessage: CampaignMessaging {
    private static let LOG_TAG = "FullscreenMessage"

    var eventDispatcher: Campaign.EventDispatcher?
    var messageId: String?

    public weak var fullscreenMessageDelegate: FullscreenMessageDelegate?

    private var state: CampaignState?
    private var html: String?
    private var extractedAssets: [[String]]?
    private var isUsingLocalImage = false
    private var fullscreenMessage: FullscreenPresentable?
    private let cache: Cache

    /// Campaign Fullscreen Message class initializer. It is accessed via the `createMessageObject` method.
    ///  - Parameters:
    ///    - consequence: `RuleConsequence` containing a Message-defining payload
    ///    - state: The CampaignState
    ///    - eventDispatcher: The Campaign event dispatcher
    private init(consequence: RuleConsequence, state: CampaignState, eventDispatcher: @escaping Campaign.EventDispatcher) {
        self.messageId = consequence.id
        self.eventDispatcher = eventDispatcher
        self.state = state
        self.isUsingLocalImage = false
        self.cache = Cache(name: CampaignConstants.RulesDownloaderConstants.RULES_CACHE_NAME)
        self.parseFullscreenMessagePayload(consequence: consequence)
    }

    /// Creates a `CampaignFullscreenMessage` object
    ///  - Parameters:
    ///    - consequence: `RuleConsequence` containing a Message-defining payload
    ///    - state: The CampaignState
    ///    - eventDispatcher: The Campaign event dispatcher
    ///  - Returns: A Message object or nil if the message object creation failed.
    @discardableResult static func createMessageObject(consequence: RuleConsequence?, state: CampaignState, eventDispatcher: @escaping Campaign.EventDispatcher) -> CampaignMessaging? {
        guard let consequence = consequence else {
            Log.trace(label: LOG_TAG, "\(#function) - Cannot create a Fullscreen Message object, the consequence is nil.")
            return nil
        }
        let fullscreenMessage = CampaignFullscreenMessage(consequence: consequence, state: state, eventDispatcher: eventDispatcher)
        // html is required so no message object is returned if it is nil
        guard fullscreenMessage.html != nil else {
            return nil
        }
        return fullscreenMessage
    }

    /// Instantiates  a new `CampaignFullscreenMessage` object then calls `show()` to display the message.
    /// This method reads the html content from the cached html within the rules cache and generates the expanded html by
    /// replacing assets URLs with cached references, before calling the method to display the message.
    func showMessage() {
        guard let htmlContent = readHtmlFromFile() else {
            Log.trace(label: Self.LOG_TAG, "\(#function) - Failed to read html content from the Campaign rules cache.")
            return
        }

        // use assets if not empty
        var finalHtml = ""
        if let extractedAssets = extractedAssets, !extractedAssets.isEmpty {
            finalHtml = generateExpandedHtml(sourceHtml: htmlContent)
        } else {
            finalHtml = htmlContent
        }
        self.fullscreenMessage = ServiceProvider.shared.uiService.createFullscreenMessage(payload: finalHtml, listener: self.fullscreenMessageDelegate ?? self, isLocalImageUsed: false)
        self.fullscreenMessage?.show()
    }

    /// Returns true as the Campaign Fullscreen Message class should download assets
    func shouldDownloadAssets() -> Bool {
        return true
    }

    /// Attempts to handle fullscreen message interaction by inspecting the id field on the clicked message.
    ///  - Parameter query: A `[String: String]` dictionary containing message interaction details
    func processMessageInteraction(query: [String: String]) {
        guard let id = query[CampaignConstants.Campaign.MessageData.TAG_ID], !id.isEmpty else {
            Log.debug(label: Self.LOG_TAG, "\(#function) - Cannot process message interaction, input query is nil or empty.")
            return
        }
        let strTokens = id.components(separatedBy: CampaignConstants.Campaign.MessageData.TAG_ID_DELIMITER)
        guard strTokens.count == CampaignConstants.Campaign.MessageData.ID_TOKENS_LEN else {
            Log.debug(label: Self.LOG_TAG, "\(#function) - Cannot process message interaction, input query contains an incorrect amount of id tokens.")
            return
        }
        let tagId = strTokens[2]
        switch tagId {
        case CampaignConstants.Campaign.MessageData.TAG_ID_BUTTON_1, // adbinapp://confirm/?id=h11901a,86f10d,3
             CampaignConstants.Campaign.MessageData.TAG_ID_BUTTON_2, // adbinapp://confirm/?id=h11901a,86f10d,4
             CampaignConstants.Campaign.MessageData.TAG_ID_BUTTON_X: // adbinapp://confirm/?id=h11901a,86f10d,5
            clickedWithData(data: query)
            viewed()
        default:
            Log.debug(label: Self.LOG_TAG, "\(#function) - Unsupported tag Id found in the id field in the given query: \(tagId)")
        }
    }

    // TODO: see if still needed as caching  is occurring within CampaignMessageAssetsCache
    /// Downloads any assets previously extracted from the "remoteAssets" array.
    private func downloadAssets() {
        guard let extractedAssets = extractedAssets, !extractedAssets.isEmpty else {
            Log.debug(label: Self.LOG_TAG, "\(#function) - No assets to be downloaded.")
            return
        }

        for currentAssetArray in extractedAssets {
            let currentAssetArrayCount = currentAssetArray.count

            // no strings in this asset, skip this entry
            if currentAssetArrayCount <= 0 {
                continue
            }

            let messageId = self.messageId ?? ""
            Log.debug(label: Self.LOG_TAG, "\(#function) - Downloading assets for message id: \(messageId).")
            // TODO: hook up campaignMessageAssetsCache when rules pr merged
            // init campaignMessageAssetsCache
            //campaignMessageAssetsCache?.downloadAssetsForMessage()
        }
    }

    /// Parses a `CampaignRuleConsequence` instance defining message payload for a `CampaignFullscreenMessage` object.
    /// Required fields:
    ///     * html: A `String` containing html for this message
    /// Optional fields:
    ///     * assets: An array of `[String]`s containing remote assets to prefetch and cache.
    ///  - Parameter consequence: `RuleConsequence` containing a Message-defining payload
    private func parseFullscreenMessagePayload(consequence: RuleConsequence) {
        guard !consequence.details.isEmpty else {
            Log.error(label: Self.LOG_TAG, "\(#function) - The consequence details are nil or empty, dropping the fullscreen message.")
            return
        }
        let detail = consequence.details

        // html is required
        guard let html = detail[CampaignConstants.EventDataKeys.RulesEngine.CONSEQUENCE_DETAIL_KEY_HTML] as? String, !html.isEmpty else {
            Log.error(label: Self.LOG_TAG, "\(#function) - The html filename for a fullscreen message is required, dropping the notification.")
            return
        }
        self.html = html

        // assets are optional
        if let assetsArray = detail[CampaignConstants.EventDataKeys.RulesEngine.CONSEQUENCE_DETAIL_KEY_REMOTE_ASSETS] as? [[String]], !assetsArray.isEmpty {
            for assets in assetsArray {
                extractAsset(assets: assets)
            }
        } else {
            Log.trace(label: Self.LOG_TAG, "\(#function) - Tried to read assets for fullscreen message but found none. This is not a required field.")
        }
    }

    /// Extract assets for the HTML message.
    ///  - Parameter assets: An array of `Strings` containing assets specific for this `CampaignFullscreenMessage`.
    private func extractAsset(assets: [String]) {
        guard !assets.isEmpty else {
            Log.debug(label: Self.LOG_TAG, "\(#function) - There are no assets to extract.")
            return
        }
        var currentAsset: [String] = []
        for asset in assets where !asset.isEmpty {
            currentAsset.append(asset)
        }
        Log.trace(label: Self.LOG_TAG, "\(#function) - Adding \(currentAsset) to extracted assets.")
        extractedAssets?.append(currentAsset)
    }

    /// Reads a html file from disk and returns its contents as `String`
    ///  - Returns: A `String` containing the cached html.
    private func readHtmlFromFile() -> String? {
        guard let html = html, let cachedEntry = cache.get(key: "campaignrules/assets/"+html) else {
            return nil
        }
        return String(data: cachedEntry.data, encoding: .utf8)
    }

    /// Replace the image urls in the HTML with cached URIs for those images. If no cache URIs are found, then use a local image asset, if it has been
    /// provided in the assets.
    ///  - Returns: The HTML `String` with image tokens replaced with cached URIs, if available.
    private func generateExpandedHtml(sourceHtml: String) -> String {
        // if we have no extracted assets, return the source html unchanged
        guard let extractedAssets = extractedAssets, !extractedAssets.isEmpty else {
            Log.trace(label: Self.LOG_TAG, "\(#function) - Not generating expanded html, extracted assets is nil or empty.")
            return sourceHtml
        }
        var imageTokens: [String: String] = [:]
        // the first element in assets is a url
        // the remaining elements in the are urls or file paths to assets that should replace that asset in the resulting html if they are already cached
        for asset in extractedAssets {
            // the url to replace
            let assetUrl = asset[0]

            // use getAssetReplacement to get the string that should
            // replace the given asset
            let assetValue = getAssetReplacement(assetArray: asset) ?? ""
            if assetValue.isEmpty {
                continue // no replacement, move on
            } else {
                // save it
                imageTokens[assetUrl] = assetValue
            }
        }

        // actually replace the asset
        return expandTokens(input: sourceHtml, tokens: imageTokens) ?? ""
    }

    /// Returns the remote or local URL to use in asset replacement.
    ///  - Returns: A `String` containing either a cached URI, or a local asset name, or nil if neither is present.
    private func getAssetReplacement(assetArray: [String]) -> String? {
        guard !assetArray.isEmpty else { // edge case
            Log.debug(label: Self.LOG_TAG, "\(#function) - Cannot replace assets, the assets array is empty.")
            return nil
        }

        // first prioritize remote urls that are cached
        for asset in assetArray {
            if let url = URL(string: asset) {
//                if MessageAssetsDownloader.isAssetDownloadable(url: url) {
//                    let cacheService = ServiceProvider.shared.cacheService
//                    let messageId = self.messageId ?? ""
//                    let cacheEntry = cacheService.get(cacheName: CampaignConstants.Campaign.MESSAGE_CACHE_FOLDER + CampaignConstants.Campaign.PATH_SEPARATOR + messageId, key: asset)
//                    if let data = cacheEntry?.data {
//                        Log.trace(label: Self.LOG_TAG, "\(#function) - Replaced assets using cached assets.")
//                        return String(decoding: data, as: UTF8.self)
//                    }
//                }
            }
        }

        // then fallback to local urls
        for asset in assetArray {
            if let url = URL(string: asset) {
                // TODO: replace with implementation of campaignMessageAssetsCache
//                if MessageAssetsDownloader.isAssetDownloadable(url: url) {
//                    Log.trace(label: Self.LOG_TAG, "\(#function) - Replaced assets using local url.")
//                    self.isUsingLocalImage = true
//                    return asset
//                }
            }
        }
        return nil
    }
}
