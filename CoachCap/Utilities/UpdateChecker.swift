import Foundation

class UpdateChecker: ObservableObject {
    @Published var updateAvailable: (version: String, url: String)?
    @Published var isChecking = false

    private let currentVersion = "1.1"
    private let gitHubRepo = "spectrevisuals/CoachCam"

    func checkForUpdates() {
        isChecking = true

        let urlString = "https://api.github.com/repos/\(gitHubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            defer { DispatchQueue.main.async { self?.isChecking = false } }

            guard let data = data, error == nil else { return }

            do {
                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)

                let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

                if self?.isNewerVersion(latestVersion) ?? false {
                    DispatchQueue.main.async {
                        self?.updateAvailable = (latestVersion, release.htmlUrl)
                    }
                }
            } catch {
                // Silent fail - don't bother user with update check errors
            }
        }.resume()
    }

    private func isNewerVersion(_ remote: String) -> Bool {
        let current = currentVersion.split(separator: ".").compactMap { Int($0) }
        let latest = remote.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(current.count, latest.count) {
            let curr = i < current.count ? current[i] : 0
            let latest = i < latest.count ? latest[i] : 0
            if latest > curr { return true }
            if latest < curr { return false }
        }
        return false
    }
}

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
    }
}
