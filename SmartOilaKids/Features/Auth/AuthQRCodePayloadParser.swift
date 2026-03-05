import Foundation

struct AuthQRCodePayloadParseResult {
    let payload: AuthScanPayload
    let isContractV1: Bool
}

private struct AuthQRCodeExtractedFields {
    var token: String?
    var refreshToken: String?
    var parentPhone: String?
    var dsn: String?
    var deviceName: String?

    mutating func mergeMissing(from other: AuthQRCodeExtractedFields) {
        token = token ?? other.token
        refreshToken = refreshToken ?? other.refreshToken
        parentPhone = parentPhone ?? other.parentPhone
        dsn = dsn ?? other.dsn
        deviceName = deviceName ?? other.deviceName
    }

    var payload: AuthScanPayload {
        AuthScanPayload(
            token: token,
            refreshToken: refreshToken,
            parentPhone: parentPhone,
            dsn: dsn,
            deviceName: deviceName
        )
    }
}

struct AuthQRCodePayloadParser {
    // Preferred parent QR schema (v1):
    // {"schema":"smartoila.child.bind.v1","token":"...","refresh_token":"...","phone":"+998...","dsn":"abc-12-xyz","device_name":"Child 1"}
    // URL form is also supported via query items with the same keys.
    func parse(from rawCode: String) -> AuthQRCodePayloadParseResult {
        if let contractPayload = extractContractPayload(from: rawCode) {
            return AuthQRCodePayloadParseResult(payload: contractPayload, isContractV1: true)
        }

        return AuthQRCodePayloadParseResult(
            payload: extractLegacyAuthPayload(from: rawCode),
            isContractV1: false
        )
    }

    private func extractContractPayload(from rawCode: String) -> AuthScanPayload? {
        if let jsonPayload = AuthQRCodePayloadDecoder.decodeJSONObjectCandidate(rawCode),
           isContractPayload(jsonPayload) {
            let contractData = (jsonPayload["data"] as? [String: Any]) ?? jsonPayload
            return extractFields(from: contractData).payload
        }

        if let url = URL(string: rawCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let embedded = extractEmbeddedPayload(from: components),
               isContractPayload(embedded) {
                let contractData = (embedded["data"] as? [String: Any]) ?? embedded
                return extractFields(from: contractData).payload
            }

            guard hasContractMarker(in: components) else {
                return nil
            }

            return extractFields(from: components).payload
        }

        return nil
    }

    private func extractLegacyAuthPayload(from rawCode: String) -> AuthScanPayload {
        var extracted = AuthQRCodeExtractedFields()

        if let jsonPayload = AuthQRCodePayloadDecoder.decodeJSONObjectCandidate(rawCode) {
            extracted.mergeMissing(from: extractFields(from: jsonPayload))
            if let nested = jsonPayload["data"] as? [String: Any] {
                extracted.mergeMissing(from: extractFields(from: nested))
            }
        }

        if let url = URL(string: rawCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            extracted.mergeMissing(from: extractFields(from: components))

            if let embeddedPayload = extractEmbeddedPayload(from: components) {
                extracted.mergeMissing(from: extractFields(from: embeddedPayload))
            }
        }

        extracted.token = extracted.token ?? AuthQRCodeValueNormalizer.token(rawCode)
        return extracted.payload
    }

    private func extractFields(from payload: [String: Any]) -> AuthQRCodeExtractedFields {
        AuthQRCodeExtractedFields(
            token: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: payload,
                keys: AuthQRCodePayloadKeys.tokenFields,
                normalize: AuthQRCodeValueNormalizer.token
            ),
            refreshToken: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: payload,
                keys: AuthQRCodePayloadKeys.refreshTokenFields,
                normalize: AuthQRCodeValueNormalizer.token
            ),
            parentPhone: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: payload,
                keys: AuthQRCodePayloadKeys.phoneFields,
                normalize: AuthQRCodeValueNormalizer.phone
            ),
            dsn: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: payload,
                keys: AuthQRCodePayloadKeys.dsnFields,
                normalize: AuthQRCodeValueNormalizer.dsn
            ),
            deviceName: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: payload,
                keys: AuthQRCodePayloadKeys.deviceNameFields,
                normalize: AuthQRCodeValueNormalizer.deviceName
            )
        )
    }

    private func extractFields(from components: URLComponents) -> AuthQRCodeExtractedFields {
        AuthQRCodeExtractedFields(
            token: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: components,
                queryKeys: AuthQRCodePayloadKeys.tokenQueryKeys,
                includeAllQueryValues: true,
                includePathSegments: true,
                normalize: AuthQRCodeValueNormalizer.token
            ),
            refreshToken: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: components,
                queryKeys: AuthQRCodePayloadKeys.refreshTokenQueryKeys,
                normalize: AuthQRCodeValueNormalizer.token
            ),
            parentPhone: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: components,
                queryKeys: AuthQRCodePayloadKeys.phoneQueryKeys,
                includeAllQueryValues: true,
                normalize: AuthQRCodeValueNormalizer.phone
            ),
            dsn: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: components,
                queryKeys: AuthQRCodePayloadKeys.dsnQueryKeys,
                includeAllQueryValues: true,
                includePathSegments: true,
                normalize: AuthQRCodeValueNormalizer.dsn
            ),
            deviceName: AuthQRCodePayloadFieldResolver.extractNormalized(
                from: components,
                queryKeys: AuthQRCodePayloadKeys.deviceNameQueryKeys,
                includeAllQueryValues: true,
                normalize: AuthQRCodeValueNormalizer.deviceName
            )
        )
    }

    private func isContractPayload(_ payload: [String: Any]) -> Bool {
        if let marker = extractContractMarker(from: payload),
           AuthQRCodePayloadKeys.contractMarkers.contains(marker.lowercased()) {
            return true
        }

        if let nested = payload["data"] as? [String: Any],
           let marker = extractContractMarker(from: nested),
           AuthQRCodePayloadKeys.contractMarkers.contains(marker.lowercased()) {
            return true
        }

        return false
    }

    private func hasContractMarker(in components: URLComponents) -> Bool {
        AuthQRCodePayloadFieldResolver.hasContractMarker(
            in: components,
            markerQueryKeys: AuthQRCodePayloadKeys.contractMarkerQueryKeys,
            acceptedValues: AuthQRCodePayloadKeys.contractMarkers
        )
    }

    private func extractContractMarker(from payload: [String: Any]) -> String? {
        AuthQRCodePayloadFieldResolver.extractString(
            from: payload,
            keys: AuthQRCodePayloadKeys.contractMarkerFields
        )
    }

    private func extractEmbeddedPayload(from components: URLComponents) -> [String: Any]? {
        AuthQRCodePayloadFieldResolver.extractEmbeddedPayload(
            from: components,
            candidateKeys: AuthQRCodePayloadKeys.embeddedPayloadFields,
            decodeJSONObjectCandidate: AuthQRCodePayloadDecoder.decodeJSONObjectCandidate
        )
    }
}
