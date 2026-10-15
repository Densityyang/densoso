import Foundation
import DensosoDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The small transport boundary keeps Open Food Facts replaceable and makes
/// its parsing policy testable without making network requests in tests.
public protocol HTTPDataClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPDataClient: HTTPDataClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenFoodFactsError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public enum OpenFoodFactsError: Error, Equatable, Sendable {
    case missingUserAgent
    case invalidEndpoint
    case invalidResponse
    case barcodeMismatch
    case rateLimited
    case serviceUnavailable(statusCode: Int)
    case unexpectedStatus(statusCode: Int)
}

/// Open Food Facts adapter for packaged-food barcode lookups.
///
/// It deliberately returns provider data as an unconfirmed match only. The
/// caller must surface the attribution and obtain user confirmation before a
/// meal or HealthKit record can be created.
public struct OpenFoodFactsPackagedFoodProvider: PackagedFoodProvider {
    public static let providerID = "open-food-facts"
    public static let defaultAttribution = "Product data from Open Food Facts (ODbL); images, when used, are CC BY-SA."

    private let userAgent: String
    private let endpoint: URL
    private let client: any HTTPDataClient

    public init(
        userAgent: String,
        endpoint: URL = URL(string: "https://world.openfoodfacts.org")!,
        client: any HTTPDataClient = URLSessionHTTPDataClient()
    ) throws {
        let normalizedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserAgent.isEmpty else { throw OpenFoodFactsError.missingUserAgent }
        self.userAgent = normalizedUserAgent
        self.endpoint = endpoint
        self.client = client
    }

    public func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OpenFoodFactsError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "api/v2/product", barcode]
            .filter { !$0.isEmpty }
            .joined(separator: "/")) + ".json"
        components.queryItems = [URLQueryItem(name: "fields", value: "code,product_name,product_name_en,generic_name,brands,serving_quantity,serving_size,nutriments")]
        guard let url = components.url else { throw OpenFoodFactsError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await client.data(for: request)
        switch response.statusCode {
        case 200...299: break
        case 429: throw OpenFoodFactsError.rateLimited
        case 500...599: throw OpenFoodFactsError.serviceUnavailable(statusCode: response.statusCode)
        default: throw OpenFoodFactsError.unexpectedStatus(statusCode: response.statusCode)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == 1, let product = decoded.product else { return nil }
        if let returnedCode = decoded.code, returnedCode != barcode { throw OpenFoodFactsError.barcodeMismatch }

        let name = product.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return PackagedFoodMatch(
            barcode: barcode,
            displayName: name,
            servingGrams: product.servingGrams,
            caloriesPer100Grams: product.nutriments?.energyKcalPer100Grams,
            providerID: Self.providerID,
            attribution: Self.defaultAttribution
        )
    }
}

private extension OpenFoodFactsPackagedFoodProvider {
    struct Response: Decodable {
        let status: Int
        let code: String?
        let product: Product?
    }

    struct Product: Decodable {
        let productName: String?
        let productNameEnglish: String?
        let genericName: String?
        let brands: String?
        let servingQuantity: FlexibleNumber?
        let servingSize: String?
        let nutriments: Nutriments?

        enum CodingKeys: String, CodingKey {
            case productName = "product_name"
            case productNameEnglish = "product_name_en"
            case genericName = "generic_name"
            case brands
            case servingQuantity = "serving_quantity"
            case servingSize = "serving_size"
            case nutriments
        }

        var displayName: String {
            [productName, productNameEnglish, genericName, brands]
                .compactMap { $0 }
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        }

        var servingGrams: Double? {
            if let servingQuantity = servingQuantity?.value, servingQuantity > 0 { return servingQuantity }
            guard let servingSize else { return nil }
            let normalized = servingSize.lowercased().replacingOccurrences(of: ",", with: ".")
            guard normalized.contains("g") else { return nil }
            let number = normalized.split(whereSeparator: { !("0123456789.".contains($0)) }).first
            return number.flatMap { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    struct Nutriments: Decodable {
        let energyKcalPer100Grams: Double?

        enum CodingKeys: String, CodingKey {
            case energyKcalPer100Grams = "energy-kcal_100g"
        }
    }

    struct FlexibleNumber: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Double(text.replacingOccurrences(of: ",", with: ".")) {
                value = number
            } else {
                throw DecodingError.typeMismatch(
                    Double.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected a number or numeric string")
                )
            }
        }
    }
}
