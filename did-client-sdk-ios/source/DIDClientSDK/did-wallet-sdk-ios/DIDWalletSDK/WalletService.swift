/*
 * Copyright 2024 OmniOne.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import DIDDataModelSDK
import DIDUtilitySDK
import DIDCommunicationSDK
import DIDCoreSDK

class WalletService: WalletServiceImpl {
   
    let walletCore: WalletCoreImpl
    
    public init(_ walletCore: WalletCoreImpl) {
        self.walletCore = walletCore
    }
    
    public func deleteWallet() throws -> Bool {
        
        try CoreDataManager.shared.deleteUser()
        try CoreDataManager.shared.deleteToken()
        try CoreDataManager.shared.deleteCaPakage()
        return try walletCore.deleteWallet()
    }
    
    public func createWallet(tasURL: String, walletURL: String) async throws -> Bool {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard !walletURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("walletURL").getError()
        }
        
        // Fetch and save CA (Certified App) information
        try await self.fatchCaInfo(tasURL: tasURL)
        
        WalletLogger.shared.debug("fatchCaInfo completed")
        
        // Create a device key (device document)
        let deviceKey = try self.createDeviceDocument()
        WalletLogger.shared.debug("deviceKey completed")
        
        WalletLogger.shared.debug("deviceKey: \(try deviceKey.toJson(isPretty: true))")
        
        // Register the wallet using the provided URLs and the generated device key
        return try await self.requestRegisterWallet(tasURL: tasURL, walletURL: walletURL, ownerDidDoc: deviceKey)
    }
    
    public func requestVp(hWalletToken: String, claimInfos: [ClaimInfo]? = nil, verifierProfile: _RequestProfile?, APIGatewayURL: String, passcode: String? = nil) async throws -> (AccE2e, Data) {
        
        guard !hWalletToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("hWalletToken").getError()
        }
        guard let verifierProfile = verifierProfile else {
            throw WalletAPIError.verifyParameterFail("verifierProfile").getError()
        }
        guard !APIGatewayURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("APIGatewayURL").getError()
        }
        
        let roleType = RoleTypeEnum.Verifier
        // checkCertVcRef
        try await WalletToken(self.walletCore).verifyCertVcRef(roleType: roleType, providerDID:verifierProfile.profile.profile.verifier.did, providerURL: verifierProfile.profile.profile.verifier.certVcRef, APIGatewayURL: APIGatewayURL)
        
        let holderDidDoc = try WalletAPI.shared.getDidDocument(type: DidDocumentType.HolderDidDocumnet)

        let proof = Proof(created: Date.getUTC0Date(seconds: 0),
                          proofPurpose: ProofPurpose.keyAgreement,
                          verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + "#keyagree",
                          type: ProofType.secp256r1Signature2018)
        
        let keyPair = try CryptoUtils.generateECKeyPair(ecType: ECType.secp256r1)
        let iv = try CryptoUtils.generateNonce(size: 16)
        
        var accE2e = AccE2e(publicKey: MultibaseUtils.encode(type: MultibaseType.base58BTC, data: keyPair.publicKey),
                            iv: MultibaseUtils.encode(type: MultibaseType.base58BTC, data: iv),
                            proof: proof)
        
        let source = try DigestUtils.getDigest(source: accE2e.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature = try WalletAPI.shared.sign(keyId: "keyagree", data: source, type: DidDocumentType.HolderDidDocumnet)
        accE2e.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature)
        let presentationInfo = PresentationInfo(holder: holderDidDoc.id,
                                                validFrom: Date.getUTC0Date(seconds: 0),
                                                validUntil: Date.getUTC0Date(seconds: 5000),
                                                verifierNonce: verifierProfile.profile.profile.process.verifierNonce)

        var vp = try WalletAPI.shared.createVp(hWalletToken: hWalletToken, claimInfos: claimInfos!, presentationInfo: presentationInfo)
        let authType = passcode != nil ? "#pin" : "#bio"
        WalletLogger.shared.debug("vp: \(try vp.toJson())")
        let vpProof = Proof(created: Date.getUTC0Date(seconds: 0),
                            proofPurpose: ProofPurpose.assertionMethod,
                            verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + authType,
                            type: ProofType.secp256r1Signature2018)
        vp.proof = vpProof
        let vpSource = try DigestUtils.getDigest(source: vp.toJsonData(), digestEnum: DigestEnum.sha256)
        
        let vpSignature: Data?
        if passcode != nil {
            vpSignature = try walletCore.sign(keyId: "pin", pin: passcode?.data(using: .utf8), data: vpSource, type: DidDocumentType.HolderDidDocumnet)
        } else {
            vpSignature = try walletCore.sign(keyId: "bio", pin: nil, data: vpSource, type: DidDocumentType.HolderDidDocumnet)
        }
        vp.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: vpSignature!)
        let serverNonce = try MultibaseUtils.decode(encoded: verifierProfile.profile.profile.process.verifierNonce)
        let sessKey = try CryptoUtils.generateSharedSecret(ecType: ECType.secp256r1,
                                                           privateKey: keyPair.privateKey,
                                                           publicKey: MultibaseUtils.decode(encoded: verifierProfile.profile.profile.process.reqE2e.publicKey))
        
        let clientMergedSharedSecret = WalletUtil.mergeSharedSecretAndNonce(sharedSecret: sessKey, nonce: serverNonce, symmetricCipherType: SymmetricCipherType.aes256CBC)
        let encVp = try CryptoUtils.encrypt(plain: vp.toJsonData(), info: CipherInfo(cipherType: SymmetricCipherType.aes256CBC, padding: SymmetricPaddingType.pkcs5), key: clientMergedSharedSecret, iv: iv)
        return (accE2e, encVp)
    }
    
    private func fatchCaInfo(tasURL: String) async throws -> Void {
                                                                                     
        let data = try await CommnunicationClient().doGet(url: URL(string: tasURL + "/list/api/v1/allowed-ca/list?wallet=org.omnione.did.sdk.wallet")!)
        let allowCAList = try AllowCAList.init(from: data)
        
        guard allowCAList.count != 0 else {
            throw WalletAPIError.createWalletFail.getError()
        }
        try CoreDataManager.shared.deleteCaPakage()
        
        for item in allowCAList.items {
            try CoreDataManager.shared.insertCaPakage(pkgName: item)
        }
    }
    
    public func createSignedDIDDoc(passcode: String? = nil) throws -> SignedDIDDoc {
        
        let deviceDidDoc = try walletCore.getDidDocument(type: DidDocumentType.DeviceDidDocument)
        WalletLogger.shared.debug("saved deviceDidDoc: \(try deviceDidDoc.toJson())")
        var holderDidDoc = try walletCore.getDidDocument(type: DidDocumentType.HolderDidDocumnet)
        WalletLogger.shared.debug("saved holderDidDoc: \(try holderDidDoc.toJson())")
        let wallet = Wallet(id: Properties.getWalletId()!, did: deviceDidDoc.id)
        let nonce =  try CryptoUtils.generateNonce(size: 16)
        let hexNonce = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: nonce)
        
        var proofArry: [Proof] = .init()
        if try walletCore.isSavedKey(keyId: "pin") {
            var pinProof = Proof(created: Date.getUTC0Date(seconds: 0),
                                 proofPurpose: ProofPurpose.assertionMethod,
                                 verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + "#pin",
                                 type: ProofType.secp256r1Signature2018)
            
            holderDidDoc.proof = pinProof
            let firstSource = try DigestUtils.getDigest(source: holderDidDoc.toJsonData(), digestEnum: DigestEnum.sha256)
            WalletLogger.shared.debug("assert holderDidDoc Str: \(try holderDidDoc.toJson(isPretty: true))")
            
            let pinSignature = try walletCore.sign(keyId: "pin", pin: passcode?.data(using: .utf8), data: firstSource, type: DidDocumentType.HolderDidDocumnet)
            holderDidDoc.proof = nil
            pinProof.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: pinSignature)
            proofArry.append(pinProof)
        }
        
        if try walletCore.isSavedKey(keyId: "bio") {
            var bioProof = Proof(created: Date.getUTC0Date(seconds: 0),
                                 proofPurpose: ProofPurpose.assertionMethod,
                                 verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + "#bio",
                                 type: ProofType.secp256r1Signature2018)
            
            holderDidDoc.proof = bioProof
            let secondSource = try DigestUtils.getDigest(source: holderDidDoc.toJsonData(), digestEnum: DigestEnum.sha256)
            
            WalletLogger.shared.debug("auth holderDidDoc Str: \(try holderDidDoc.toJson(isPretty: true))")
            let bioSignature = try walletCore.sign(keyId: "bio", pin: nil, data: secondSource, type: DidDocumentType.HolderDidDocumnet)
            // (core func)
            holderDidDoc.proof = nil
            bioProof.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: bioSignature)
            proofArry.append(bioProof)
                
        }
        holderDidDoc.proofs = proofArry
        WalletLogger.shared.debug("final holderDidDoc Str: \(try holderDidDoc.toJson(isPretty: true))")
        let ownerDIDDoc = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: try holderDidDoc.toJsonData())
        // deviceKey
        let proof = Proof(created: Date.getUTC0Date(seconds: 0),
                        proofPurpose: ProofPurpose.assertionMethod,
                        verificationMethod: deviceDidDoc.id + "?versionId=" + deviceDidDoc.versionId + "#assert",
                        type: ProofType.secp256r1Signature2018)
        
        var signedDidDoc = SignedDIDDoc(ownerDidDoc: ownerDIDDoc, wallet: wallet, nonce: hexNonce, proof: proof)
        let source = try DigestUtils.getDigest(source: signedDidDoc.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature = try walletCore.sign(keyId: "assert", pin: nil, data: source, type: DidDocumentType.DeviceDidDocument)
        signedDidDoc.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature)
        WalletLogger.shared.debug("signed holderDidDoc Str: \(try signedDidDoc.toJson(isPretty: true))")
        return signedDidDoc
    }
    
    public func createProofs(ownerDidDoc: DIDDocument?, proofPurpose: String) throws -> Data {
        
        guard !proofPurpose.isEmpty else {
            throw WalletAPIError.verifyParameterFail("proofPurpose").getError()
        }
        guard let ownerDidDoc = ownerDidDoc else {
            throw WalletAPIError.verifyParameterFail("ownerDidDoc").getError()
        }
        
        var didDoc = ownerDidDoc
    
        var proofPurposeEnum: DIDDataModelSDK.ProofPurpose? = nil
        switch proofPurpose {
        case "assert", "pin", "bio":
            proofPurposeEnum = DIDDataModelSDK.ProofPurpose.assertionMethod
        case "auth":
            proofPurposeEnum = DIDDataModelSDK.ProofPurpose.authentication
        case "keyagree":
            proofPurposeEnum = DIDDataModelSDK.ProofPurpose.keyAgreement
        default:
            WalletLogger.shared.debug("proofPurpose: \(proofPurpose)")
        }
            
        didDoc.proof = DIDDataModelSDK.Proof(created: Date.getUTC0Date(seconds: 0), proofPurpose: proofPurposeEnum!, verificationMethod: didDoc.id+"?versionId="+didDoc.versionId+"#"+proofPurpose, type: DIDDataModelSDK.ProofType.secp256r1Signature2018)
        let source = try DigestUtils.getDigest(source: didDoc.toJsonData(), digestEnum: DigestEnum.sha256)
            
        return try walletCore.sign(keyId: proofPurpose, pin: nil, data: source, type: DidDocumentType.DeviceDidDocument)
    }
    
    public func createDeviceDocument() throws -> DIDDocument {
        // generate deviceKey
        var didDoc = try walletCore.createDeviceDidDocument()
        var proofArry: [Proof] = .init()
        var assertProof = DIDDataModelSDK.Proof(created: Date.getUTC0Date(seconds: 0), proofPurpose: DIDDataModelSDK.ProofPurpose.assertionMethod, verificationMethod: didDoc.id+"?versionId="+didDoc.versionId+"#assert", type: DIDDataModelSDK.ProofType.secp256r1Signature2018)
        didDoc.proof = assertProof
        let assertSource = try DigestUtils.getDigest(source: didDoc.toJsonData(), digestEnum: DigestEnum.sha256)
        WalletLogger.shared.debug("assert didDoc Str: \(try didDoc.toJson())")
        let assertSignature = try walletCore.sign(keyId: "assert", pin: nil, data: assertSource, type: DidDocumentType.DeviceDidDocument)
        didDoc.proof = nil
        assertProof.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: assertSignature)
        proofArry.append(assertProof)
        
        var authProof = DIDDataModelSDK.Proof(created: Date.getUTC0Date(seconds: 0), proofPurpose: DIDDataModelSDK.ProofPurpose.authentication, verificationMethod: didDoc.id+"?versionId="+didDoc.versionId+"#auth", type: DIDDataModelSDK.ProofType.secp256r1Signature2018)
        
        didDoc.proof = authProof
        let authSource = try DigestUtils.getDigest(source: didDoc.toJsonData(), digestEnum: DigestEnum.sha256)

        WalletLogger.shared.debug("auth didDoc Str: \(try didDoc.toJson())")
        let authSignature = try walletCore.sign(keyId: "auth", pin: nil, data: authSource, type: DidDocumentType.DeviceDidDocument)
        // (core func)
        didDoc.proof = nil
        authProof.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: authSignature)
        proofArry.append(authProof)
        didDoc.proofs = proofArry
        WalletLogger.shared.debug("fianl didDoc Str: \(try didDoc.toJson())")
        return didDoc
    }
    
    public func requestRegisterWallet(tasURL: String, walletURL: String, ownerDidDoc: DIDDocument?) async throws -> Bool {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard !walletURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("walletURL").getError()
        }
        guard let ownerDidDoc = ownerDidDoc else {
            throw WalletAPIError.verifyParameterFail("ownerDidDoc").getError()
        }
        
        let ownerDidDocJsonData = try ownerDidDoc.toJsonData()
        let responseData = try await CommnunicationClient().doPost(url: URL(string:walletURL + "/wallet/api/v1/request-sign-wallet")!, requestJsonData: ownerDidDocJsonData)
        let attDIDDoc = try AttestedDIDDoc.init(from: responseData)
        let reqAttDidDoc = RequestAttestedDIDDoc(id: WalletUtil.generateMessageID(), attestedDIDDoc: attDIDDoc)
        _ = try await CommnunicationClient().doPost(url: URL(string: tasURL + "/tas/api/v1/request-register-wallet")!, requestJsonData: try reqAttDidDoc.toJsonData())
        Properties.setWalletId(id: attDIDDoc.walletId)
        WalletLogger.shared.debug("saved walletId")
        try walletCore.saveDidDocument(type: DidDocumentType.DeviceDidDocument)
        return true
    }
    
    public func bindUser() throws -> Bool {
        
        if let token = try CoreDataManager.shared.selectToken() {
            WalletLogger.shared.debug("bindUser verifyWalletToken 등록 성공")
            try CoreDataManager.shared.insertUser(finalEncKey: "", pii: token.pii)
            return true
        } else {
            WalletLogger.shared.debug("bindUser selectToken 실패")
            throw WalletAPIError.selectQueryFail.getError()
        }
    }
    
    public func unbindUser() throws -> Bool {
        return try CoreDataManager.shared.deleteUser()
    }
    
    // user restore (didDoc)
    public func requestRegisterUser(tasURL: String, txId: String, serverToken: String, signedDIDDoc: SignedDIDDoc?) async throws -> _RequestRegisterUser {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard !txId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("txId").getError()
        }
        guard !serverToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("serverToken").getError()
        }
        guard let signedDIDDoc = signedDIDDoc else {
            throw WalletAPIError.verifyParameterFail("signedDIDDoc").getError()
        }
        
        let parameter = try RequestRegisterUser(id: WalletUtil.generateMessageID(), txId: txId, signedDidDoc: signedDIDDoc, serverToken: serverToken).toJsonData()
        let responseData = try await CommnunicationClient().doPost(url: URL(string: tasURL)!, requestJsonData: parameter)
        return try _RequestRegisterUser.init(from: responseData)
    }
    
    // user restore (didDoc)
    public func requestRestoreUser(tasURL: String, txId: String, serverToken: String, didAuth: DIDAuth?) async throws -> _RequestRestoreDidDoc {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard !txId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("txId").getError()
        }
        guard !serverToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("serverToken").getError()
        }
        guard let didAuth = didAuth else {
            throw WalletAPIError.verifyParameterFail("didAuth").getError()
        }
        
        let parameter = try RequestRestoreDidDoc(id: WalletUtil.generateMessageID(), txId: txId, serverToken: serverToken, didAuth: didAuth).toJsonData()
        let responseData = try await CommnunicationClient().doPost(url: URL(string: tasURL)!, requestJsonData: parameter)
        return try _RequestRestoreDidDoc.init(from: responseData)
    }
    
    // user update (didDoc)
    public func requestUpdateUser(tasURL: String, txId: String, serverToken: String, didAuth: DIDAuth?, signedDIDDoc: SignedDIDDoc?) async throws -> _RequestUpdateDidDoc {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard !txId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("txId").getError()
        }
        guard !serverToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("serverToken").getError()
        }
        guard let didAuth = didAuth else {
            throw WalletAPIError.verifyParameterFail("didAuth").getError()
        }
        
        guard let signedDIDDoc = signedDIDDoc else {
            throw WalletAPIError.verifyParameterFail("signedDIDDoc").getError()
        }
        
        let parameter = try RequestUpdateDidDoc(id: WalletUtil.generateMessageID(), txId: txId, serverToken: serverToken, didAuth: didAuth, signedDidDoc: signedDIDDoc).toJsonData()/*RequestUpdateDidDoc(id: WalletUtil.generateMessageID(), txId: txId, serverToken: serverToken, didAuth: didAuth, signedDIDDoc: signedDIDDoc).toJsonData()*/
        
        let responseData = try await CommnunicationClient().doPost(url: URL(string: tasURL)!, requestJsonData: parameter)
        return try _RequestUpdateDidDoc.init(from: responseData)
    }
    
    
    public func getSignedDidAuth(authNonce: String, passcode: String? = nil) throws -> DIDAuth {
        
        guard !authNonce.isEmpty else {
            throw WalletAPIError.verifyParameterFail("authNonce").getError()
        }
        // 1. query did
        var didDoc = try walletCore.getDidDocument(type: DidDocumentType.HolderDidDocumnet)
        // 2. except proofValue and generate proof
        let authType = passcode != nil ? "#pin" : "#bio"
        let proof = Proof(created: Date.getUTC0Date(seconds: 0),
                        proofPurpose: ProofPurpose.authentication,
                        verificationMethod: didDoc.id + "?versionId=" + didDoc.versionId + authType,
                        type: ProofType.secp256r1Signature2018)
        didDoc.proof = proof
        // 3. prepare holder did, authnonce, proof(except proofValue)
        var didAuth = DIDAuth(did: didDoc.id, authNonce: authNonce, proof: proof)
        // 4. digest for signature
        let source = try DigestUtils.getDigest(source: didAuth.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature: Data?
        if passcode != nil {
            signature = try walletCore.sign(keyId: "pin", pin: passcode?.data(using: .utf8), data: source, type: DidDocumentType.HolderDidDocumnet)
        } else {
            signature = try walletCore.sign(keyId: "bio", pin: nil, data: source, type: DidDocumentType.HolderDidDocumnet)
        }
        // 5. proofValue in DidAuth
        didAuth.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature!)
        return didAuth
    }
    
    public func requestIssueVc(tasURL: String, didAuth: DIDAuth?, issuerProfile: _RequestIssueProfile?, refId: String, serverToken: String, APIGatewayURL: String) async throws -> (String, _RequestIssueVc?) {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
        guard let didAuth = didAuth else {
            throw WalletAPIError.verifyParameterFail("didAuth").getError()
        }
        guard let issuerProfile = issuerProfile else {
            throw WalletAPIError.verifyParameterFail("issuerProfile").getError()
        }
        guard !refId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("refId").getError()
        }
        guard !serverToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("serverToken").getError()
        }
        guard !APIGatewayURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("APIGatewayURL").getError()
        }

        let roleType = RoleTypeEnum.Issuer
        // checkCertVcRef
        try await WalletToken(self.walletCore).verifyCertVcRef(roleType: roleType, providerDID:issuerProfile.profile.profile.issuer.did, providerURL: issuerProfile.profile.profile.issuer.certVcRef, APIGatewayURL: APIGatewayURL)
        
        let holderDidDoc = try walletCore.getDidDocument(type: DidDocumentType.HolderDidDocumnet)
        let proof = Proof(created: Date.getUTC0Date(seconds: 0),
                        proofPurpose: ProofPurpose.keyAgreement,
                          verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + "#keyagree",
                        type: ProofType.secp256r1Signature2018)
        
        
        let keyPair = try CryptoUtils.generateECKeyPair(ecType: ECType.secp256r1)
        let iv = try CryptoUtils.generateNonce(size: 16)
        var accE2e = AccE2e(publicKey: MultibaseUtils.encode(type: MultibaseType.base58BTC, data: keyPair.publicKey),
                            iv: MultibaseUtils.encode(type: MultibaseType.base58BTC, data: iv),
                            proof: proof)
        
        let source = try DigestUtils.getDigest(source: accE2e.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature = try walletCore.sign(keyId: "keyagree", pin: nil, data: source, type: DidDocumentType.HolderDidDocumnet)
        accE2e.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature)
        let reqVcProfile = ReqVcProfile(id: issuerProfile.profile.id, issuerNonce: issuerProfile.profile.profile.process.issuerNonce)
        let reqVC = ReqVC(refId: refId, profile: reqVcProfile)
        WalletLogger.shared.debug("reqVc: \(try reqVC.toJson(isPretty: true))")
        let serverNonce = try MultibaseUtils.decode(encoded: issuerProfile.profile.profile.process.issuerNonce)
        // generate sessionk ey
        let sessKey = try CryptoUtils.generateSharedSecret(ecType: ECType.secp256r1,
                                                           privateKey: keyPair.privateKey,
                                                           publicKey: MultibaseUtils.decode(encoded: issuerProfile.profile.profile.process.reqE2e.publicKey))
        
        let clientMergedSharedSecret = WalletUtil.mergeSharedSecretAndNonce(sharedSecret: sessKey, nonce: serverNonce, symmetricCipherType: SymmetricCipherType.aes256CBC)

        let encReqVc = try CryptoUtils.encrypt(plain: reqVC.toJsonData(), 
                                               info: CipherInfo(cipherType: SymmetricCipherType.aes256CBC,
                                                                padding: SymmetricPaddingType.pkcs5),
                                               key: clientMergedSharedSecret, 
                                               iv: iv)
        
        let multiEncReqVc = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: encReqVc)
        let parameter = try RequestIssueVc(id: WalletUtil.generateMessageID(), txId: issuerProfile.txId, serverToken: serverToken, didAuth: didAuth, accE2e: accE2e, encReqVc: multiEncReqVc).toJsonData()
        let responseData = try await CommnunicationClient().doPost(url: URL(string: tasURL)!, requestJsonData: parameter)
        let decodedResponse = try _RequestIssueVc.init(from: responseData)
        let envVc = try MultibaseUtils.decode(encoded: decodedResponse.e2e.encVc)
        
        let decVc = try CryptoUtils.decrypt(cipher: envVc,
                                            info: CipherInfo(cipherType: SymmetricCipherType.aes256CBC, padding: SymmetricPaddingType.pkcs5),
                                            key: clientMergedSharedSecret,
                                            iv: MultibaseUtils.decode(encoded: decodedResponse.e2e.iv))
        
        var vc = try VerifiableCredential(from: decVc)
        let data = try await CommnunicationClient().doGet(url: URL(string: APIGatewayURL + "/api-gateway/api/v1/did-doc?did=" + vc.issuer.id)!)
        let DIDDoc = try DIDDocVO.init(from: data)
        let issuerDIDDocJson = try MultibaseUtils.decode(encoded: DIDDoc.didDoc)
        let issuerDIDDoc = try DIDDocument.init(from: issuerDIDDocJson)
        WalletLogger.shared.debug("issuerDIDDoc: \(try issuerDIDDoc.toJson(isPretty: true))")
        
        let tempProofValue = vc.proof.proofValue
        let tempProofValueList = vc.proof.proofValueList
        
        // verify issuer proof
        for method in issuerDIDDoc.verificationMethod {
            if method.id == "assert" {
                let pubKey = try MultibaseUtils.decode(encoded: method.publicKeyMultibase)
                let signature = try MultibaseUtils.decode(encoded: vc.proof.proofValue!)
                vc.proof.proofValue = nil
                vc.proof.proofValueList = nil
                let digest = DigestUtils.getDigest(source: try vc.toJsonData(), digestEnum: .sha256)
                let result = try walletCore.verify(publicKey: pubKey, data: digest, signature: signature)
                WalletLogger.shared.debug("result: \(result)")
                guard result else {
                    throw WalletAPIError.verifyCertVCFail.getError()
                }
            }
        }
        
        if walletCore.isAnyCredentialsSaved() {
            let vcs = try walletCore.getAllCredentials()
            for v in vcs {
                if v.credentialSchema.id == vc.credentialSchema.id {
                    WalletLogger.shared.debug("v.credentialSchema.id: \(v.credentialSchema.id)")
                    WalletLogger.shared.debug("vc.credentialSchema.id: \(vc.credentialSchema.id)")
                    _ = try walletCore.deleteCredential(ids: [v.id])
                }
            }
        }
        
        vc.proof.proofValue = tempProofValue
        vc.proof.proofValueList = tempProofValueList
        
        WalletLogger.shared.debug("vc!!!!!: \(try vc.toJson(isPretty: true))")
        
        _ = try walletCore.addCredential(credential: vc)
        
        return (vc.id, decodedResponse)
    }
    
    public func requestRevokeVc(tasURL: String, authType: VerifyAuthType, vcId: String, issuerNonce:String, txId: String, serverToken: String, passcode: String? = nil) async throws -> _RequestRevokeVc {
        
        guard !tasURL.isEmpty else {
            throw WalletAPIError.verifyParameterFail("tasURL").getError()
        }
//        guard let authType = authType else {
//            throw WalletAPIError.verifyParameterFail("authType").getError()
//        }
        guard !vcId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("vcId").getError()
        }
        guard !issuerNonce.isEmpty else {
            throw WalletAPIError.verifyParameterFail("issuerNonce").getError()
        }
        guard !txId.isEmpty else {
            throw WalletAPIError.verifyParameterFail("txId").getError()
        }
        guard !serverToken.isEmpty else {
            throw WalletAPIError.verifyParameterFail("serverToken").getError()
        }
        
        let holderDidDoc = try WalletAPI.shared.getDidDocument(type: DidDocumentType.HolderDidDocumnet)
        let authType = passcode != nil ? "#pin" : "#bio"
        let revokeProof = Proof(created: Date.getUTC0Date(seconds: 0),
                            proofPurpose: ProofPurpose.assertionMethod,
                            verificationMethod: holderDidDoc.id + "?versionId=" + holderDidDoc.versionId + authType,
                            type: ProofType.secp256r1Signature2018)
        
        var reqRevokeVc = ReqRevokeVc(vcId: vcId, issuerNonce: issuerNonce)
        reqRevokeVc.proof = revokeProof
        
        let reqRevokeVcSource = try DigestUtils.getDigest(source: reqRevokeVc.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature: Data?
        if passcode != nil {
            signature = try walletCore.sign(keyId: "pin", pin: passcode?.data(using: .utf8), data: reqRevokeVcSource, type: DidDocumentType.HolderDidDocumnet)
        } else {
            signature = try walletCore.sign(keyId: "bio", pin: nil, data: reqRevokeVcSource, type: DidDocumentType.HolderDidDocumnet)
        }
                    
        reqRevokeVc.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature!)
        let parameter = try RequestRevokeVc.init(id: WalletUtil.generateMessageID(), txId: txId, serverToken: serverToken, request: reqRevokeVc).toJsonData()
        let responseData = try await CommnunicationClient().doPost(url: URL(string: tasURL)!, requestJsonData: parameter)
        return try _RequestRevokeVc.init(from: responseData)
    }

    
    public func getSignedWalletInfo() throws -> SignedWalletInfo {
        
        let didDoc = try walletCore.getDidDocument(type: DidDocumentType.DeviceDidDocument)
        let proof = Proof(created: Date.getUTC0Date(seconds: 0),
                        proofPurpose: ProofPurpose.assertionMethod,
                        verificationMethod: didDoc.id+"?versionId="+didDoc.versionId+"#assert",
                        type: ProofType.secp256r1Signature2018)
        
        let wallet = Wallet(id: Properties.getWalletId()!, did: didDoc.id)
        let nonce = try CryptoUtils.generateNonce(size: 16)
        let hexNonce = MultibaseUtils.encode(type: MultibaseType.base58BTC, data:nonce)
        var signedWalletInfo = SignedWalletInfo(wallet: wallet, nonce: hexNonce, proof: proof)
        
        WalletLogger.shared.debug("signedWalletInfo: \(try signedWalletInfo.toJson())")
        let source = try DigestUtils.getDigest(source: signedWalletInfo.toJsonData(), digestEnum: DigestEnum.sha256)
        let signature = try walletCore.sign(keyId: "assert", pin: nil, data: source, type: DidDocumentType.DeviceDidDocument)
        signedWalletInfo.proof?.proofValue = MultibaseUtils.encode(type: MultibaseType.base58BTC, data: signature)
        return signedWalletInfo
    }
}
