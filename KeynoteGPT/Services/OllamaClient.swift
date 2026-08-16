import Foundation

enum OllamaClientError: LocalizedError {
    case unreachable(String, String)
    case http(Int, String)
    case invalidResponse
    case cancelled
    case timeout(Int)

    var errorDescription: String? {
        switch self {
        case .unreachable(let base, let reason):
            return "Cannot reach Ollama at \(base). Is it running? (\(reason))"
        case .http(let code, let body):
            return "Ollama HTTP \(code): \(body)"
        case .invalidResponse:
            return "Ollama returned an invalid response."
        case .cancelled:
            return "Cancelled"
        case .timeout(let seconds):
            return "Ollama request timed out after \(seconds)s. Try a smaller model or lower context."
        }
    }
}

struct OllamaModelInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
}

actor OllamaClient {
    func normalizeBase(_ url: String) throws -> String {
        try OllamaEndpointValidator.validatedBaseURL(url)
    }

    func listModels(baseURL: String) async throws -> [OllamaModelInfo] {
        let base: String
        do {
            base = try normalizeBase(baseURL)
        } catch {
            throw OllamaClientError.unreachable(baseURL, error.localizedDescription)
        }
        guard let url = URL(string: "\(base)/api/tags") else {
            throw OllamaClientError.unreachable(base, "invalid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw OllamaClientError.http(http.statusCode, body)
            }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map { OllamaModelInfo(name: $0.name) }.sorted { $0.name < $1.name }
        } catch let error as OllamaClientError {
            throw error
        } catch let error as URLError {
            throw OllamaClientError.unreachable(base, error.localizedDescription)
        }
    }

    func chatCompletion(
        baseURL: String,
        model: String,
        system: String,
        user: String,
        numCtx: Int = 0,
        timeout: TimeInterval = 600
    ) async throws -> String {
        let base: String
        do {
            base = try normalizeBase(baseURL)
        } catch {
            throw OllamaClientError.unreachable(baseURL, error.localizedDescription)
        }
        guard let url = URL(string: "\(base)/api/chat") else {
            throw OllamaClientError.unreachable(base, "invalid URL")
        }

        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if numCtx > 0 {
            payload["options"] = ["num_ctx": numCtx]
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OllamaClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw OllamaClientError.http(http.statusCode, "stream open failed")
            }

            var chunks: [String] = []
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.isEmpty {
                    chunks.append(content)
                }
                if obj["done"] as? Bool == true {
                    break
                }
            }
            return chunks.joined()
        } catch is CancellationError {
            throw OllamaClientError.cancelled
        } catch let error as OllamaClientError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaClientError.timeout(Int(timeout))
        } catch let error as URLError {
            throw OllamaClientError.unreachable(base, error.localizedDescription)
        }
    }
}

private struct TagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}
