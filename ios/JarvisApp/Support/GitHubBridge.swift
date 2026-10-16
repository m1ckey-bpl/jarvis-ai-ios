import Foundation

/// A repository as GitHub itself describes it, mapped into Swift values so the
/// UI never has to poke at raw JSON.
public struct GitHubRepository: Identifiable, Hashable, Sendable {
    public var id: Int
    public var owner: String
    public var name: String
    public var isPrivate: Bool
    public var defaultBranch: String
    public var description: String?
    public var htmlURL: String

    public var fullName: String { "\(owner)/\(name)" }
}

public struct GitHubIssueSummary: Sendable, Hashable {
    public var number: Int
    public var title: String
    public var htmlURL: String
}

public struct GitHubPullRequestSummary: Sendable, Hashable {
    public var number: Int
    public var htmlURL: String
    public var head: String
    public var base: String
}

/// One executed step of a coding-agent run. Reported individually so the user can
/// see exactly what happened, in order, and what failed.
public struct GitHubStepResult: Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var succeeded: Bool
}

/// Thin, honest adapter over `GitHubClient`.
///
/// Every method here performs a real API call or throws. Nothing is simulated and
/// nothing is reported as done until GitHub confirms it.
@MainActor
public final class GitHubBridge {

    private let client: GitHubClient?

    public init(client: GitHubClient?) { self.client = client }

    public var isConnected: Bool { client?.state() == .ready }

    private func requireClient() throws -> GitHubClient {
        guard let client else {
            throw JarvisError.unavailable(reason: "GitHub is not initialised in this build.")
        }
        guard client.state() == .ready else {
            throw JarvisError.providerNotConfigured
        }
        return client
    }

    // MARK: Reads

    public func repositories(limit: Int = 50) async throws -> [GitHubRepository] {
        let client = try requireClient()
        let raw = try await client.repositories(limit: limit)
        return raw.compactMap(Self.repository(from:))
    }

    /// Parses "owner/name", tolerating a full URL and a trailing ".git".
    public static func splitFullName(_ fullName: String) -> (owner: String, name: String)? {
        var value = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "github.com/") { value = String(value[range.upperBound...]) }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    public static func repository(from json: JSONValue) -> GitHubRepository? {
        guard let id = json["id"]?.intValue,
              let fullName = json["full_name"]?.stringValue,
              let owner = splitFullName(fullName)?.owner,
              let name = splitFullName(fullName)?.name else { return nil }
        return GitHubRepository(id: id,
                                owner: owner,
                                name: name,
                                isPrivate: json["private"]?.boolValue ?? false,
                                defaultBranch: json["default_branch"]?.stringValue ?? "main",
                                description: json["description"]?.stringValue,
                                htmlURL: json["html_url"]?.stringValue ?? "https://github.com/\(fullName)")
    }

    // MARK: Writes (each one is user-initiated and confirmed in the UI first)

    public func createIssue(repository: String, title: String, body: String) async throws -> GitHubIssueSummary {
        let client = try requireClient()
        guard let (owner, name) = Self.splitFullName(repository) else {
            throw JarvisError.invalidArguments("repository must be “owner/name”")
        }
        let json = try await client.createIssue(owner: owner, repo: name, title: title, body: body)
        guard let number = json["number"]?.intValue, let url = json["html_url"]?.stringValue else {
            throw JarvisError.providerBadResponse("GitHub did not confirm the issue details")
        }
        return GitHubIssueSummary(number: number, title: title, htmlURL: url)
    }

    /// The full coding-agent write path, executed as discrete, reported steps:
    ///  1. create the working branch from the default branch head,
    ///  2. commit the plan document to that branch,
    ///  3. open a pull request so the change is reviewable and revertible.
    ///
    /// A branch that already exists is reported as such and the run continues —
    /// JARVIS never force-pushes or rewrites history.
    public func applyPlan(repository: GitHubRepository,
                          branch: String,
                          baseBranch: String,
                          planText: String,
                          path: String) async throws -> [GitHubStepResult] {
        let client = try requireClient()
        var steps: [GitHubStepResult] = []

        // Step 1 — branch
        do {
            let head = try await client.headSHA(owner: repository.owner, repo: repository.name, branch: baseBranch)
            _ = try await client.createBranch(owner: repository.owner, repo: repository.name, branch: branch, fromSHA: head)
            steps.append(GitHubStepResult(title: "Branch created",
                                          detail: "origin/\(branch) from \(baseBranch) @ \(head.prefix(7))",
                                          succeeded: true))
        } catch let error as JarvisError {
            if case .providerBadResponse(let message) = error, message.lowercased().contains("already exists") {
                steps.append(GitHubStepResult(title: "Branch already exists",
                                              detail: "Reusing origin/\(branch) — nothing was overwritten.",
                                              succeeded: true))
            } else {
                steps.append(GitHubStepResult(title: "Branch creation failed", detail: error.userMessage, succeeded: false))
                throw error
            }
        }

        // Step 2 — commit the plan document
        do {
            let commit = try await client.commitFile(owner: repository.owner, repo: repository.name,
                                                     path: path, content: planText,
                                                     message: "docs: add JARVIS agent plan for \(branch)",
                                                     branch: branch)
            steps.append(GitHubStepResult(title: "Plan committed",
                                          detail: "\(path) — \(commit)",
                                          succeeded: true))
        } catch let error as JarvisError {
            steps.append(GitHubStepResult(title: "Commit failed", detail: error.userMessage, succeeded: false))
            throw error
        }

        // Step 3 — pull request
        do {
            let pr = try await client.openPullRequest(owner: repository.owner, repo: repository.name,
                                                      title: "JARVIS: plan for \(repository.name)",
                                                      head: branch, base: baseBranch,
                                                      body: planText)
            steps.append(GitHubStepResult(title: "Pull request #\(pr.number) opened",
                                          detail: pr.htmlURL, succeeded: true))
        } catch let error as JarvisError {
            steps.append(GitHubStepResult(title: "Pull request failed",
                                          detail: "The branch and commit exist; open the PR manually. \(error.userMessage)",
                                          succeeded: false))
        }
        return steps
    }
}
