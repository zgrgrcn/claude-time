/// Release metadata. `version` is the single source of truth: the CLI prints it for `--version`,
/// and `Scripts/make-app.sh` / `Scripts/make-release.sh` stamp it into the app's Info.plist.
public enum ClaudeTime {
    public static let version = "0.1.0"
}
