//
// HaloXBuilder.swift – native Swift/AppKit GUI front-end for
// scripts/build-local.sh. It presents every build option as a
// field prefilled with the script's defaults, streams the build
// output live into a console-style log, and shows the result
// (the FAIL: message or a success notice) in a sheet.
//
// Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
// See the LICENSE file for details.
//
// The app bundle is produced in the repo root by build.sh; the
// parent of the bundle path is the repository root, which is how
// the builder locates scripts/build-local.sh and assets/shield.icns.
//

import AppKit

// Host architecture, used as the default for the --arch popup.
#if arch(arm64)
let defaultArch = "arm64"
#else
let defaultArch = "x86_64"
#endif

// Shared border color of the two framed scroll areas.
// It matches the bezel border of the former output
// area (the darker gray, not the lighter window frame).
let frameBorderColor = NSColor(white: 0.27, alpha: 1.0)

// Color of the field labels: a light blue that stays
// readable on the dark background.
let fieldLabelColor = NSColor(hex: "#9ee9f9")

// Background color of the primary (Build) button.
let buttonColor = NSColor(hex: "#4c7077")

// Console-style font for the build output.
let logFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

// Fixed -vidmode presets for the popup, mirroring the table in
// scripts/vidmode-presets.sh (the single source of truth for the
// scripts and the CI workflow; duplicated here for the GUI).
let vidmodePresets: [(name: String, value: String)] = [
    ("macbook-air-13", "1470,956,60"),
    ("macbook-air-13-max", "1710,1112,60"),
    ("macbook-air-13-old", "1440,900,60"),
    ("macbook-air-13-old-max", "1680,1050,60"),
    ("macbook-air-15", "1710,1107,60"),
    ("macbook-air-15-max", "1920,1243,60"),
    ("macbook-pro-14", "1512,982,60"),
    ("macbook-pro-14-max", "1800,1169,60"),
    ("macbook-pro-16", "1728,1117,60"),
    ("macbook-pro-16-max", "2056,1329,60"),
]

private extension String {
    /// Strip ANSI escape sequences (terminal color codes).
    var stripANSI: String {
        replacingOccurrences(of: "\\x1b\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }
}

private extension NSColor {
    /// Create a color from a hex string like "#9ee9f9".
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(digits, radix: 16) ?? 0
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

// A vertical stack view with a flipped coordinate system, so its
// content is laid out from the top. Inside a scroll view it
// therefore starts scrolled to the top by default.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// A plain view with a flipped coordinate system, used as the
// document view of a scroll view. The content stack view sits
// inside it with a margin, which the scroll view's own frame
// management would otherwise override.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A thin, draggable divider that resizes the output area.
/// Dragging it also grows or shrinks the window, so the form
/// area keeps its size while only the output area changes.
final class ResizeDividerView: NSView {
    /// Called with the vertical drag delta in points,
    /// positive when the user drags downward.
    var onResize: ((CGFloat) -> Void)?
    private var lastY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        let delta = lastY - y
        lastY = y
        onResize?(delta)
    }
}

/// A label styled as a clickable link (blue, underlined): plain link
/// text, not a button. Clicking it runs `onClick`.
final class LinkLabel: NSTextField {
    var onClick: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                // Same color as the field labels (fieldLabelColor).
                .foregroundColor: fieldLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow the click (the field is not selectable, so nothing
        // starts editing); the action runs on mouse up.
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

/// Returns a Selector from a string (used for undo:/redo:, which have
/// no public Swift #selector target), without the compiler warning that
/// a literal Selector("...") would produce.
private func sel(_ name: String) -> Selector { Selector(name) }

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var logView: NSTextView!
    private var buildButton: NSButton!
    /// Secondary button that clears the download cache without building.
    private var cacheButton: NSButton!
    /// Spinner shown on the build button while the build runs.
    private var buildSpinner: NSProgressIndicator!

    // Build controls
    private var archPopup: NSPopUpButton!
    private var outField: NSTextField!
    private var enginePopup: NSPopUpButton!
    private var engineUrlField: NSTextField!
    private var engineDirField: NSTextField!
    private var runtimeUrlField: NSTextField!
    private var runtimeDirField: NSTextField!
    private var gameField: NSTextField!
    private var gameUrlField: NSTextField!
    private var chimeraCheck: NSButton!
    private var dsoalCheck: NSButton!
    private var dsoalField: NSTextField!
    private var dsoalHrtfCheck: NSButton!
    private var moltenvkField: NSTextField!
    /// Chosen -vidmode value: a preset name maps to its W,H,R, a custom
    /// selection holds the entered value, nil means "off" (no -vidmode).
    private var vidmodePopup: NSPopUpButton!
    private var vidmodeValue: String?
    /// Popup item showing a previously entered custom value, so it stays
    /// visible and marked as custom ("... (custom)").
    private var customVidmodeItem: NSMenuItem?
    private var cacheDirField: NSTextField!
    private var noCacheCheck: NSButton!

    /// The repo root. HaloXBuilder.app is produced in the repo root, so the
    /// parent of the bundle path is the root. This is how the builder finds
    /// scripts/build-local.sh and assets/shield.icns.
    private let repoRoot: URL = {
        URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
    }()

    private var buildTask: Process?
    /// Height of the output area, changed by the resize divider.
    private var logHeightConstraint: NSLayoutConstraint!

    // MARK: - Window setup

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        // The builder must run from the repo root, next to
        // the scripts/ folder, or it cannot find build-local.sh.
        let script = repoRoot.appendingPathComponent("scripts/build-local.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            showMissingScriptDialog()
        }
    }

    // MARK: - Menu bar (About, Edit, Window)

    /// Builds the main menu. Without an Edit menu the text fields
    /// would not respond to Cmd+C/V/X/A, so it must exist.
    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu with the About item.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "HaloX Builder")
        appMenuItem.submenu = appMenu
        let aboutItem = NSMenuItem(
            title: "About HaloX Builder",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit HaloX Builder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Edit menu: makes copy/paste/cut/select-all work in the fields.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: sel("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: sel("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - About dialog

    private var aboutWindow: NSWindow?

    @objc private func showAbout() {
        if aboutWindow == nil {
            aboutWindow = makeAboutWindow()
        }
        guard let window = aboutWindow else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/BUM-MasterMike") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Builds the About window: icon, name, version, build date,
    /// copyright and a clickable GitHub link.
    private func makeAboutWindow() -> NSWindow {
        let about = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        about.title = "About HaloX Builder"
        about.isReleasedWhenClosed = false
        about.isMovableByWindowBackground = true
        about.appearance = NSAppearance(named: .darkAqua)

        guard let content = about.contentView else { return about }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        // Icon.
        let icon = NSImageView()
        if let bundleIcon = NSImage(named: "AppIcon") {
            icon.image = bundleIcon
        } else if let repoIcon = NSImage(contentsOf: repoRoot.appendingPathComponent("assets/shield.icns")) {
            icon.image = repoIcon
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        stack.addArrangedSubview(icon)

        // Name.
        let name = NSTextField(labelWithString: "HaloX Builder")
        name.font = .boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(name)

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let buildDate = bundle.object(forInfoDictionaryKey: "BuildDate") as? String ?? ""
        let copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 BUM MasterMike.\nLicensed under the MIT License."

        // Version.
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(versionLabel)

        // Build date.
        let buildLabel = NSTextField(labelWithString: "Built on \(buildDate)")
        buildLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(buildLabel)

        // Small gap before the copyright.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(spacer)

        // Copyright.
        let copyrightLabel = NSTextField(labelWithString: copyright)
        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.maximumNumberOfLines = 0
        copyrightLabel.preferredMaxLayoutWidth = 290
        stack.addArrangedSubview(copyrightLabel)

        // Clickable GitHub link (plain link text, not a button).
        let link = LinkLabel(text: "github.com/BUM-MasterMike")
        link.onClick = { [weak self] in self?.openGitHub() }
        stack.setCustomSpacing(14, after: copyrightLabel)
        stack.addArrangedSubview(link)

        return about
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        window.title = appVersion.map { "HaloX Builder \($0)" } ?? "HaloX Builder"
        window.center()
        window.minSize = NSSize(width: 520, height: 620)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let content = window.contentView else { return }

        // Force dark mode, no matter what macOS is set to.
        window.appearance = NSAppearance(named: .darkAqua)

        // App icon (centered, top).
        let icon = NSImageView()
        icon.image = NSImage(contentsOf: repoRoot.appendingPathComponent("assets/shield.icns"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)

        // Title.
        let title = NSTextField(labelWithString: "HaloX Build Configuration")
        title.font = .boldSystemFont(ofSize: 16)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        // The form lives in a scroll view, wrapped in a
        // container that draws the subtle rounded frame.
        // The container (not the scroll view) owns the
        // border, so the clip view cannot cover it; the
        // scroll view is inset by the border width.
        let formContainer = NSView()
        formContainer.wantsLayer = true
        formContainer.layer?.borderWidth = 1
        formContainer.layer?.borderColor = frameBorderColor.cgColor
        formContainer.layer?.cornerRadius = 6
        formContainer.layer?.masksToBounds = true
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(formContainer)

        let formScroll = NSScrollView()
        formScroll.hasVerticalScroller = true
        formScroll.borderType = .noBorder
        formScroll.drawsBackground = false
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addSubview(formScroll)
        NSLayoutConstraint.activate([
            formScroll.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 1),
            formScroll.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 1),
            formScroll.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -1),
            formScroll.bottomAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: -1),
        ])

        // The document view is a plain flipped view pinned
        // to the clip view without constants, so the scroll
        // view's own frame management stays intact. The
        // form (the stack view) sits inside it with a
        // consistent margin on all sides, so the fields
        // never touch the frame.
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: formScroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
        ])

        let form = FlippedStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.distribution = .fill
        form.spacing = 6
        form.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            form.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            form.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            form.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
        ])

        buildForm(in: form)

        // Trailing spring: absorbs any surplus height in the form stack,
        // so surplus never stretches the last row (which would push the
        // "No cache" row away from its section when the window grows).
        let formSpring = NSView()
        formSpring.translatesAutoresizingMaskIntoConstraints = false
        formSpring.setContentHuggingPriority(.defaultLow, for: .vertical)
        form.addArrangedSubview(formSpring)

        // Build button (left-aligned, like the field labels above).
        buildButton = NSButton(title: "Build HaloX", target: self, action: #selector(buildTapped))
        // Blue background for a modern primary-button look.
        buildButton.isBordered = false
        buildButton.wantsLayer = true
        buildButton.layer?.backgroundColor = buttonColor.cgColor
        buildButton.layer?.cornerRadius = 6
        buildButton.attributedTitle = NSAttributedString(
            string: "Build HaloX",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
        buildButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buildButton)

        // Spinner on the build button while the build runs:
        // centered, hidden by default, only visible during the build.
        buildSpinner = NSProgressIndicator()
        buildSpinner.style = .spinning
        buildSpinner.controlSize = .small
        buildSpinner.isDisplayedWhenStopped = false
        buildSpinner.translatesAutoresizingMaskIntoConstraints = false
        buildSpinner.isHidden = true
        buildButton.addSubview(buildSpinner)
        NSLayoutConstraint.activate([
            buildSpinner.centerXAnchor.constraint(equalTo: buildButton.centerXAnchor),
            buildSpinner.centerYAnchor.constraint(equalTo: buildButton.centerYAnchor),
        ])

        // Secondary button next to Build: clears the download cache
        // only (build-local.sh --clear-cache, no build).
        cacheButton = NSButton(title: "Clear Cache", target: self, action: #selector(clearCacheTapped))
        cacheButton.toolTip = "Delete the cached engine/runtime downloads"
        // Same visual style as the build button (borderless, filled,
        // rounded), so both buttons have the same apparent height.
        cacheButton.isBordered = false
        cacheButton.wantsLayer = true
        cacheButton.layer?.backgroundColor = NSColor(white: 0.30, alpha: 1.0).cgColor
        cacheButton.layer?.cornerRadius = 6
        cacheButton.layer?.masksToBounds = true
        cacheButton.attributedTitle = NSAttributedString(
            string: "Clear Cache",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
        cacheButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cacheButton)

        // Log output, wrapped in a container that draws
        // the same rounded frame as the form above.
        let logContainer = NSView()
        logContainer.wantsLayer = true
        logContainer.layer?.borderWidth = 1
        logContainer.layer?.borderColor = frameBorderColor.cgColor
        logContainer.layer?.cornerRadius = 6
        logContainer.layer?.masksToBounds = true
        logContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(logContainer)

        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logContainer.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.topAnchor.constraint(equalTo: logContainer.topAnchor, constant: 1),
            logScroll.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor, constant: 1),
            logScroll.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor, constant: -1),
            logScroll.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor, constant: -1),
        ])

        logView = NSTextView()
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = logFont
        logView.textColor = NSColor.textColor
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.textContainer?.lineFragmentPadding = 0
        logView.autoresizingMask = [.width, .height]
        logScroll.documentView = logView

        // Flexible spacer: absorbs extra space at the bottom so
        // the elements above stay top-aligned when the window grows.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(spacer)

        // Divider between the output area and the spacer: drag it
        // to resize the output area (the window grows with it).
        let resizeDivider = ResizeDividerView()
        resizeDivider.translatesAutoresizingMaskIntoConstraints = false
        resizeDivider.wantsLayer = true
        resizeDivider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        content.addSubview(resizeDivider)

        // The form may shrink below its preferred height when the
        // window is small (soft minimum) and grows at most to its
        // natural height, so all fields become visible without the
        // layout being pushed to the bottom.
        let formMinHeight = formScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        formMinHeight.priority = .defaultHigh
        let formMaxHeight = formScroll.heightAnchor.constraint(lessThanOrEqualTo: documentView.heightAnchor)
        formMaxHeight.priority = .defaultHigh
        let spacerZero = spacer.heightAnchor.constraint(equalToConstant: 0)
        spacerZero.priority = .defaultLow
        logHeightConstraint = logContainer.heightAnchor.constraint(equalToConstant: 150)

        NSLayoutConstraint.activate([
            // Icon
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),

            // Title (more space below it)
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            // Form (flexible height, up to its natural height)
            formContainer.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            formContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            formContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            formMinHeight,
            formMaxHeight,

            // Build button (left-aligned, extra space above, larger)
            buildButton.topAnchor.constraint(equalTo: formContainer.bottomAnchor, constant: 20),
            buildButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buildButton.heightAnchor.constraint(equalToConstant: 44),
            buildButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Cache button (same size as the build button, right next to it)
            cacheButton.leadingAnchor.constraint(equalTo: buildButton.trailingAnchor, constant: 12),
            cacheButton.centerYAnchor.constraint(equalTo: buildButton.centerYAnchor),
            cacheButton.widthAnchor.constraint(equalTo: buildButton.widthAnchor),
            cacheButton.heightAnchor.constraint(equalTo: buildButton.heightAnchor),

            // Log (resizable height, directly below the button)
            logContainer.topAnchor.constraint(equalTo: buildButton.bottomAnchor, constant: 20),
            logContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            logContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            logHeightConstraint,

            // Resize divider (draggable handle below the log)
            resizeDivider.topAnchor.constraint(equalTo: logContainer.bottomAnchor),
            resizeDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            resizeDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            resizeDivider.heightAnchor.constraint(equalToConstant: 6),

            // Spacer (extra space at the bottom)
            spacer.topAnchor.constraint(equalTo: resizeDivider.bottomAnchor, constant: 10),
            spacer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            spacer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            spacer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            spacerZero,
        ])

        // Dragging the divider resizes the output area and the
        // window together, so the form area keeps its size and the
        // flexible spacer does not absorb the change.
        resizeDivider.onResize = { [weak self] delta in
            guard let self = self else { return }
            let current = self.logHeightConstraint.constant
            let next = min(max(current + delta, 80), 600)
            let applied = next - current
            self.logHeightConstraint.constant = next
            var frame = self.window.frame
            frame.size.height += applied
            frame.origin.y -= applied
            self.window.setFrame(frame, display: true, animate: false)
        }

        appendLog("HaloX Builder ready. Defaults are prefilled; adjust and press \"Build HaloX\".\n")

        // Start with the form scrolled to the top so the first
        // field is visible.
        DispatchQueue.main.async {
            formScroll.layoutSubtreeIfNeeded()
            guard let document = formScroll.documentView else { return }
            let clip = formScroll.contentView
            let topY = document.isFlipped ? 0 : max(0, document.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: topY))
            formScroll.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Form

    private func buildForm(in form: NSStackView) {
        section("Build", in: form)

        archPopup = NSPopUpButton()
        archPopup.addItems(withTitles: ["Apple Silicon (arm64)", "Intel (x86_64)"])
        archPopup.selectItem(at: defaultArch == "arm64" ? 0 : 1)
        addRow("Architecture", archPopup, to: form)

        outField = NSTextField()
        outField.stringValue = "/Applications/HaloX.app"
        outField.placeholderString = "/Applications/HaloX.app"
        addRow("Output (.app)", outField, to: form)

        section("Engine & Runtime", in: form)

        enginePopup = NSPopUpButton()
        enginePopup.addItems(withTitles: [
            "wineskincx-23.7.1",
            "wineskincx-23.6.0",
            "wineskincx-23.5.0",
            "wineskincx-22.1.1",
            "wineskincx-21.2.0",
        ])
        addRow("Engine", enginePopup, to: form)

        engineUrlField = NSTextField()
        engineUrlField.placeholderString = "direct archive URL (overrides the engine choice)"
        addRow("Engine URL", engineUrlField, to: form)

        engineDirField = NSTextField()
        engineDirField.placeholderString = "local wswine.bundle dir (overrides both)"
        addRow("Engine dir", engineDirField, to: form)

        runtimeUrlField = NSTextField()
        runtimeUrlField.stringValue = "https://github.com/The-Wineskin-Project/Wrapper/releases/download/v1.0/Wineskin-3.0.6_1.tar.7z"
        addRow("Runtime URL", runtimeUrlField, to: form)

        runtimeDirField = NSTextField()
        runtimeDirField.placeholderString = "local wrapper Contents dir (overrides the URL)"
        addRow("Runtime dir", runtimeDirField, to: form)

        section("Game", in: form)

        gameField = NSTextField()
        gameField.stringValue = repoRoot.appendingPathComponent("game").path
        addRow("Game source", gameField, to: form)

        // Button below the game source field: open a panel
        // to pick a folder or a .zip file.
        let gameChooseButton = NSButton(
            title: "Choose folder or ZIP…",
            target: self,
            action: #selector(chooseGame)
        )
        gameChooseButton.toolTip = "Select a game folder or a .zip file"
        addRow("", gameChooseButton, to: form)

        gameUrlField = NSTextField()
        gameUrlField.placeholderString = "download a Halo zip first (overrides the game source)"
        addRow("Game URL", gameUrlField, to: form)

        section("Components", in: form)

        chimeraCheck = addCheckbox("Chimera", tooltip: "Include the latest Chimera release", to: form)
        chimeraCheck.state = .on

        dsoalCheck = addCheckbox("DSOAL", tooltip: "DSOAL positional audio", to: form)
        dsoalCheck.state = .on

        dsoalField = NSTextField()
        dsoalField.stringValue = "bundle"
        dsoalField.placeholderString = "bundle / github / zip / dir"
        addRow("DSOAL source", dsoalField, to: form)

        dsoalHrtfCheck = addCheckbox("DSOAL HRTF", tooltip: "DSOAL binaural HRTF (headphones)", to: form)

        moltenvkField = NSTextField()
        moltenvkField.stringValue = "1.2.5"
        moltenvkField.placeholderString = "version, path or 'none'"
        addRow("MoltenVK", moltenvkField, to: form)

        // Fixed presets from scripts/vidmode-presets.sh, plus a custom
        // option, mirroring the script's interactive picker. Items
        // carry a tag (0 = off, 1 = preset, 2 = custom value,
        // 3 = custom prompt) and the value in representedObject.
        vidmodePopup = NSPopUpButton()
        vidmodePopup.addItem(withTitle: "Off (no -vidmode)")
        vidmodePopup.lastItem?.tag = 0
        for preset in vidmodePresets {
            vidmodePopup.addItem(withTitle: preset.name)
            vidmodePopup.lastItem?.tag = 1
            vidmodePopup.lastItem?.representedObject = preset.value
            vidmodePopup.lastItem?.toolTip = preset.value
        }
        vidmodePopup.addItem(withTitle: "Custom W,H,R…")
        vidmodePopup.lastItem?.tag = 3
        vidmodePopup.toolTip = "Pick a display preset, or define your own W,H,R (e.g. 1280,800,60)"
        vidmodePopup.target = self
        vidmodePopup.action = #selector(vidmodeSelectionChanged)
        addRow("Vidmode", vidmodePopup, to: form)

        section("Cache", in: form)

        cacheDirField = NSTextField()
        cacheDirField.stringValue = NSString(string: "~/Library/Caches/HaloX").expandingTildeInPath
        addRow("Cache dir", cacheDirField, to: form)

        noCacheCheck = addCheckbox("No cache", tooltip: "No persistent cache (temp only)", to: form)
    }

    private func section(_ title: String, in form: NSStackView) {
        // Extra vertical space before a section header (but not
        // before the very first one) so the parameter groups are
        // easier to tell apart.
        if let previous = form.arrangedSubviews.last {
            form.setCustomSpacing(18, after: previous)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .vertical)
        form.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
    }

    private func addRow(_ label: String, _ control: NSControl, to form: NSStackView) {
        let labelField = NSTextField(labelWithString: label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.textColor = fieldLabelColor

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.heightAnchor.constraint(equalToConstant: 26).isActive = true
        // Rounded corners for a modern look (the default
        // text field bezel is square).
        if let textField = control as? NSTextField {
            textField.isBezeled = true
            textField.bezelStyle = .roundedBezel
        } else if let button = control as? NSButton {
            button.bezelStyle = .rounded
        }

        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Rows must never stretch vertically: surplus height in the form
        // stack goes to the trailing spring, not into the last row.
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)
        form.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        labelField.widthAnchor.constraint(equalToConstant: 128).isActive = true
    }

    private func addCheckbox(_ label: String, tooltip: String? = nil, to form: NSStackView) -> NSButton {
        // No title on the checkbox itself: the independent label on the
        // left carries the name, and the checkbox sits in the control
        // column, aligned with the text fields.
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        check.translatesAutoresizingMaskIntoConstraints = false
        if let tooltip = tooltip {
            check.toolTip = tooltip
        }
        addRow(label, check, to: form)
        return check
    }

    /// Open a panel to pick a game folder or a .zip file
    /// and put the chosen path into the game source field.
    @objc private func chooseGame() {
        let panel = NSOpenPanel()
        panel.title = "Select game source"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            var isDir: ObjCBool = false
            let isDirectory = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDir
            ) && isDir.boolValue
            let isZip = url.pathExtension.lowercased() == "zip"
            if isDirectory || isZip {
                self.gameField.stringValue = url.path
            } else {
                let alert = NSAlert()
                alert.messageText = "Invalid selection"
                alert.informativeText = "Please choose a game folder or a .zip file."
                alert.alertStyle = .critical
                alert.beginSheetModal(for: self.window) { _ in }
            }
        }
    }

    // MARK: - Build

    @objc private func buildTapped() {
        let outPath = expand(outField.stringValue)
        // Ask before replacing an output bundle that already exists.
        if FileManager.default.fileExists(atPath: outPath) {
            let alert = NSAlert()
            alert.messageText = "Overwrite existing output?"
            alert.informativeText = "\(outPath) already exists. Do you want to replace it?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self = self, response == .alertFirstButtonReturn else { return }
                self.runBuild()
            }
        } else {
            runBuild()
        }
    }

    /// Toggle the controls between their normal state and the "busy"
    /// state while a build or a cache clear runs: both buttons are
    /// disabled and a spinner is shown on the build button; afterwards
    /// the build button title is restored.
    private func setRunInProgress(_ running: Bool) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ]
        if running {
            buildButton.attributedTitle = NSAttributedString(string: "", attributes: titleAttrs)
            buildButton.isEnabled = false
            cacheButton.isEnabled = false
            buildSpinner.isHidden = false
            buildSpinner.startAnimation(nil)
        } else {
            buildSpinner.stopAnimation(nil)
            buildSpinner.isHidden = true
            buildButton.attributedTitle = NSAttributedString(string: "Build HaloX", attributes: titleAttrs)
            buildButton.isEnabled = true
            cacheButton.isEnabled = true
        }
    }

    /// Run scripts/build-local.sh with the given arguments, stream its
    /// output into the log, and call completion(status) on the main
    /// thread. The log is cleared first so a stale "FAIL:" from an
    /// earlier run can never be shown again. HALOX_CACHE_DIR mirrors
    /// the configured cache dir, the same variable the script honours.
    private func runScript(_ args: [String], completion: @escaping (Int32) -> Void) {
        logView.string = ""
        appendLog("$ scripts/build-local.sh \(args.joined(separator: " "))\n\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/build-local.sh"] + args
        process.currentDirectoryURL = repoRoot

        var env = ProcessInfo.processInfo.environment
        env["HALOX_CACHE_DIR"] = expand(cacheDirField.stringValue)
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self?.appendLog(text) }
            }
        }

        setRunInProgress(true)
        buildTask = process

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try process.run()
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    self.appendLog("\n[exit status \(status)]\n")
                    self.setRunInProgress(false)
                    self.buildTask = nil
                    completion(status)
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLog("Failed to start build-local.sh: \(error)\n")
                    self.setRunInProgress(false)
                    self.buildTask = nil
                    completion(1)
                }
            }
        }
    }

    /// Run the build script with the current field values.
    private func runBuild() {
        runScript(buildArguments()) { [weak self] status in
            self?.showResultDialog(status: status)
        }
    }

    /// Clear the download cache only: run build-local.sh with just
    /// --clear-cache (and the configured cache dir), then report the
    /// outcome in an info dialog.
    @objc private func clearCacheTapped() {
        var args = ["--clear-cache"]
        if let cacheDir = trimmed(cacheDirField.stringValue) {
            args += ["--cache-dir", expand(cacheDir)]
        }
        runScript(args) { [weak self] status in
            self?.showCacheResultDialog(status: status)
        }
    }

    private func showCacheResultDialog(status: Int32) {
        let alert = NSAlert()
        if status == 0 {
            let plain = logView.string.stripANSI
            alert.messageText = "Cache cleared"
            if plain.contains("Cache already empty") {
                alert.informativeText = "The download cache was already empty."
            } else {
                alert.informativeText = "Removed the cached downloads from \(expand(cacheDirField.stringValue))."
            }
            alert.alertStyle = .informational
        } else if let failure = extractFailMessage(from: logView.string) {
            alert.messageText = "Cache clear failed"
            alert.informativeText = failure
            alert.alertStyle = .critical
        } else {
            alert.messageText = "Cache clear failed"
            alert.informativeText = "build-local.sh exited with status \(status)."
            alert.alertStyle = .critical
        }
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Handle the Vidmode popup selection: item tag 0 = off, 1 = preset,
    /// 2 = a previously entered custom value, 3 = open the custom prompt.
    @objc private func vidmodeSelectionChanged() {
        guard let item = vidmodePopup.selectedItem else { return }
        switch item.tag {
        case 3:
            promptForCustomVidmode()
        case 0:
            vidmodeValue = nil
        default:
            vidmodeValue = item.representedObject as? String
        }
    }

    /// Ask for a custom W,H,R value. The value is validated (three
    /// positive integers) before it is accepted.
    private func promptForCustomVidmode() {
        let alert = NSAlert()
        alert.messageText = "Custom -vidmode"
        alert.informativeText = "Enter a W,H,R value that matches the current 'Looks like' resolution (e.g. 1280,800,60):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = vidmodeValue ?? ""
        alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .alertFirstButtonReturn else {
                self.resetVidmodeToOff()
                return
            }
            guard let value = self.normalizedVidmode(input.stringValue) else {
                self.warnInvalidVidmode(input.stringValue)
                return
            }
            self.applyCustomVidmode(value)
        }
    }

    /// Accept exactly three positive integers (W,H,R) – the format the
    /// scripts expect – and return it normalized, or nil when invalid.
    private func normalizedVidmode(_ raw: String) -> String? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard let number = Int(text), number > 0 else { return nil }
            numbers.append(number)
        }
        return numbers.map(String.init).joined(separator: ",")
    }

    /// Store a valid custom value and show it in the popup, marked as
    /// custom, so it stays visible and selectable.
    private func applyCustomVidmode(_ value: String) {
        if let existing = customVidmodeItem {
            vidmodePopup.menu?.removeItem(existing)
        }
        let item = NSMenuItem(title: "\(value)  (custom)", action: nil, keyEquivalent: "")
        item.tag = 2
        item.representedObject = value
        item.toolTip = "Custom W,H,R"
        // Insert directly before the "Custom W,H,R…" prompt item.
        let insertIndex = max(0, vidmodePopup.numberOfItems - 1)
        vidmodePopup.menu?.insertItem(item, at: insertIndex)
        customVidmodeItem = item
        vidmodeValue = value
        vidmodePopup.select(item)
    }

    private func resetVidmodeToOff() {
        vidmodePopup.selectItem(at: 0)
        vidmodeValue = nil
    }

    private func warnInvalidVidmode(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "Invalid -vidmode"
        alert.informativeText = value.isEmpty
            ? "No value entered. Use three positive integers, e.g. 1280,800,60."
            : "'\(value)' is not a valid W,H,R value. Use three positive integers, e.g. 1280,800,60."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if response == .alertFirstButtonReturn {
                self.promptForCustomVidmode()
            } else {
                self.resetVidmodeToOff()
            }
        }
    }

    private func buildArguments() -> [String] {
        var args: [String] = []

        let arch = archPopup.indexOfSelectedItem == 0 ? "arm64" : "x86_64"
        args += ["--arch", arch]

        let out = trimmed(outField.stringValue) ?? "/Applications/HaloX.app"
        args += ["--out", expand(out)]

        args += ["--engine", enginePopup.titleOfSelectedItem ?? "wineskincx-23.7.1"]
        if let value = trimmed(engineUrlField.stringValue) {
            args += ["--engine-url", value]
        }
        if let value = trimmed(engineDirField.stringValue) {
            args += ["--engine-dir", expand(value)]
        }
        // Runtime URL only when actually set: the field is prefilled
        // with the script default, so the behaviour stays identical.
        if let value = trimmed(runtimeUrlField.stringValue) {
            args += ["--runtime-url", value]
        }
        if let value = trimmed(runtimeDirField.stringValue) {
            args += ["--runtime-dir", expand(value)]
        }
        let game = trimmed(gameField.stringValue) ?? repoRoot.appendingPathComponent("game").path
        args += ["--game", expand(game)]
        if let value = trimmed(gameUrlField.stringValue) {
            args += ["--game-url", value]
        }
        args += chimeraCheck.state == .on ? ["--chimera"] : ["--no-chimera"]
        if dsoalCheck.state == .on {
            args += ["--dsoal", trimmed(dsoalField.stringValue) ?? "bundle"]
            if dsoalHrtfCheck.state == .on {
                args += ["--dsoal-hrtf"]
            }
        } else {
            args += ["--no-dsoal"]
        }
        args += ["--moltenvk", trimmed(moltenvkField.stringValue) ?? "1.2.5"]
        if let value = vidmodeValue {
            args += ["--vidmode", value]
        }
        let cacheDir = trimmed(cacheDirField.stringValue)
            ?? NSString(string: "~/Library/Caches/HaloX").expandingTildeInPath
        args += ["--cache-dir", expand(cacheDir)]
        if noCacheCheck.state == .on {
            args += ["--no-cache"]
        }
        return args
    }

    private func trimmed(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Expand a leading `~` so the shell script never receives a literal one.
    private func expand(_ value: String) -> String {
        return NSString(string: value).expandingTildeInPath
    }

    private func appendLog(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.textColor,
            .font: logFont
        ]
        logView.textStorage?.append(NSAttributedString(string: text, attributes: attrs))
        logView.scrollRangeToVisible(NSRange(location: logView.string.utf16.count, length: 0))
    }

    /// Show a sheet summarizing the build result: the FAIL:
    /// message on failure, a success notice on exit status 0.
    private func showResultDialog(status: Int32) {
        let alert = NSAlert()
        if let failure = extractFailMessage(from: logView.string) {
            alert.messageText = "Build failed"
            alert.informativeText = failure
            alert.alertStyle = .critical
        } else if status == 0 {
            alert.messageText = "Build succeeded"
            alert.informativeText = "Created \(expand(outField.stringValue))."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Build failed"
            alert.informativeText = "The build exited with status \(status)."
            alert.alertStyle = .critical
        }
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Return the message of the first "FAIL:" line in the log,
    /// with terminal color codes stripped.
    private func extractFailMessage(from log: String) -> String? {
        let plain = log.stripANSI
        guard let range = plain.range(of: "FAIL:") else { return nil }
        let after = plain[range.upperBound...]
        let end = after.firstIndex(of: "\n") ?? after.endIndex
        let message = String(after[..<end]).trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : message
    }

    /// Alert shown at launch when the app cannot find
    /// scripts/build-local.sh because it was moved out of
    /// the repository root.
    private func showMissingScriptDialog() {
        let alert = NSAlert()
        alert.messageText = "Wrong location"
        alert.informativeText = "HaloXBuilder.app must stay in the repository root, next to the scripts/ and assets/ folders, so it can find scripts/build-local.sh. Move it back there and run it from the repo root."
        alert.alertStyle = .critical
        alert.beginSheetModal(for: window) { _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.appearance = NSAppearance(named: .darkAqua)
app.setActivationPolicy(.regular)
app.run()
