import Foundation
import Observation

// Bot avatar image and shape.
extension AppStore {
    static let avatarFileName = ".avatar.png"

    /// File holding a bot's uploaded avatar, when it has one.
    public func avatarImageURL(for bot: Bot) -> URL? {
        guard bot.avatarImageRev != nil,
              let dir = try? botHome.homeURL(botId: bot.id)
        else { return nil }
        let url = dir.appendingPathComponent(Self.avatarFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func setAvatarShape(botId: String, shape: BotAvatarShape) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        bots[idx].avatarShape = shape == .circle ? nil : shape.rawValue
        save()
    }

    /// `png` is already normalised (square, small) by the caller.
    public func setAvatarImage(botId: String, png: Data) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }),
              let dir = try? botHome.homeURL(botId: botId)
        else { return }
        do {
            try png.write(to: dir.appendingPathComponent(Self.avatarFileName), options: .atomic)
        } catch { return }
        bots[idx].avatarImageRev = (bots[idx].avatarImageRev ?? 0) + 1
        save()
    }

    public func clearAvatarImage(botId: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botId }) else { return }
        if let dir = try? botHome.homeURL(botId: botId) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.avatarFileName))
        }
        bots[idx].avatarImageRev = nil
        save()
    }
}
