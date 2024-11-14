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

public struct RequestUpdateDidDoc: Jsonable {
    public var id: String
    public var txId: String
    public var serverToken: String
    public var didAuth: DIDAuth
    public var signedDidDoc: SignedDIDDoc
    
    public init(id: String, txId: String, serverToken: String, didAuth: DIDAuth, signedDidDoc: SignedDIDDoc) {
        self.id = id
        self.txId = txId
        self.serverToken = serverToken
        self.didAuth = didAuth
        self.signedDidDoc = signedDidDoc
    }
}

public struct _RequestUpdateDidDoc: Jsonable {
    public var txId: String
    
    public init(txId: String) {
        self.txId = txId
    }
}