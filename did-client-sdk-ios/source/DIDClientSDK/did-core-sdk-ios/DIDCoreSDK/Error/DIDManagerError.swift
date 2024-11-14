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

enum DIDManagerError: WalletCoreErrorProcotol {
    // Generate random (011xx)
    case failToGenerateRandom       // Fail to generate random
    
    // Create document (012xx)
    case documentIsAlreadyExists    // Document is already exists
    
    // Edit document (013xx)
    case duplicateKeyIDExistsInVerificationMethod   // Duplicate key ID exists in verification method
    case notFoundKeyIDInVerificationMethod          // Not found key ID in verification method
    case duplicateServiceIDExistsInService          // Duplicate service ID exists in service
    case notFoundServiceIDInService                 // Not found service ID in service
    case dontCallResetChangesIfNoDocumentSaved      // Don't call 'resetChanges' if no document saved
    
    // ETC (019xx)
    case unexpectedCondition        // Unexpected condition occurred
    
    
    func getCodeAndMessage() -> (String, String) {
        switch self {
            // Generate random (011xx)
        case .failToGenerateRandom:
            return ("01100", "Fail to generate random")
            
            // Create document (012xx)
        case .documentIsAlreadyExists:
            return ("01200", "Document is already exists")
            
            // Edit document (013xx)
        case .duplicateKeyIDExistsInVerificationMethod:
            return ("01300", "Duplicate key ID exists in verification method")
        case .notFoundKeyIDInVerificationMethod:
            return ("01301", "Not found key ID in verification method")
        case .duplicateServiceIDExistsInService:
            return ("01302", "Duplicate service ID exists in service")
        case .notFoundServiceIDInService:
            return ("01303", "Not found service ID in service")
        case .dontCallResetChangesIfNoDocumentSaved:
            return ("01304", "Don't call 'resetChanges' if no document saved")
            
            // ETC (019xx)
        case .unexpectedCondition:
            return ("01900", "Unexpected condition occurred")
        }
    }
}
