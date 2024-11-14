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

import XCTest
import DIDUtilitySDK
@testable import DIDCoreSDK

final class SecureEnclaveManagerTests: XCTestCase {

    let groupName : String = "Test"
    let identifier: String = "myKey"
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testGenerateKey() throws
    {
        let publicKey = try SecureEnclaveManager.generateKey(group: groupName,
                                                             identifier: identifier,
                                                             accessMethod: .none)
        print("publicKey - \(publicKey.toHex())")
    }
    
    func testSign() throws
    {
        if SecureEnclaveManager.isKeySaved(group: groupName,
                                           identifier: identifier)
        {
            try SecureEnclaveManager.deleteKey(group: groupName,
                                           identifier: identifier)
        }
        
        let publicKey = try SecureEnclaveManager.generateKey(group: groupName,
                                                             identifier: identifier,
                                                             accessMethod: .none)
        print("publicKey - \(publicKey.toHex())")
        
        let plainData = "Test".data(using: .utf8)!
        let digest = DigestUtils.getDigest(source: plainData, digestEnum: .sha256)
        
        let signature = try SecureEnclaveManager.sign(group: groupName,
                                                      identifier: identifier,
                                                      digest: digest)
        
        print("signature - \(signature.toHex())")
        let result = try SecureEnclaveManager.verify(publicKey: publicKey,
                                                     digest: digest,
                                                     signature: signature)
        print("result - \(result)")
        
    }
    

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
