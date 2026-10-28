import Foundation

/// Prices in US dollars per token. Field names match the LiteLLM price list. Missing prices are nil.
struct ModelPrice: Codable, Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheCreation: Double?
    var cacheCreationAboveOneHour: Double?

    enum CodingKeys: String, CodingKey {
        case input = "input_cost_per_token"
        case output = "output_cost_per_token"
        case cacheRead = "cache_read_input_token_cost"
        case cacheCreation = "cache_creation_input_token_cost"
        case cacheCreationAboveOneHour = "cache_creation_input_token_cost_above_1hr"
    }

    /// Cache writes use the five minute price. One hour writes use the one hour price, or the five minute price
    /// when the list has no one hour price.
    func cost(of record: UsageRecord) -> Double {
        let fiveMinuteWrites = record.cacheWrite - record.cacheWriteOneHour
        let oneHourPrice = cacheCreationAboveOneHour ?? cacheCreation ?? 0
        return Double(record.input) * (input ?? 0)
            + Double(record.output) * (output ?? 0)
            + Double(record.cacheRead) * (cacheRead ?? 0)
            + Double(fiveMinuteWrites) * (cacheCreation ?? 0)
            + Double(record.cacheWriteOneHour) * oneHourPrice
    }
}

/// The file written to the price cache directory.
struct PriceCacheContents: Codable, Equatable {
    var builtAt: Date
    var modelCount: Int
    var models: [String: ModelPrice]
}

enum PriceCacheError: Error, LocalizedError {
    case unexpectedFormat
    case noModels
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedFormat: return "The price list is not a json object."
        case .noModels: return "The price list has no models from the supported providers."
        case .httpStatus(let status): return "The price list download returned http status \(status)."
        }
    }
}

/// Pure functions to build, store and query the price cache, plus the download. Only the download uses the network.
enum PriceCache {
    static let sourceURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let includedProviders: Set<String> = [
        "anthropic", "openai", "gemini", "vertex_ai-language-models", "xai", "mistral", "deepseek"
    ]

    static func defaultFileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/com.evadnoob.tokenstatsbar/prices.json")
    }

    /// Keeps the entries of the included providers and only their price fields.
    static func filter(litellmJSON: Data) throws -> [String: ModelPrice] {
        guard let object = try JSONSerialization.jsonObject(with: litellmJSON) as? [String: Any] else {
            throw PriceCacheError.unexpectedFormat
        }
        var models: [String: ModelPrice] = [:]
        for (name, value) in object {
            guard let entry = value as? [String: Any],
                  let provider = entry["litellm_provider"] as? String,
                  includedProviders.contains(provider) else { continue }
            func number(_ key: String) -> Double? { (entry[key] as? NSNumber)?.doubleValue }
            models[name] = ModelPrice(
                input: number("input_cost_per_token"),
                output: number("output_cost_per_token"),
                cacheRead: number("cache_read_input_token_cost"),
                cacheCreation: number("cache_creation_input_token_cost"),
                cacheCreationAboveOneHour: number("cache_creation_input_token_cost_above_1hr"))
        }
        return models
    }

    /// Filters the LiteLLM json. An empty result is an error, so a bad download never replaces a good cache.
    static func contents(litellmJSON: Data, builtAt: Date) throws -> PriceCacheContents {
        let models = try filter(litellmJSON: litellmJSON)
        guard !models.isEmpty else { throw PriceCacheError.noModels }
        return PriceCacheContents(builtAt: builtAt, modelCount: models.count, models: models)
    }

    static func write(_ contents: PriceCacheContents, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(contents).write(to: fileURL, options: .atomic)
    }

    /// Nil when the file is missing or unreadable.
    static func read(from fileURL: URL) -> PriceCacheContents? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PriceCacheContents.self, from: data)
    }

    /// Exact name first, then the name without a trailing date suffix such as "-20250929".
    static func price(for model: String, in models: [String: ModelPrice]) -> ModelPrice? {
        if let exact = models[model] { return exact }
        guard let range = model.range(of: "-[0-9]{8}$", options: .regularExpression) else { return nil }
        return models[String(model[..<range.lowerBound])]
    }

    static func download() async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw PriceCacheError.httpStatus(status)
        }
        return data
    }
}

/// Owns the price cache file for the user interface: loads it, builds it and publishes the state.
@MainActor
final class PriceCacheController: ObservableObject {
    @Published private(set) var models: [String: ModelPrice] = [:]
    @Published private(set) var builtAt: Date?
    @Published private(set) var errorText: String?
    @Published private(set) var isRebuilding = false

    let fileURL: URL
    /// Called after the models changed, so the usage summary can be priced again.
    var onChange: (() -> Void)?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let contents = PriceCache.read(from: fileURL) { apply(contents) }
    }

    var modelCount: Int { models.count }

    /// Used on launch: downloads the price list only when there is no cache file.
    func buildIfMissing() {
        if builtAt == nil { rebuild() }
    }

    /// On failure the existing cache is kept and the error text is published.
    func rebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        let fileURL = fileURL
        Task {
            do {
                let contents = try await Task.detached {
                    let data = try await PriceCache.download()
                    let built = try PriceCache.contents(litellmJSON: data, builtAt: Date())
                    try PriceCache.write(built, to: fileURL)
                    return built
                }.value
                errorText = nil
                apply(contents)
                onChange?()
            } catch {
                errorText = "Rebuild failed: \(error.localizedDescription)"
            }
            isRebuilding = false
        }
    }

    private func apply(_ contents: PriceCacheContents) {
        models = contents.models
        builtAt = contents.builtAt
    }
}
