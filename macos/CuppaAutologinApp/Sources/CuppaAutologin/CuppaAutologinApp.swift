import AppKit
import CuppaEngine

@main
@MainActor
struct CuppaAutologinApp {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if EngineCLI.isEngineCommand(arguments) {
            let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            Task.detached {
                let result = await EngineCLI.execute(arguments: arguments, resources: resources)
                if !result.output.isEmpty { print(result.output) }
                if !result.error.isEmpty { FileHandle.standardError.write(Data((result.error + "\n").utf8)) }
                exit(result.status)
            }
            RunLoop.current.run()
            return
        }
        let application = NSApplication.shared
        let delegate = MenuBarAppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        // AppKit owns the menu-bar lifecycle; SwiftUI supplies the popover's
        // content without creating an unrelated window when the app launches.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
