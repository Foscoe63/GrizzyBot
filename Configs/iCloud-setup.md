# iCloud container for GrizzyBot backups

GrizzyBot prefers the ubiquity container **`iCloud.com.grizzybot.app`** for automatic workspace backups. If that container is missing, it falls back to the user’s iCloud Drive `CloudDocs` folder, then `~/Documents`.

## Create the container (one-time)

1. Open [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list).
2. Click **+** → **iCloud Containers** → Continue.
3. Description: `GrizzyBot`
4. Identifier: `iCloud.com.grizzybot.app`
5. Save.

## Attach to the app ID

1. Identifiers → **App IDs** → `com.grizzybot.app` (create if needed).
2. Enable **iCloud** → include container `iCloud.com.grizzybot.app`.
3. Regenerate provisioning profiles if you use Manual signing.

## Release entitlements

Release builds use `Sources/GrizzyBot/GrizzyBot.Release.entitlements`, which lists:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.grizzybot.app</string>
</array>
```

Debug builds use `GrizzyBot.entitlements` without iCloud so ad-hoc/Xcode signing works without a team container.

## Verify on device

After a signed Release run, check **Settings → Backup** or Console for paths under:

`~/Library/Mobile Documents/iCloud~com~grizzybot~app/`

Exports and backups **never include API keys** — secrets live in Keychain only.
