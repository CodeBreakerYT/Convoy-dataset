import SwiftUI

// ============================================================
// PASTE YOUR PUBLIC GITHUB REPO LINK HERE  (the only thing to change)
// Repo layout:
//   bike/<Brand>/<Brand Model Year>.png     bike images (README.md is ignored)
//   logo/<brand>.png                        brand logos (matched to the brand folder name, case-insensitive)
// ============================================================
let githubRepoLink = "https://github.com/YOUR_USERNAME/YOUR_REPO"
let imagesFolder   = "bike"      // folder holding the brand folders
let logosFolder    = "logo"      // folder holding the brand logos
// ============================================================

// MARK: - Model

struct Bike: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String       // "Honda CBR650R 2022 STD"
    let category: String   // "Honda"
    let url: URL
}

struct BikeLibrary {
    var bikes: [Bike] = []
    var logos: [String: URL] = [:]            // logo file name (no extension) -> url
    var brands: [String] { Array(Set(bikes.map(\.category))).sorted() }

    private static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// "Harley-Davidson" matches "harley davidson.png"; "Hero MotoCorp" matches "hero.png".
    func logo(for brand: String) -> URL? {
        let b = Self.norm(brand)
        if let exact = logos.first(where: { Self.norm($0.key) == b }) { return exact.value }
        return logos.first { let l = Self.norm($0.key); return !l.isEmpty && (b.hasPrefix(l) || l.hasPrefix(b)) }?.value
    }
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

    static func load() async throws -> BikeLibrary {
        guard let (owner, repo) = ownerRepo(from: githubRepoLink) else { throw URLError(.badURL) }
        let cacheKey = "bikes.cache.\(owner).\(repo)"
        let stampKey = cacheKey + ".t"
        // GitHub allows 60 unauthenticated calls/hour per IP -> cache the list for 1 hour.
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: stampKey) < 3600,
           let list = try? JSONDecoder().decode([String].self, from: d) {
            return library(from: list, owner: owner, repo: repo)
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
            return library(from: paths, owner: owner, repo: repo)
        } catch {   // offline / rate-limited -> fall back to last saved list
            if let d = UserDefaults.standard.data(forKey: cacheKey),
               let list = try? JSONDecoder().decode([String].self, from: d) { return library(from: list, owner: owner, repo: repo) }
            throw error
        }
    }

    private static func rawURL(_ p: String, _ owner: String, _ repo: String) -> URL? {
        let enc = p.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(enc)")
    }

    private static func library(from paths: [String], owner: String, repo: String) -> BikeLibrary {
        let exts = ["png", "jpg", "jpeg", "webp"]
        let bp = imagesFolder.isEmpty ? "" : imagesFolder + "/"
        let lp = logosFolder.isEmpty ? "" : logosFolder + "/"
        var lib = BikeLibrary()
        for p in paths {
            if p.hasPrefix(bp) {
                let rel = String(p.dropFirst(bp.count)).split(separator: "/").map(String.init)
                guard rel.count == 2, exts.contains((rel[1] as NSString).pathExtension.lowercased()),
                      let url = rawURL(p, owner, repo) else { continue }
                lib.bikes.append(Bike(path: p, name: (rel[1] as NSString).deletingPathExtension, category: rel[0], url: url))
            } else if p.hasPrefix(lp) {
                let rel = String(p.dropFirst(lp.count))
                guard !rel.contains("/"), exts.contains((rel as NSString).pathExtension.lowercased()),
                      let url = rawURL(p, owner, repo) else { continue }
                lib.logos[(rel as NSString).deletingPathExtension] = url
            }
        }
        lib.bikes.sort { ($0.category, $0.name) < ($1.category, $1.name) }
        return lib
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

struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed || url == nil { placeholder() }
            else { ProgressView().tint(.orange) }
        }
        .task(id: url) {
            guard let url else { return }
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
    @Published var library = BikeLibrary()
    @Published var selected: String?          // nil = brand picker
    @Published var search = ""
    @Published var loading = false
    @Published var error: String?

    var results: [Bike] {
        library.bikes.filter {
            (selected == nil || $0.category == selected) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search))
        }
    }

    func load() async {
        loading = true; error = nil
        do { library = try await GitHubReader.load() }
        catch { self.error = "Couldn't read the repo. Check the link, that it's public, and your connection." }
        if library.bikes.isEmpty && error == nil { error = "No images found in \"\(imagesFolder)/\" of that repo." }
        loading = false
    }
}

// MARK: - Views

/// Garage "choose your bike": brand logos first -> tap a brand -> its bikes.
/// Use `onPick` to hand the chosen bike back to the garage.
struct BikeGalleryView: View {
    var onPick: ((Bike) -> Void)? = nil
    @StateObject private var vm = BikeGalleryModel()
    private let brandCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let bikeCols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if vm.loading {
                    ProgressView().tint(.orange).frame(maxHeight: .infinity)
                } else if let e = vm.error {
                    Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            brandStrip
                            if vm.selected == nil && vm.search.isEmpty { brandGrid } else { bikeGrid }
                        }.padding(.horizontal)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(vm.selected ?? "Find your bike")
            .toolbar {
                if vm.selected != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.snappy) { vm.selected = nil } } label: { Image(systemName: "chevron.left") }
                    }
                }
            }
            .searchable(text: $vm.search, prompt: "Search brand or model")
            .task { await vm.load() }
            .refreshable { await vm.load() }
        }
        .preferredColorScheme(.dark)
    }

    // Horizontal logo chips (category filter) shown above the bikes
    @ViewBuilder private var brandStrip: some View {
        if vm.selected != nil || !vm.search.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", logo: nil, active: vm.selected == nil) { vm.selected = nil }
                    ForEach(vm.library.brands, id: \.self) { b in
                        chip(b, logo: vm.library.logo(for: b), active: vm.selected == b) { vm.selected = b }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, logo: URL?, active: Bool, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if logo != nil { CachedImage(url: logo) { EmptyView() }.frame(width: 18, height: 18) }
            Text(title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(active ? Color.orange : Color.white.opacity(0.08), in: Capsule())
        .foregroundStyle(active ? .black : .white)
        .onTapGesture { withAnimation(.snappy, tap) }
    }

    private var brandGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BRANDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: brandCols, spacing: 12) {
                ForEach(vm.library.brands, id: \.self) { b in
                    VStack(spacing: 8) {
                        CachedImage(url: vm.library.logo(for: b)) {
                            Image(systemName: "bicycle").foregroundStyle(.secondary)
                        }.frame(width: 44, height: 44)
                        Text(b).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96).padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { withAnimation(.snappy) { vm.selected = b } }
                }
            }
        }
    }

    private var bikeGrid: some View {
        LazyVGrid(columns: bikeCols, spacing: 12) {
            ForEach(vm.results) { bike in
                BikeCard(bike: bike, logo: vm.library.logo(for: bike.category))
                    .onTapGesture { onPick?(bike) }
            }
        }
    }
}

struct BikeCard: View {
    let bike: Bike
    let logo: URL?
    var body: some View {
        VStack(spacing: 8) {
            CachedImage(url: bike.url) { Image(systemName: "photo").foregroundStyle(.secondary) }.frame(height: 110)
            HStack(spacing: 4) {
                if logo != nil { CachedImage(url: logo) { EmptyView() }.frame(width: 14, height: 14) }
                Text(bike.category).font(.caption2).foregroundStyle(.secondary)
            }
            Text(bike.name).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview { BikeGalleryView { print($0.name) } }
