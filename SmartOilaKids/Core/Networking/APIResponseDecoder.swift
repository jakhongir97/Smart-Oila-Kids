import Foundation

struct APIResponseDecoder {
    let decoder: JSONDecoder

    func detectEnvelopeError(in data: Data) -> NetworkError? {
        guard let envelope = try? decoder.decode(APIFailureEnvelope.self, from: data) else {
            return nil
        }

        guard envelope.status == false else {
            return nil
        }

        let body = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkError.server(
            statusCode: envelope.statusCode ?? 400,
            body: (body?.isEmpty == false ? body! : "Request failed")
        )
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
#if DEBUG
            let payloadText = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[APIClient] Decoding failed for \(String(describing: type))")
            print("[APIClient] Decoder error: \(error.localizedDescription)")
            print("[APIClient] Payload: \(payloadText)")
#endif
            throw NetworkError.decodingFailed
        }
    }
}
