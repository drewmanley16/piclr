import Foundation

// MARK: - Gear

enum GearCategory: String, CaseIterable, Identifiable {
    case paddle = "Paddle"
    case balls = "Balls"
    case shoes = "Shoes"
    case bag = "Bag"
    case apparel = "Apparel"
    case accessory = "Accessory"
    case other = "Other"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .paddle: return "figure.pickleball"
        case .balls: return "circle.hexagongrid.fill"
        case .shoes: return "shoe"
        case .bag: return "bag"
        case .apparel: return "tshirt"
        case .accessory: return "eyeglasses"
        case .other: return "shippingbox"
        }
    }

    /// Placeholder for the name field, tailored to the category.
    var namePlaceholder: String {
        switch self {
        case .paddle:    return "e.g. Perseus 16mm"
        case .balls:     return "e.g. Franklin X-40"
        case .shoes:     return "e.g. K-Swiss Express"
        case .bag:       return "e.g. Sling bag"
        case .apparel:   return "e.g. Performance tee"
        case .accessory: return "e.g. Overgrip"
        case .other:     return "Name"
        }
    }
}

struct GearItem: Identifiable, Decodable, Hashable {
    let id: UUID
    let userId: UUID
    let category: String
    let name: String
    let brand: String?
    let photoPath: String?
    /// Signed URL filled in by `MediaHydrator.hydrateGear` — never decoded.
    var photoUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case photoPath = "photo_path"
        case category, name, brand
    }

    var categoryIcon: String {
        GearCategory(rawValue: category)?.systemImage ?? "shippingbox"
    }

    /// Secondary line wherever an item is listed — locker rows and the profile
    /// showcase read the same, so it lives on the model.
    var subtitle: String {
        if let brand, !brand.isEmpty { return "\(brand) · \(category)" }
        return category
    }
}

struct NewGear: Encodable {
    /// Generated client-side so the photo can be uploaded to its final path
    /// (`<uid>/<gear-id>.jpg`) before the row exists.
    let id: UUID
    let userId: UUID
    let category: String
    let name: String
    let brand: String?
    let photoPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case photoPath = "photo_path"
        case category, name, brand
    }
}

/// Attaches a freshly uploaded photo to a row that already exists — the add
/// flow's second step, kept narrow so it can't disturb the other fields.
struct GearPhotoPathUpdate: Encodable {
    let photoPath: String

    enum CodingKeys: String, CodingKey {
        case photoPath = "photo_path"
    }
}

struct GearUpdate: Encodable {
    let category: String
    let name: String
    let brand: String?
    let photoPath: String?

    enum CodingKeys: String, CodingKey {
        case photoPath = "photo_path"
        case category, name, brand
    }
}

struct GearVisibilityUpdate: Encodable {
    let gearVisible: Bool

    enum CodingKeys: String, CodingKey {
        case gearVisible = "gear_visible"
    }
}

/// What an edit does to an item's photo. Distinguishing "left alone" from
/// "cleared" matters — both arrive as no new image data.
enum GearPhotoEdit {
    case unchanged
    case replaced(Data)
    case removed
}

/// Who's looking at a locker. `.owner` reads `store.gear` and can add, remove,
/// and change visibility; `.viewer` is a read-only snapshot of someone else's
/// gear, already filtered by RLS before it ever reaches the client.
enum GearLockerMode: Hashable {
    case owner
    case viewer(name: String, items: [GearItem])
}
