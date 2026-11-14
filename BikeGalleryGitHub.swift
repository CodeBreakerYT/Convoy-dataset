import SwiftUI

// ============================================================
// PASTE YOUR PUBLIC GITHUB REPO LINK HERE  (the only thing to change)
// Repo layout:   bike/<Brand>/<Brand Model>.png      (README.md in bike/ is ignored)
// ============================================================
let githubRepoLink = "https://github.com/YOUR_USERNAME/YOUR_REPO"
let imagesFolder   = "bike"      // folder inside the repo that holds the brand folders
// ============================================================

// MARK: - Model

struct Bike: Identifiable, Hashable {
    var id: String { path }
    let path: String       // "bike/Honda/Honda CBR650R.png"
    let name: String       // "Honda CBR650R"
    let category: String   // "Honda"
    let url: URL
}

// MARK: - GitHub reader (lists the repo tree; no manifest needed)

enum GitHubReader {
    private struct Tree: Decodable { struct Node: Decodable { let path: String; let type: String }; let tree: [Node] }

    static func ownerRepo(from link: String) -> (String, String)? {
        let parts = link.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "").split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].contains("github.com") else { return nil }
        return (parts[1], parts[2].replacingOccurrences(of: ".git", with: ""))
    }

    static func loadBikes() async throws -> [Bike] {
        guard let (owner, repo) = ownerRepo(from: githubRepoLink) else { throw URLError(.badURL) }
        let cacheKey = "bikes.cache.\(owner).\(repo)"
        let stampKey = cacheKey + ".t"
        // GitHub allows 60 unauthenticated calls/hour per IP -> cache the list for 1 hour.
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: stampKey) < 3600,
           let list = try? JSONDecoder().decode([String].self, from: d) {
            return bikes(from: list, owner: owner, repo: repo)
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/HEAD?recursive=1")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let paths = try JSONDecoder().decode(Tree.self, from: data).tree.filter { $0.type == "blob" }.map(\.path)
            if let enc = try? JSONEncoder().encode(paths) {
                UserDefaults.standard.set(enc, forKey: cacheKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)
            }
            return bikes(from: paths, owner: owner, repo: repo)
        } catch {   // offline / rate-limited -> fall back to last saved list
            if let d = UserDefaults.standard.data(forKey: cacheKey),
               let list = try? JSONDecoder().decode([String].self, from: d) { return bikes(from: list, owner: owner, repo: repo) }
            throw error
        }
    }

    private static func bikes(from paths: [String], owner: String, repo: String) -> [Bike] {
        let exts = ["png", "jpg", "jpeg", "webp"]
        let prefix = imagesFolder.isEmpty ? "" : imagesFolder + "/"
        return paths.compactMap { p -> Bike? in
            guard p.hasPrefix(prefix) else { return nil }
            let rel = String(p.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            guard rel.count == 2, exts.contains((rel[1] as NSString).pathExtension.lowercased()) else { return nil }
            let enc = p.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(enc)") else { return nil }
            return Bike(path: p, name: (rel[1] as NSString).deletingPathExtension, category: rel[0], url: url)
        }.sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }
}

// MARK: - Cached image (downloads once, then loads from disk/memory)

enum ImageCache {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 500_000_000)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()
    static let mem = NSCache<NSURL, UIImage>()
}

struct CachedImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo").foregroundStyle(.secondary) }
            else { ProgressView().tint(.orange) }
        }
        .task(id: url) {
            if let hit = ImageCache.mem.object(forKey: url as NSURL) { image = hit; return }
            do {
                let (d, _) = try await ImageCache.session.data(from: url)
                if let img = UIImage(data: d) { ImageCache.mem.setObject(img, forKey: url as NSURL); image = img } else { failed = true }
            } catch { failed = true }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class BikeGalleryModel: ObservableObject {
    @Published var bikes: [Bike] = []
    @Published var selected = "All"
    @Published var search = ""
    @Published var loading = false
    @Published var error: String?

    var categories: [String] { ["All"] + Array(Set(bikes.map(\.category))).sorted() }
    var filtered: [Bike] {
        bikes.filter {
            (selected == "All" || $0.category == selected) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    func load() async {
        loading = true; error = nil
        do { bikes = try await GitHubReader.loadBikes() }
        catch { self.error = "Couldn't read the repo. Check the link, that it's public, and your connection." }
        if bikes.isEmpty && error == nil { error = "No images found in \"\(imagesFolder)/\" of that repo." }
        loading = false
    }
}

// MARK: - Views

struct BikeGalleryView: View {
    @StateObject private var vm = BikeGalleryModel()
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.categories, id: \.self) { c in
                            Text(c).font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(vm.selected == c ? Color.orange : Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(vm.selected == c ? .black : .white)
                                .onTapGesture { withAnimation(.snappy) { vm.selected = c } }
                        }
                    }.padding(.horizontal)
                }
                if vm.loading {
                    Spacer(); ProgressView().tint(.orange); Spacer()
                } else if let e = vm.error {
                    Spacer(); Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(); Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(vm.filtered) { BikeCard(bike: $0) }
                        }.padding(.horizontal)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Find your bike")
            .searchable(text: $vm.search, prompt: "Search model")
            .task { await vm.load() }
            .refreshable { await vm.load() }
        }
        .preferredColorScheme(.dark)
    }
}

struct BikeCard: View {
    let bike: Bike
    var body: some View {
        VStack(spacing: 8) {
            CachedImage(url: bike.url).frame(height: 110)
            Text(bike.category).font(.caption2).foregroundStyle(.secondary)
            Text(bike.name).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview { BikeGalleryView() }
