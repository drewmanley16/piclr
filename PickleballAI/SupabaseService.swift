import Foundation
import Supabase

/// Reads Supabase.plist (gitignored). Copy Supabase.example.plist ->
/// Supabase.plist and fill in your project URL + anon key.
enum SupabaseConfig {
    static let url: URL = loaded.url
    static let anonKey: String = loaded.key
    static let isConfigured: Bool = loaded.configured

    private static let loaded: (url: URL, key: String, configured: Bool) = {
        let fallback = URL(string: "https://placeholder.supabase.co")!
        guard
            let path = Bundle.main.path(forResource: "Supabase", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path),
            let urlString = dict["SUPABASE_URL"] as? String,
            let key = dict["SUPABASE_ANON_KEY"] as? String,
            let url = URL(string: urlString)
        else {
            return (fallback, "", false)
        }
        let configured = !urlString.contains("YOUR-PROJECT")
            && !key.contains("YOUR-ANON")
            && !key.isEmpty
        return (configured ? url : fallback, key, configured)
    }()
}

/// App-wide Supabase client.
let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey
)
