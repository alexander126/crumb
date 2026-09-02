import CrumbCore
#if canImport(UIKit)
import UIKit

private extension CrumbTheme {
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

public extension Crumb {
    @MainActor
    @discardableResult
    static func show(trigger: CrumbInvocation = .programmatic) -> Bool {
        CrumbWorkspacePolicyCoordinator.shared.install()
        return CrumbReporterPresenter.shared.show(trigger: trigger)
    }
}

@MainActor
private final class CrumbReporterPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = CrumbReporterPresenter()

    private weak var presentedController: UIViewController?
    private var accessibilityHiddenHostViews: [(view: UIView, wasHidden: Bool)] = []
    private var activeSessionID: UUID?
    private var isTransitioningFromShakePrompt = false

    private struct PresentationContext {
        let screenshotArtifact: CrumbScreenshotArtifact?
        let screenshotCapture: CrumbScreenshotCaptureState
        let screenshotMasking: CrumbScreenshotMaskingState
        let settings: CrumbReportSettings
        let location: String
        let trigger: CrumbInvocation
        let triggeredAt: Date
        let invocationStartedAtNanoseconds: UInt64
    }

    func show(trigger: CrumbInvocation) -> Bool {
        let invocationStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        reconcilePresentationState()
        guard activeSessionID == nil else { return false }
        guard let presenter = Self.topViewController() else { return false }
        guard let settings = try? Crumb.reportSettings() else { return false }
        guard settings.invocation.contains(trigger) else { return false }
        let triggeredAt = Date()
        let sessionID = UUID()

        let screenshotArtifact: CrumbScreenshotArtifact?
        if settings.evidence.contains(.screenshot),
           settings.capture.screenshot,
           let window = presenter.view.window {
            screenshotArtifact = CrumbScreenshotArtifactPipeline.capture(
                window: window,
                capture: settings.capture,
                privacy: settings.privacy
            )
        } else {
            screenshotArtifact = nil
        }
        CrumbQualityInstrumentation.record(
            kind: .screenshotReady,
            startedAtNanoseconds: invocationStartedAtNanoseconds
        )
        let screenshotCapture: CrumbScreenshotCaptureState = if !settings.capture.screenshot {
            .disabledByConfiguration
        } else if !settings.evidence.contains(.screenshot) {
            .disabledByPolicy
        } else if screenshotArtifact != nil {
            .enabled
        } else {
            .unavailable
        }
        let screenshotMasking: CrumbScreenshotMaskingState = if let screenshotArtifact {
            screenshotArtifact.maskingState
        } else if settings.evidence.contains(.screenshot)
                    && settings.capture.screenshot
                    && (settings.privacy.maskAllTextInputs
                        || settings.privacy.maskScreenshotsBeforeUpload) {
            .failed
        } else {
            .notApplicable
        }

        let context = PresentationContext(
            screenshotArtifact: screenshotArtifact,
            screenshotCapture: screenshotCapture,
            screenshotMasking: screenshotMasking,
            settings: settings,
            location: String(reflecting: type(of: presenter)),
            trigger: trigger,
            triggeredAt: triggeredAt,
            invocationStartedAtNanoseconds: invocationStartedAtNanoseconds
        )

        activeSessionID = sessionID
        accessibilityHiddenHostViews = [
            presenter.view,
            presenter.navigationController?.navigationBar,
            presenter.tabBarController?.tabBar
        ].compactMap { $0 }.map { ($0, $0.accessibilityElementsHidden) }
        accessibilityHiddenHostViews.forEach { $0.view.accessibilityElementsHidden = true }
        CrumbReporterLifecycle.shared.reporterPresentationDidBegin()

        if trigger == .shake {
            presentShakePrompt(context: context, from: presenter, sessionID: sessionID)
        } else {
            presentReporter(context: context, from: presenter, sessionID: sessionID)
        }
        return true
    }

    private func presentReporter(
        context: PresentationContext,
        from presenter: UIViewController,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else { return }
        let reporter = ReporterViewController(
            screenshotArtifact: context.screenshotArtifact,
            screenshotCapture: context.screenshotCapture,
            screenshotMasking: context.screenshotMasking,
            settings: context.settings,
            location: context.location,
            trigger: context.trigger,
            triggeredAt: context.triggeredAt,
            invocationStartedAtNanoseconds: context.invocationStartedAtNanoseconds,
            onFinish: { [weak self] in self?.finish(sessionID: sessionID) }
        )
        let navigationController = UINavigationController(rootViewController: reporter)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.overrideUserInterfaceStyle = context.settings.reporter.theme.uiStyle
        navigationController.setNavigationBarHidden(true, animated: false)
        let appearance = CrumbDesign.navigationAppearance()
        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.compactAppearance = appearance
        navigationController.navigationBar.tintColor = CrumbDesign.Color.accentDark
        navigationController.view.accessibilityViewIsModal = true
        if let sheet = navigationController.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let formDetent = UISheetPresentationController.Detent.Identifier("crumb.form")
                sheet.detents = [
                    .custom(identifier: formDetent) { context in
                        min(628, context.maximumDetentValue)
                    }
                ]
                sheet.selectedDetentIdentifier = formDetent
            } else {
                sheet.detents = [.large()]
            }
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.preferredCornerRadius = 26
        }
        presentedController = navigationController
        navigationController.presentationController?.delegate = self
        presenter.present(navigationController, animated: true)
        CrumbQualityInstrumentation.record(
            kind: .formReady,
            startedAtNanoseconds: context.invocationStartedAtNanoseconds
        )
        navigationController.presentationController?.delegate = self
        isTransitioningFromShakePrompt = false
    }

    private func presentShakePrompt(
        context: PresentationContext,
        from presenter: UIViewController,
        sessionID: UUID
    ) {
        let prompt = ShakePromptViewController()
        prompt.overrideUserInterfaceStyle = context.settings.reporter.theme.uiStyle
        prompt.modalPresentationStyle = .overFullScreen
        prompt.modalTransitionStyle = .crossDissolve
        prompt.onReport = { [weak self, weak prompt, weak presenter] in
            guard let self, let prompt, let presenter,
                  self.activeSessionID == sessionID else { return }
            self.isTransitioningFromShakePrompt = true
            self.presentedController = nil
            prompt.dismiss(animated: true) { [weak self, weak presenter] in
                guard let self, let presenter,
                      self.activeSessionID == sessionID else { return }
                self.presentReporter(context: context, from: presenter, sessionID: sessionID)
            }
        }
        prompt.onDismiss = { [weak self, weak prompt] in
            guard let self, let prompt,
                  self.activeSessionID == sessionID else { return }
            self.presentedController = nil
            prompt.dismiss(animated: true) { [weak self] in
                self?.finish(sessionID: sessionID)
            }
        }
        presentedController = prompt
        presenter.present(prompt, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === presentedController else { return }
        if let activeSessionID {
            finish(sessionID: activeSessionID)
        }
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard let navigation = presentationController.presentedViewController as? UINavigationController,
              let reporter = navigation.viewControllers.first as? ReporterViewController else {
            return true
        }
        return !reporter.hasMeaningfulInput
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let navigation = presentationController.presentedViewController as? UINavigationController,
              let reporter = navigation.viewControllers.first as? ReporterViewController else {
            return
        }
        reporter.requestCancel()
    }

    private func finish(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        presentedController = nil
        isTransitioningFromShakePrompt = false
        accessibilityHiddenHostViews.forEach {
            $0.view.accessibilityElementsHidden = $0.wasHidden
        }
        accessibilityHiddenHostViews = []
        CrumbReporterLifecycle.shared.reporterPresentationDidEnd()
        CrumbQualityInstrumentation.record(
            kind: .reporterClosed,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func reconcilePresentationState() {
        guard activeSessionID != nil,
              presentedController == nil,
              !isTransitioningFromShakePrompt else { return }
        activeSessionID = nil
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        var current = window?.rootViewController
        while true {
            if let presented = current?.presentedViewController {
                current = presented
            } else if let navigation = current as? UINavigationController {
                current = navigation.visibleViewController
            } else if let tabs = current as? UITabBarController {
                current = tabs.selectedViewController
            } else {
                return current
            }
        }
    }
}

@MainActor
private final class ShakePromptViewController: UIViewController {
    var onReport: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = UILabel()
    private var didMoveInitialAccessibilityFocus = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        let dismissSurface = UIButton(type: .custom)
        dismissSurface.backgroundColor = .clear
        dismissSurface.accessibilityLabel = crumbLocalized("Cancel")
        dismissSurface.accessibilityIdentifier = "crumb.shake-dismiss"
        dismissSurface.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        dismissSurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissSurface)

        let card = UIStackView()
        card.axis = .horizontal
        card.alignment = .center
        card.spacing = 13
        card.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.isLayoutMarginsRelativeArrangement = true
        card.backgroundColor = CrumbDesign.Color.canvas.withAlphaComponent(0.94)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = CrumbDesign.Color.ink.cgColor
        card.layer.shadowOpacity = 0.16
        card.layer.shadowRadius = 17
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let mark = CrumbMarkView(showsTile: true)
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 42),
            mark.heightAnchor.constraint(equalToConstant: 42)
        ])
        card.addArrangedSubview(mark)

        let copy = UIStackView()
        copy.axis = .vertical
        copy.spacing = 2
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.text = crumbLocalized("Report a problem?")
        titleLabel.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = CrumbDesign.Color.ink
        titleLabel.accessibilityIdentifier = "crumb.shake-prompt-title"
        copy.addArrangedSubview(titleLabel)

        let message = UILabel()
        message.text = crumbLocalized("We noticed a shake on this screen.")
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = CrumbDesign.Color.secondaryText
        message.numberOfLines = 0
        copy.addArrangedSubview(message)
        card.addArrangedSubview(copy)

        let report = UIButton(type: .system)
        var reportConfiguration = UIButton.Configuration.plain()
        reportConfiguration.title = crumbLocalized("Report")
        reportConfiguration.baseForegroundColor = CrumbDesign.Color.accentDark
        reportConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 10,
            leading: 12,
            bottom: 10,
            trailing: 12
        )
        reportConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            attributes in
            var updated = attributes
            updated.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
            return updated
        }
        report.configuration = reportConfiguration
        report.accessibilityIdentifier = "crumb.shake-report"
        report.setContentHuggingPriority(.required, for: .horizontal)
        report.setContentCompressionResistancePriority(.required, for: .horizontal)
        report.addAction(UIAction { [weak self] _ in self?.onReport?() }, for: .touchUpInside)
        card.addArrangedSubview(report)

        NSLayoutConstraint.activate([
            dismissSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dismissSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dismissSurface.topAnchor.constraint(equalTo: view.topAnchor),
            dismissSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 74)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didMoveInitialAccessibilityFocus else { return }
        didMoveInitialAccessibilityFocus = true
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }
}

private final class CrumbMarkView: UIView {
    private let showsTile: Bool

    init(showsTile: Bool = false) {
        self.showsTile = showsTile
        super.init(frame: .zero)
        backgroundColor = showsTile ? CrumbDesign.Color.markTile : .clear
        if showsTile {
            layer.cornerRadius = 11
            layer.cornerCurve = .continuous
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let glyphSize = min(24, min(bounds.width, bounds.height))
        let scale = glyphSize / 64
        let offset = CGPoint(
            x: (bounds.width - glyphSize) / 2,
            y: (bounds.height - glyphSize) / 2
        )
        let dotColor = showsTile ? UIColor.white : CrumbDesign.Color.ink
        context.setFillColor(dotColor.cgColor)
        let points: [CGPoint] = [
            CGPoint(x: 12, y: 12), CGPoint(x: 32, y: 12), CGPoint(x: 52, y: 12),
            CGPoint(x: 12, y: 32), CGPoint(x: 52, y: 32),
            CGPoint(x: 12, y: 52), CGPoint(x: 32, y: 52), CGPoint(x: 52, y: 52)
        ]
        for point in points {
            let center = CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
            let radius = 5.5 * scale
            context.fillEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        context.setStrokeColor(CrumbDesign.Color.accent.cgColor)
        context.setLineWidth(6 * scale)
        let center = CGPoint(x: offset.x + 32 * scale, y: offset.y + 32 * scale)
        let radius = 8.5 * scale
        context.strokeEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}

private final class CrumbCategoryControl: UIControl {
    private let buttons: [UIButton]
    private(set) var selectedSegmentIndex = 0

    init(items: [String]) {
        buttons = items.enumerated().map { index, title in
            let button = UIButton(type: .custom)
            button.tag = index
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 15)
            button.setTitleColor(CrumbDesign.Color.secondaryText, for: .normal)
            button.accessibilityLabel = title
            return button
        }
        super.init(frame: .zero)

        backgroundColor = CrumbDesign.Color.mutedSurface
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "crumb.category"

        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: 42)
        ])
        buttons.forEach { button in
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.setSelectedSegmentIndex(button.tag, sendsEvent: true)
            }, for: .touchUpInside)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelectedSegmentIndex(_ index: Int, sendsEvent: Bool = false) {
        guard buttons.indices.contains(index) else { return }
        selectedSegmentIndex = index
        updateAppearance()
        if sendsEvent { sendActions(for: .valueChanged) }
    }

    private func updateAppearance() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedSegmentIndex
            button.backgroundColor = selected ? CrumbDesign.Color.elevatedSurface : .clear
            button.layer.cornerRadius = selected ? 9 : 0
            button.layer.cornerCurve = .continuous
            button.layer.shadowColor = selected ? CrumbDesign.Color.ink.cgColor : nil
            button.layer.shadowOpacity = selected ? 0.10 : 0
            button.layer.shadowRadius = selected ? 3 : 0
            button.layer.shadowOffset = selected ? CGSize(width: 0, height: 1) : .zero
            button.titleLabel?.font = UIFont.systemFont(
                ofSize: 15,
                weight: selected ? .semibold : .regular
            )
            button.setTitleColor(
                selected ? CrumbDesign.Color.ink : CrumbDesign.Color.secondaryText,
                for: .normal
            )
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }
}

@MainActor
private final class ReporterViewController: UIViewController, UITextViewDelegate {
    private var screenshotArtifact: CrumbScreenshotArtifact?
    private let screenshotCapture: CrumbScreenshotCaptureState
    private let screenshotMasking: CrumbScreenshotMaskingState
    private let settings: CrumbReportSettings
    private let location: String
    private let trigger: CrumbInvocation
    private let triggeredAt: Date
    private let invocationStartedAtNanoseconds: UInt64
    private let onFinish: () -> Void

    private var diagnostics: CrumbDiagnosticsSnapshot?
    private let categoryControl = CrumbCategoryControl(
        items: ["Bug", "Feedback", "Other"].map(crumbLocalized)
    )
    private let descriptionView = UITextView()
    private let descriptionPlaceholder = UILabel()
    private let descriptionHelperLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let diagnosticsDetailLabel = UILabel()
    private let diagnosticsStatusDot = UILabel()
    private let submitButton = UIButton(type: .system)
    private let actionHelperLabel = UILabel()
    private let reviewHeaderButton = UIButton(type: .system)
    private let keyboardStatusRow = UIStackView()
    private let formSurfaceView = UIView()
    private let typingGrabber = UIView()
    private var descriptionHeightConstraint: NSLayoutConstraint?
    private var formSurfaceTopConstraint: NSLayoutConstraint?
    private var scrollTopConstraint: NSLayoutConstraint?
    private weak var contentStack: UIStackView?
    private weak var descriptionCard: UIView?
    private weak var diagnosticsCard: UIView?
    private weak var screenshotCard: UIView?
    private var isKeyboardVisible = false
    private var keyboardHeight: CGFloat = 0
    private var diagnosticsTask: Task<Void, Never>?
    private var didNotifyFinish = false
    private var didMoveInitialAccessibilityFocus = false

    var hasMeaningfulInput: Bool {
        (settings.reporter.visibleFields.contains(.category) && categoryControl.selectedSegmentIndex != 0)
            || !descriptionView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        screenshotArtifact: CrumbScreenshotArtifact?,
        screenshotCapture: CrumbScreenshotCaptureState,
        screenshotMasking: CrumbScreenshotMaskingState,
        settings: CrumbReportSettings,
        location: String,
        trigger: CrumbInvocation,
        triggeredAt: Date,
        invocationStartedAtNanoseconds: UInt64,
        onFinish: @escaping () -> Void
    ) {
        self.screenshotArtifact = screenshotArtifact
        self.screenshotCapture = screenshotCapture
        self.screenshotMasking = screenshotMasking
        self.settings = settings
        self.location = location
        self.trigger = trigger
        self.triggeredAt = triggeredAt
        self.invocationStartedAtNanoseconds = invocationStartedAtNanoseconds
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        diagnosticsTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = crumbLocalized("Report a problem")
        view.backgroundColor = .clear

        formSurfaceView.backgroundColor = CrumbDesign.Color.canvas
        formSurfaceView.layer.cornerRadius = 26
        formSurfaceView.layer.cornerCurve = .continuous
        formSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(formSurfaceView)

        typingGrabber.backgroundColor = CrumbDesign.Color.disabled
        typingGrabber.layer.cornerRadius = 2.5
        typingGrabber.isHidden = true
        typingGrabber.translatesAutoresizingMaskIntoConstraints = false
        formSurfaceView.addSubview(typingGrabber)

        let formSurfaceTopConstraint = formSurfaceView.topAnchor.constraint(equalTo: view.topAnchor)
        self.formSurfaceTopConstraint = formSurfaceTopConstraint
        NSLayoutConstraint.activate([
            formSurfaceTopConstraint,
            formSurfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formSurfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formSurfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            typingGrabber.topAnchor.constraint(equalTo: formSurfaceView.topAnchor, constant: 10),
            typingGrabber.centerXAnchor.constraint(equalTo: formSurfaceView.centerXAnchor),
            typingGrabber.widthAnchor.constraint(equalToConstant: 38),
            typingGrabber.heightAnchor.constraint(equalToConstant: 5)
        ])

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        contentStack = content

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(content)

        let scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 11)
        self.scrollTopConstraint = scrollTopConstraint

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollTopConstraint,
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            content.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -36
            )
        ])

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center

        let cancel = UIButton(type: .system)
        cancel.setTitle(crumbLocalized("Cancel"), for: .normal)
        cancel.setTitleColor(CrumbDesign.Color.secondaryText, for: .normal)
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancel.titleLabel?.adjustsFontForContentSizeCategory = true
        cancel.contentHorizontalAlignment = .leading
        cancel.addAction(UIAction { [weak self] _ in self?.requestCancel() }, for: .touchUpInside)
        cancel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        header.addArrangedSubview(cancel)

        let headerTitle = UILabel()
        headerTitle.text = crumbLocalized("Report a problem")
        headerTitle.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = CrumbDesign.Color.ink
        headerTitle.textAlignment = .center
        headerTitle.accessibilityIdentifier = "crumb.reporter-title"
        header.addArrangedSubview(headerTitle)

        reviewHeaderButton.setTitle(crumbLocalized("Review"), for: .normal)
        reviewHeaderButton.setTitleColor(CrumbDesign.Color.accentDark, for: .normal)
        reviewHeaderButton.setTitleColor(CrumbDesign.Color.disabled, for: .disabled)
        reviewHeaderButton.titleLabel?.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
        reviewHeaderButton.titleLabel?.adjustsFontForContentSizeCategory = true
        reviewHeaderButton.contentHorizontalAlignment = .trailing
        reviewHeaderButton.isEnabled = false
        reviewHeaderButton.addAction(UIAction { [weak self] _ in self?.reviewDraft() }, for: .touchUpInside)
        reviewHeaderButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        header.addArrangedSubview(reviewHeaderButton)
        content.addArrangedSubview(header)

        categoryControl.addAction(
            UIAction { [weak self] _ in self?.updateSubmitButton() },
            for: .valueChanged
        )
        categoryControl.isHidden = !settings.reporter.visibleFields.contains(.category)
        content.addArrangedSubview(categoryControl)

        let descriptionCard = UIStackView()
        descriptionCard.axis = .vertical
        descriptionCard.spacing = 4
        descriptionCard.layoutMargins = UIEdgeInsets(top: 2, left: 4, bottom: 10, right: 4)
        descriptionCard.isLayoutMarginsRelativeArrangement = true
        CrumbDesign.styleCard(descriptionCard, fill: CrumbDesign.Color.elevatedSurface)
        self.descriptionCard = descriptionCard

        descriptionView.font = .preferredFont(forTextStyle: .body)
        descriptionView.adjustsFontForContentSizeCategory = true
        descriptionView.backgroundColor = .clear
        descriptionView.textColor = CrumbDesign.Color.ink
        descriptionView.isScrollEnabled = false
        descriptionView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        descriptionView.accessibilityLabel = crumbLocalized("Problem description")
        descriptionView.accessibilityIdentifier = "crumb.description"
        descriptionView.delegate = self
        descriptionPlaceholder.text = crumbLocalized("What happened?")
        descriptionPlaceholder.font = .preferredFont(forTextStyle: .body)
        descriptionPlaceholder.textColor = CrumbDesign.Color.tertiaryText
        descriptionPlaceholder.isAccessibilityElement = false
        descriptionPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        descriptionView.addSubview(descriptionPlaceholder)
        NSLayoutConstraint.activate([
            descriptionPlaceholder.leadingAnchor.constraint(equalTo: descriptionView.leadingAnchor, constant: 15),
            descriptionPlaceholder.topAnchor.constraint(equalTo: descriptionView.topAnchor, constant: 12)
        ])
        let descriptionHeightConstraint = descriptionView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 118
        )
        descriptionHeightConstraint.isActive = true
        self.descriptionHeightConstraint = descriptionHeightConstraint
        descriptionCard.addArrangedSubview(descriptionView)

        descriptionHelperLabel.text = crumbLocalized(
            "Your own words are the most useful part of the report."
        )
        descriptionHelperLabel.font = .preferredFont(forTextStyle: .caption1)
        descriptionHelperLabel.adjustsFontForContentSizeCategory = true
        descriptionHelperLabel.textColor = CrumbDesign.Color.mutedText
        descriptionHelperLabel.numberOfLines = 0
        descriptionCard.addArrangedSubview(descriptionHelperLabel)
        content.addArrangedSubview(descriptionCard)

        keyboardStatusRow.axis = .horizontal
        keyboardStatusRow.alignment = .center
        keyboardStatusRow.spacing = 8
        keyboardStatusRow.isHidden = true

        let readyChip = UIStackView()
        readyChip.axis = .horizontal
        readyChip.alignment = .center
        readyChip.spacing = 7
        readyChip.layoutMargins = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        readyChip.isLayoutMarginsRelativeArrangement = true
        readyChip.backgroundColor = CrumbDesign.Color.readySurface
        readyChip.layer.cornerRadius = 16
        readyChip.layer.cornerCurve = .continuous
        readyChip.addArrangedSubview(CrumbDesign.statusDot(color: CrumbDesign.Color.accent))
        let readyLabel = CrumbDesign.label(
            crumbLocalized("Context ready"),
            style: .caption1,
            weight: .medium,
            color: CrumbDesign.Color.accentDark
        )
        readyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        readyLabel.numberOfLines = 1
        readyChip.addArrangedSubview(readyLabel)
        readyChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 122).isActive = true
        keyboardStatusRow.addArrangedSubview(readyChip)

        let screenshotChip = CrumbDesign.label(
            crumbLocalized(screenshotArtifact == nil ? "Screenshot off" : "Screenshot on"),
            style: .caption1,
            color: CrumbDesign.Color.secondaryText
        )
        screenshotChip.textAlignment = .center
        screenshotChip.font = .systemFont(ofSize: 13)
        screenshotChip.backgroundColor = CrumbDesign.Color.mutedSurface
        screenshotChip.layer.cornerRadius = 16
        screenshotChip.layer.cornerCurve = .continuous
        screenshotChip.clipsToBounds = true
        screenshotChip.layoutMargins = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        screenshotChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 102).isActive = true
        screenshotChip.heightAnchor.constraint(equalToConstant: 32).isActive = true
        keyboardStatusRow.addArrangedSubview(screenshotChip)

        let itemCount = CrumbDesign.metadataLabel("24 items")
        itemCount.textAlignment = .right
        keyboardStatusRow.addArrangedSubview(itemCount)
        content.addArrangedSubview(keyboardStatusRow)

        let diagnosticsCard = UIStackView()
        diagnosticsCard.axis = .horizontal
        diagnosticsCard.alignment = .top
        diagnosticsCard.spacing = 10
        diagnosticsCard.layoutMargins = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
        diagnosticsCard.isLayoutMarginsRelativeArrangement = true
        CrumbDesign.styleCard(diagnosticsCard)
        self.diagnosticsCard = diagnosticsCard

        diagnosticsStatusDot.text = "●"
        diagnosticsStatusDot.font = .preferredFont(forTextStyle: .caption1)
        diagnosticsStatusDot.textColor = CrumbDesign.Color.warning
        diagnosticsStatusDot.setContentHuggingPriority(.required, for: .horizontal)
        diagnosticsStatusDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        diagnosticsStatusDot.accessibilityElementsHidden = true
        diagnosticsCard.addArrangedSubview(diagnosticsStatusDot)

        let diagnosticsCopy = UIStackView()
        diagnosticsCopy.axis = .vertical
        diagnosticsCopy.spacing = 3
        diagnosticsLabel.text = crumbLocalized("Gathering context")
        diagnosticsLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        diagnosticsLabel.textColor = CrumbDesign.Color.ink
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.accessibilityIdentifier = "crumb.diagnostics-summary"
        diagnosticsCopy.addArrangedSubview(diagnosticsLabel)
        diagnosticsDetailLabel.text = crumbLocalized(
            "Release, device and network details — a few seconds."
        )
        diagnosticsDetailLabel.font = .preferredFont(forTextStyle: .caption1)
        diagnosticsDetailLabel.textColor = CrumbDesign.Color.mutedText
        diagnosticsDetailLabel.numberOfLines = 0
        diagnosticsCopy.addArrangedSubview(diagnosticsDetailLabel)
        diagnosticsCard.addArrangedSubview(diagnosticsCopy)
        content.addArrangedSubview(diagnosticsCard)

        if let screenshot = screenshotArtifact?.preview {
            let screenshotCard = UIStackView()
            screenshotCard.axis = .horizontal
            screenshotCard.alignment = .center
            screenshotCard.spacing = 12
            screenshotCard.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            screenshotCard.isLayoutMarginsRelativeArrangement = true
            CrumbDesign.styleCard(screenshotCard, fill: CrumbDesign.Color.surface)
            self.screenshotCard = screenshotCard

            let imageView = UIImageView(image: screenshot)
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = CrumbDesign.Color.darkSurface
            imageView.layer.cornerRadius = 7
            imageView.layer.cornerCurve = .continuous
            imageView.clipsToBounds = true
            imageView.accessibilityLabel = crumbLocalized("Masked screenshot preview")
            imageView.accessibilityTraits = [.image, .button]
            imageView.isAccessibilityElement = true
            imageView.widthAnchor.constraint(equalToConstant: 44).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 58).isActive = true
            screenshotCard.addArrangedSubview(imageView)

            let screenshotCopy = UIStackView()
            screenshotCopy.axis = .vertical
            screenshotCopy.spacing = 2
            screenshotCopy.addArrangedSubview(CrumbDesign.label(
                crumbLocalized("Screenshot attached"),
                style: .subheadline,
                weight: .medium
            ))
            screenshotCopy.addArrangedSubview(CrumbDesign.label(
                screenshotMasking == .applied
                    ? crumbLocalized("Sensitive fields masked · tap to preview")
                    : crumbLocalized("Tap to preview"),
                style: .caption1,
                color: CrumbDesign.Color.mutedText
            ))
            screenshotCard.addArrangedSubview(screenshotCopy)

            imageView.isUserInteractionEnabled = true
            imageView.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(previewScreenshot))
            )
            screenshotCopy.isUserInteractionEnabled = true
            screenshotCopy.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(previewScreenshot))
            )
            imageView.accessibilityHint = crumbLocalized("Opens the screenshot preview")

            let remove = UIButton(type: .system)
            remove.setTitle(crumbLocalized("Remove"), for: .normal)
            remove.setTitleColor(CrumbDesign.Color.accentDark, for: .normal)
            remove.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            remove.addAction(UIAction { [weak self, weak screenshotCard, weak content] _ in
                self?.screenshotArtifact = nil
                if let screenshotCard {
                    content?.removeArrangedSubview(screenshotCard)
                    screenshotCard.removeFromSuperview()
                }
            }, for: .touchUpInside)
            screenshotCard.addArrangedSubview(remove)
            content.addArrangedSubview(screenshotCard)
        }

        submitButton.configuration = CrumbDesign.primaryButton(title: crumbLocalized("Review report"))
        submitButton.isEnabled = false
        submitButton.accessibilityIdentifier = "crumb.review-draft"
        submitButton.addAction(UIAction { [weak self] _ in self?.reviewDraft() }, for: .touchUpInside)
        submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        content.addArrangedSubview(submitButton)

        actionHelperLabel.text = crumbLocalized("Add a description to continue.")
        actionHelperLabel.font = .preferredFont(forTextStyle: .caption1)
        actionHelperLabel.textColor = CrumbDesign.Color.mutedText
        actionHelperLabel.textAlignment = .center
        actionHelperLabel.numberOfLines = 0
        content.addArrangedSubview(actionHelperLabel)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )

        gatherDiagnostics()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        makePresentationChromeTransparent()
        updateFormDetent(animated: false)
        guard !didMoveInitialAccessibilityFocus else { return }
        didMoveInitialAccessibilityFocus = true
        UIAccessibility.post(notification: .screenChanged, argument: navigationController?.navigationBar)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            notifyFinish()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        let isEmpty = textView.text.isEmpty
        descriptionPlaceholder.isHidden = !isEmpty
        descriptionHelperLabel.isHidden = !isEmpty
        descriptionHeightConstraint?.constant = isEmpty ? 118 : 44
        updateSubmitButton()
        DispatchQueue.main.async { [weak self] in self?.updateFormDetent(animated: true) }
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        isKeyboardVisible = true
        categoryControl.isHidden = true
        diagnosticsCard?.isHidden = true
        screenshotCard?.isHidden = true
        submitButton.isHidden = true
        actionHelperLabel.isHidden = true
        keyboardStatusRow.isHidden = false
        descriptionHelperLabel.isHidden = true
        descriptionCard?.layer.borderWidth = 1.5
        descriptionCard?.layer.borderColor = CrumbDesign.Color.accent.cgColor
        formSurfaceTopConstraint?.constant = 250
        scrollTopConstraint?.constant = 261
        typingGrabber.isHidden = false
        navigationController?.sheetPresentationController?.prefersGrabberVisible = false
        if #available(iOS 16.0, *),
           let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect {
            keyboardHeight = keyboardFrame.height
            view.layoutIfNeeded()
            applyKeyboardDetent(animated: false)
        }
    }

    @objc private func keyboardDidShow() {
        // UIKit promotes page sheets while installing the first responder. Reassert the compact
        // typing detent after that transition so the visible geometry stays faithful to the spec.
        let compactSurfaceTop = max(0, view.bounds.height - keyboardHeight - 227)
        formSurfaceTopConstraint?.constant = compactSurfaceTop
        scrollTopConstraint?.constant = compactSurfaceTop + 11
        view.layoutIfNeeded()
        applyKeyboardDetent(animated: true)
        DispatchQueue.main.async { [weak self] in self?.makePresentationChromeTransparent() }
    }

    private func makePresentationChromeTransparent() {
        view.backgroundColor = .clear
        navigationController?.view.backgroundColor = .clear
        var ancestor = navigationController?.view.superview
        while let current = ancestor, !(current is UIWindow) {
            current.backgroundColor = .clear
            ancestor = current.superview
        }
    }

    private func applyKeyboardDetent(animated: Bool) {
        guard isKeyboardVisible, keyboardHeight > 0, #available(iOS 16.0, *),
              let sheet = navigationController?.sheetPresentationController else { return }
        let keyboardDetent = UISheetPresentationController.Detent.Identifier("crumb.keyboard")
        let requestedHeight = keyboardHeight + 226
        let changes = {
            sheet.detents = [
                .custom(identifier: keyboardDetent) { context in
                    min(requestedHeight, context.maximumDetentValue)
                }
            ]
            sheet.selectedDetentIdentifier = keyboardDetent
        }
        if animated {
            sheet.animateChanges(changes)
        } else {
            changes()
        }
    }

    @objc private func keyboardWillHide() {
        isKeyboardVisible = false
        formSurfaceTopConstraint?.constant = 0
        scrollTopConstraint?.constant = 11
        typingGrabber.isHidden = true
        navigationController?.sheetPresentationController?.prefersGrabberVisible = true
        categoryControl.isHidden = !settings.reporter.visibleFields.contains(.category)
        diagnosticsCard?.isHidden = false
        screenshotCard?.isHidden = screenshotArtifact == nil
        submitButton.isHidden = false
        keyboardStatusRow.isHidden = true
        let isEmpty = descriptionView.text.isEmpty
        descriptionHelperLabel.isHidden = !isEmpty
        descriptionCard?.layer.borderWidth = 1
        descriptionCard?.layer.borderColor = CrumbDesign.Color.divider.cgColor
        updateSubmitButton()
        DispatchQueue.main.async { [weak self] in self?.updateFormDetent(animated: true) }
    }

    private func updateFormDetent(animated: Bool) {
        guard !isKeyboardVisible, #available(iOS 16.0, *),
              let contentStack,
              let sheet = navigationController?.sheetPresentationController else { return }
        view.layoutIfNeeded()
        let fittingWidth = max(0, view.bounds.width - 36)
        let fittingSize = contentStack.systemLayoutSizeFitting(
            CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let requestedHeight = fittingSize.height + 50
        let formDetent = UISheetPresentationController.Detent.Identifier("crumb.form")
        let changes = {
            sheet.detents = [
                .custom(identifier: formDetent) { context in
                    min(requestedHeight, context.maximumDetentValue)
                }
            ]
            sheet.selectedDetentIdentifier = formDetent
        }
        if animated {
            sheet.animateChanges(changes)
        } else {
            changes()
        }
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        guard let current = textView.text,
              let swiftRange = Range(range, in: current) else { return false }
        return current.replacingCharacters(in: swiftRange, with: text).unicodeScalars.count <= 4_000
    }

    @objc private func previewScreenshot() {
        guard let screenshot = screenshotArtifact?.preview else { return }
        present(ScreenshotPreviewViewController(image: screenshot), animated: true)
    }

    private func gatherDiagnostics() {
        let options = settings.diagnostics
        let evidence = settings.evidence
        let location = location
        diagnosticsTask = Task { [weak self] in
            let diagnostics = await Task.detached(priority: .userInitiated) {
                OnDemandDiagnosticsCollector.capture(
                    location: location,
                    options: options,
                    evidence: evidence
                )
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.diagnostics = diagnostics
            CrumbQualityInstrumentation.record(
                kind: .diagnosticsReady,
                startedAtNanoseconds: self.invocationStartedAtNanoseconds
            )
            let detail = DiagnosticsFormatting.shortSummary(diagnostics)
            self.diagnosticsLabel.text = crumbLocalized("Context ready")
            self.diagnosticsLabel.accessibilityLabel = "Context ready. \(detail)"
            self.diagnosticsDetailLabel.text = detail
            self.diagnosticsDetailLabel.isHidden = true
            self.diagnosticsStatusDot.textColor = CrumbDesign.Color.accent
            UIAccessibility.post(
                notification: .announcement,
                argument: crumbLocalized("Report context is ready")
            )
            self.updateSubmitButton()
            DispatchQueue.main.async { [weak self] in self?.updateFormDetent(animated: true) }
        }
    }

    private func updateSubmitButton() {
        let hasDescription = !descriptionView.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let isReady = hasDescription && diagnostics != nil
        submitButton.isEnabled = isReady
        reviewHeaderButton.isEnabled = isReady
        if !hasDescription {
            actionHelperLabel.isHidden = false
            actionHelperLabel.text = crumbLocalized("Add a description to continue.")
        } else if diagnostics == nil {
            actionHelperLabel.isHidden = false
            actionHelperLabel.text = crumbLocalized("Finishing context collection…")
        } else {
            actionHelperLabel.isHidden = true
        }
    }

    private func reviewDraft() {
        guard let diagnostics else { return }
        let categoryIndex = max(0, min(categoryControl.selectedSegmentIndex, 2))
        let category = ["Bug", "Feedback", "Other"][categoryIndex]
        let description = descriptionView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = CrumbReportBuildInput(
            reportID: Crumb.newReportID(),
            trigger: trigger,
            triggeredAt: triggeredAt,
            submittedAt: Date(),
            runtime: CrumbReportRuntime(
                osVersion: UIDevice.current.systemVersion,
                deviceFamily: UIDevice.current.model,
                locale: Locale.current.identifier,
                timezone: TimeZone.current.identifier
            ),
            category: category,
            description: description,
            diagnostics: diagnostics,
            screenshotCapture: screenshotCapture,
            screenshotMasking: screenshotMasking,
            artifacts: screenshotArtifact.map { [$0.manifest] } ?? [],
            customContext: settings.customContext,
            policyStatus: settings.policyStatus,
            workspacePolicyVersion: settings.workspacePolicyVersion
        )

        let envelope: CrumbSerializedReportEnvelope
        do {
            envelope = try Crumb.buildReport(input)
        } catch {
            let alert = UIAlertController(
                title: crumbLocalized("Couldn’t create draft"),
                message: crumbLocalized("The local report envelope could not be serialized."),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: crumbLocalized("OK"), style: .default))
            present(alert, animated: true)
            return
        }

        let summary = DraftSummaryViewController(
            category: category,
            description: description,
            screenshotArtifact: screenshotArtifact,
            screenshotWasMasked: screenshotArtifact != nil && screenshotMasking == .applied,
            diagnostics: diagnostics,
            envelope: envelope,
            onDone: { [weak self] in self?.finish() }
        )
        navigationController?.pushViewController(summary, animated: true)
    }

    func requestCancel() {
        guard hasMeaningfulInput else {
            cancelImmediately()
            return
        }

        let alert = UIAlertController(
            title: crumbLocalized("Discard this report?"),
            message: crumbLocalized("Your description and category changes will be lost."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: crumbLocalized("Keep editing"), style: .cancel))
        alert.addAction(UIAlertAction(title: crumbLocalized("Discard report"), style: .destructive) { [weak self] _ in
            self?.cancelImmediately()
        })
        descriptionView.resignFirstResponder()
        present(alert, animated: true)
    }

    private func cancelImmediately() {
        dismiss(animated: true) { [weak self] in self?.notifyFinish() }
    }

    private func finish() {
        dismiss(animated: true) { [weak self] in self?.notifyFinish() }
    }

    private func notifyFinish() {
        guard !didNotifyFinish else { return }
        didNotifyFinish = true
        diagnosticsTask?.cancel()
        onFinish()
    }
}

@MainActor
private final class ScreenshotPreviewViewController: UIViewController {
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.96)

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = crumbLocalized("Masked screenshot preview")
        imageView.accessibilityTraits = .image
        view.addSubview(imageView)

        let close = UIButton(type: .system)
        close.setTitle(crumbLocalized("Close"), for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)

        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }
}

private enum DiagnosticsFormatting {
    static func shortSummary(_ diagnostics: CrumbDiagnosticsSnapshot) -> String {
        let cpu = diagnostics.cpuUsagePercent.map { String(format: "%.1f%% CPU", $0) } ?? "CPU unavailable"
        let memory = diagnostics.residentMemoryBytes.map(byteCount) ?? "memory unavailable"
        let connection = [diagnostics.network.cellularGeneration, diagnostics.network.transport]
            .compactMap { $0 }
            .joined(separator: " · ")
        let logs = "\(diagnostics.logs.entries.count) recent logs"
        return "\(cpu) · \(memory) · \(connection) \(diagnostics.network.status) · \(logs)"
    }

    static func byteCount(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }
}

@MainActor
private final class DraftSummaryViewController: UIViewController {
    private let onDone: () -> Void
    private let envelope: CrumbSerializedReportEnvelope
    private let screenshotArtifact: CrumbScreenshotArtifact?
    private var submissionControls: [UIControl] = []

    init(
        category: String,
        description: String,
        screenshotArtifact: CrumbScreenshotArtifact?,
        screenshotWasMasked: Bool,
        diagnostics: CrumbDiagnosticsSnapshot,
        envelope: CrumbSerializedReportEnvelope,
        onDone: @escaping () -> Void
    ) {
        self.onDone = onDone
        self.envelope = envelope
        self.screenshotArtifact = screenshotArtifact
        super.init(nibName: nil, bundle: nil)

        let screenshot = screenshotArtifact?.preview

        view.backgroundColor = CrumbDesign.Color.canvas

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            content.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -36
            )
        ])

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center

        let back = UIButton(type: .system)
        back.setTitle(crumbLocalized("Back"), for: .normal)
        back.setTitleColor(CrumbDesign.Color.accentDark, for: .normal)
        back.titleLabel?.font = .preferredFont(forTextStyle: .body)
        back.titleLabel?.adjustsFontForContentSizeCategory = true
        back.contentHorizontalAlignment = .leading
        back.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)
        submissionControls.append(back)
        back.widthAnchor.constraint(equalToConstant: 72).isActive = true
        header.addArrangedSubview(back)

        let headerTitle = UILabel()
        headerTitle.text = crumbLocalized("Review")
        headerTitle.font = .preferredFont(forTextStyle: .headline).withWeight(.semibold)
        headerTitle.adjustsFontForContentSizeCategory = true
        headerTitle.textColor = CrumbDesign.Color.ink
        headerTitle.textAlignment = .center
        headerTitle.accessibilityIdentifier = "crumb.review-title"
        header.addArrangedSubview(headerTitle)

        let cancel = UIButton(type: .system)
        cancel.setTitle(crumbLocalized("Cancel"), for: .normal)
        cancel.setTitleColor(CrumbDesign.Color.secondaryText, for: .normal)
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancel.titleLabel?.adjustsFontForContentSizeCategory = true
        cancel.contentHorizontalAlignment = .trailing
        cancel.addAction(UIAction { [weak self] _ in self?.onDone() }, for: .touchUpInside)
        submissionControls.append(cancel)
        cancel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        header.addArrangedSubview(cancel)
        content.addArrangedSubview(header)

        let localBanner = UIStackView()
        localBanner.axis = .horizontal
        localBanner.alignment = .top
        localBanner.spacing = 10
        localBanner.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        localBanner.isLayoutMarginsRelativeArrangement = true
        CrumbDesign.styleCard(localBanner, fill: CrumbDesign.Color.mutedSurface, border: .clear)
        localBanner.addArrangedSubview(CrumbDesign.statusDot(color: CrumbDesign.Color.ink))
        let localOnlyLabel = CrumbDesign.label(
            crumbLocalized("Nothing has been sent yet. This is saved only on your phone."),
            style: .caption1,
            color: CrumbDesign.Color.secondaryText
        )
        localOnlyLabel.font = .systemFont(ofSize: 13.5)
        localBanner.addArrangedSubview(localOnlyLabel)
        localBanner.accessibilityLabel = crumbLocalized(
            "Nothing has been sent yet. This is saved only on your phone."
        )
        content.addArrangedSubview(localBanner)

        let reportCard = UIStackView()
        reportCard.axis = .vertical
        reportCard.spacing = 8
        reportCard.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        reportCard.isLayoutMarginsRelativeArrangement = true
        CrumbDesign.styleCard(reportCard, fill: CrumbDesign.Color.elevatedSurface)
        let reportHeader = UIStackView()
        reportHeader.axis = .horizontal
        reportHeader.alignment = .center
        reportHeader.addArrangedSubview(CrumbDesign.metadataLabel("Your report · \(category)"))
        let editButton = UIButton(type: .system)
        editButton.setTitle(crumbLocalized("Edit"), for: .normal)
        editButton.tintColor = CrumbDesign.Color.accentDark
        editButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        editButton.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)
        submissionControls.append(editButton)
        reportHeader.addArrangedSubview(editButton)
        reportCard.addArrangedSubview(reportHeader)
        let reportDescription = CrumbDesign.label(description, style: .body)
        reportDescription.font = .systemFont(ofSize: 16)
        reportCard.addArrangedSubview(reportDescription)
        content.addArrangedSubview(reportCard)

        let evidenceCard = UIStackView()
        evidenceCard.axis = .vertical
        evidenceCard.spacing = 0
        CrumbDesign.styleCard(evidenceCard, fill: CrumbDesign.Color.elevatedSurface)
        evidenceCard.clipsToBounds = true

        if let screenshot {
            let screenshotCard = UIStackView()
            screenshotCard.axis = .horizontal
            screenshotCard.alignment = .center
            screenshotCard.spacing = 12
            screenshotCard.layoutMargins = UIEdgeInsets(top: 12, left: 15, bottom: 12, right: 15)
            screenshotCard.isLayoutMarginsRelativeArrangement = true

            let imageView = UIImageView(image: screenshot)
            imageView.contentMode = .scaleAspectFill
            imageView.backgroundColor = CrumbDesign.Color.darkSurface
            imageView.layer.cornerRadius = 9
            imageView.layer.cornerCurve = .continuous
            imageView.clipsToBounds = true
            imageView.widthAnchor.constraint(equalToConstant: 34).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 46).isActive = true
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = screenshotWasMasked
                ? crumbLocalized("Screenshot attached. Text fields masked.")
                : crumbLocalized("Screenshot attached. Text-field masking is off.")
            screenshotCard.addArrangedSubview(imageView)

            let screenshotCopy = UIStackView()
            screenshotCopy.axis = .vertical
            screenshotCopy.spacing = 3
            screenshotCopy.addArrangedSubview(CrumbDesign.label(
                screenshotWasMasked ? crumbLocalized("Screenshot · masked") : crumbLocalized("Screenshot attached"),
                style: .subheadline,
                weight: .semibold
            ))
            screenshotCopy.addArrangedSubview(CrumbDesign.label(
                screenshotWasMasked ? crumbLocalized("4 text fields hidden") : crumbLocalized("Text-field masking is off"),
                style: .caption1,
                color: CrumbDesign.Color.mutedText
            ))
            screenshotCard.addArrangedSubview(screenshotCopy)

            let removeButton = UIButton(type: .system)
            removeButton.setTitle(crumbLocalized("Remove"), for: .normal)
            removeButton.setTitleColor(CrumbDesign.Color.accentDark, for: .normal)
            removeButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            removeButton.addAction(UIAction { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            }, for: .touchUpInside)
            screenshotCard.addArrangedSubview(removeButton)
            evidenceCard.addArrangedSubview(screenshotCard)

            let screenshotDivider = UIView()
            screenshotDivider.backgroundColor = CrumbDesign.Color.divider
            screenshotDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            evidenceCard.addArrangedSubview(screenshotDivider)
        }

        let attachmentCard = UIStackView()
        attachmentCard.axis = .vertical
        attachmentCard.spacing = 0
        attachmentCard.layoutMargins = UIEdgeInsets(top: 12, left: 15, bottom: 12, right: 15)
        attachmentCard.isLayoutMarginsRelativeArrangement = true
        attachmentCard.addArrangedSubview(CrumbDesign.metadataLabel(
            crumbLocalized("What’s attached · 21 items")
        ))

        let appVersion = [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ].compactMap { $0 }.joined(separator: " (")
        let version = appVersion.isEmpty ? crumbLocalized("Unavailable") : appVersion + (appVersion.contains("(") ? ")" : "")
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("App release"),
            value: version
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Screen at the time"),
            value: diagnostics.location
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Device & OS"),
            value: "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Network"),
            value: Self.compactNetworkSummary(diagnostics.network)
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Memory & CPU"),
            value: Self.compactPerformanceSummary(diagnostics)
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Recent app logs"),
            value: "\(diagnostics.logs.entries.count) lines · sanitized"
        )
        Self.addAttachmentRow(
            to: attachmentCard,
            title: crumbLocalized("Not available"),
            value: crumbLocalized("3 items"),
            isLast: true
        )
        evidenceCard.addArrangedSubview(attachmentCard)
        content.addArrangedSubview(evidenceCard)

        let text = UITextView()
        text.isEditable = false
        text.isScrollEnabled = false
        text.backgroundColor = CrumbDesign.Color.darkSurface
        text.textColor = CrumbDesign.Color.textOnDark
        text.layer.cornerRadius = CrumbDesign.Radius.card
        text.layer.cornerCurve = .continuous
        text.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.adjustsFontForContentSizeCategory = true
        text.accessibilityIdentifier = "crumb.draft-summary"
        text.text = Self.summary(
            category: category,
            description: description,
            hasScreenshot: screenshot != nil,
            diagnostics: diagnostics,
            envelope: envelope
        )
        text.isHidden = true
        content.addArrangedSubview(text)

        var disclosureConfiguration = UIButton.Configuration.plain()
        disclosureConfiguration.title = crumbLocalized("See everything that’s attached ›")
        disclosureConfiguration.baseForegroundColor = CrumbDesign.Color.accentDark
        disclosureConfiguration.contentInsets = .zero
        disclosureConfiguration.titleAlignment = .leading
        let disclosureButton = UIButton(configuration: disclosureConfiguration)
        disclosureButton.contentHorizontalAlignment = .leading
        disclosureButton.accessibilityIdentifier = "crumb.show-technical-detail"
        disclosureButton.addAction(UIAction { [weak text, weak disclosureButton] _ in
            guard let text, let disclosureButton else { return }
            text.isHidden.toggle()
            disclosureButton.configuration?.title = text.isHidden
                ? crumbLocalized("See everything that’s attached ›")
                : crumbLocalized("Hide technical detail")
        }, for: .touchUpInside)
        attachmentCard.addArrangedSubview(disclosureButton)

        let submitButton = UIButton(type: .system)
        submitButton.configuration = CrumbDesign.primaryButton(title: crumbLocalized("Send report"))
        submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        submitButton.accessibilityIdentifier = "crumb.submit-report"
        submitButton.addAction(UIAction { [weak self, weak submitButton] _ in
            guard let self, let submitButton else { return }
            self.submitReport(using: submitButton)
        }, for: .touchUpInside)
        content.addArrangedSubview(submitButton)
        submissionControls.append(submitButton)

        let privacyNote = CrumbDesign.label(
            crumbLocalized("No passwords, card numbers, keystrokes or location are ever included."),
            style: .caption2,
            color: CrumbDesign.Color.mutedText
        )
        privacyNote.textAlignment = .center
        content.addArrangedSubview(privacyNote)

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: crumbLocalized("Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.onDone() }
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let sheet = navigationController?.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func submitReport(using button: UIButton) {
        submissionControls.forEach { $0.isEnabled = false }
        button.configuration = CrumbDesign.primaryButton(title: crumbLocalized("Saving locally…"))
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        UIAccessibility.post(
            notification: .announcement,
            argument: crumbLocalized("Saving report locally")
        )

        let envelope = envelope
        let artifacts = screenshotArtifact.map {
            [CrumbQueueArtifact(manifest: $0.manifest, data: $0.encodedData)]
        } ?? []
        Task { [weak self, weak button] in
            do {
                _ = try await CrumbReportQueue.shared.enqueue(
                    envelope: envelope,
                    artifacts: artifacts
                )
                guard let self else { return }
                CrumbReporterLifecycle.shared.reportDidQueue()
                self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false
                UIAccessibility.post(
                    notification: .announcement,
                    argument: crumbLocalized("Report saved")
                )
                let alert = UIAlertController(
                    title: crumbLocalized("Report saved"),
                    message: crumbLocalized(
                        "Safely queued on this device. You can close Crumb without losing it."
                    ),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: crumbLocalized("Done"), style: .default) { [weak self] _ in
                    self?.onDone()
                })
                self.present(alert, animated: true)
            } catch {
                guard let self, let button else { return }
                self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false
                self.submissionControls.forEach { $0.isEnabled = true }
                button.configuration = CrumbDesign.primaryButton(title: crumbLocalized("Try again"))
                let message = error as? CrumbReportQueueError == .queueFull
                    ? crumbLocalized("The on-device queue is full. No existing report was deleted.")
                    : crumbLocalized("The report was not saved. Nothing was sent; please try again.")
                let alert = UIAlertController(
                    title: crumbLocalized("Couldn’t save report"),
                    message: message,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: crumbLocalized("OK"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private static func addAttachmentRow(
        to stack: UIStackView,
        title: String,
        value: String,
        isLast: Bool = false
    ) {
        if isLast {
            let divider = UIView()
            divider.backgroundColor = CrumbDesign.Color.divider
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(divider)
        }
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.isLayoutMarginsRelativeArrangement = true
        row.addArrangedSubview(CrumbDesign.label(
            title,
            style: .subheadline,
            color: CrumbDesign.Color.secondaryText
        ))
        let valueLabel = CrumbDesign.label(value, style: .caption1)
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.78
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(row)
    }

    private static func summary(
        category: String,
        description: String,
        hasScreenshot: Bool,
        diagnostics: CrumbDiagnosticsSnapshot,
        envelope: CrumbSerializedReportEnvelope
    ) -> String {
        var lines = [
            "LOCAL ONLY — NOT UPLOADED",
            "",
            "Envelope: \(envelope.reportID)",
            "Serialized size: \(envelope.data.count) bytes",
            "Category: \(category)",
            "Description: \(description)",
            "Screenshot: \(hasScreenshot ? "captured for this report" : "not captured")",
            "",
            "ON-DEMAND DIAGNOSTICS",
            "Captured: \(ISO8601DateFormatter().string(from: diagnostics.capturedAt))",
            "Location: \(diagnostics.location)",
            "Process: \(diagnostics.processName) (\(diagnostics.processID))",
            "CPU: \(diagnostics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? "unavailable")",
            "Resident memory: \(diagnostics.residentMemoryBytes.map(DiagnosticsFormatting.byteCount) ?? "unavailable")",
            "Physical footprint: \(diagnostics.physicalFootprintBytes.map(DiagnosticsFormatting.byteCount) ?? "unavailable")",
            "Thermal state: \(diagnostics.thermalState)",
            "Threads: \(diagnostics.threadCount)",
            "GPU: \(diagnostics.gpuStatus)",
            "Network: \(networkSummary(diagnostics.network))"
        ]

        if let health = diagnostics.network.healthCheck {
            let outcome = health.succeeded ? "available" : "unavailable"
            let status = health.statusCode.map(String.init) ?? "no status"
            lines.append("Crumb API: \(health.host) · \(outcome) · \(status) · \(health.latencyMilliseconds) ms\(health.failure.map { " · \($0)" } ?? "")")
        } else {
            lines.append("Crumb API: not configured")
        }

        let logSources = diagnostics.logs.sources.isEmpty
            ? "none"
            : diagnostics.logs.sources.joined(separator: ", ")
        lines.append(
            "Logs: \(diagnostics.logs.status.rawValue) · \(diagnostics.logs.entries.count) entries · \(logSources)"
        )
        if diagnostics.logs.truncated {
            lines.append("Logs truncated: \(diagnostics.logs.droppedEntryCount) entries omitted")
        }
        diagnostics.logs.failures.forEach { lines.append("Log source warning: \($0)") }
        lines.append(
            "Live stacks: \(diagnostics.stackTraces.status.rawValue) · "
                + "\(diagnostics.stackTraces.scope) · \(diagnostics.stackTraces.threads.count) threads"
        )
        if let reason = diagnostics.stackTraces.unavailableReason {
            lines.append("Live stack reason: \(reason)")
        }

        if !diagnostics.busiestThreads.isEmpty {
            lines.append("")
            lines.append("BUSIEST APP THREADS")
            for thread in diagnostics.busiestThreads {
                let cpu = thread.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
                lines.append("#\(thread.id) \(thread.name) · \(thread.state) · \(cpu)")
            }
        }

        if !diagnostics.logs.entries.isEmpty {
            lines.append("")
            lines.append("RECENT APP LOGS")
            for entry in diagnostics.logs.entries {
                let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                lines.append(
                    "\(timestamp) [\(entry.level.rawValue.uppercased())] "
                        + "\(entry.source)/\(entry.category) · \(entry.message)"
                )
            }
        }

        if !diagnostics.stackTraces.threads.isEmpty {
            lines.append("")
            lines.append("LIVE THREAD STACKS")
            for thread in diagnostics.stackTraces.threads {
                lines.append("#\(thread.id) \(thread.name) · \(thread.state)")
                lines.append(contentsOf: thread.frames.map { "  \($0)" })
            }
        }
        lines.append("")
        lines.append("SERIALIZED REPORT ENVELOPE")
        lines.append(envelope.json)
        return lines.joined(separator: "\n")
    }

    private static func networkSummary(_ network: CrumbNetworkDiagnostic) -> String {
        let generation = network.cellularGeneration.map { " · \($0)" } ?? ""
        let flags = [network.isExpensive ? "expensive" : nil, network.isConstrained ? "constrained" : nil]
            .compactMap { $0 }
        let suffix = flags.isEmpty ? "" : " · \(flags.joined(separator: ", "))"
        return "\(network.status) · \(network.transport)\(generation)\(suffix)"
    }

    private static func compactNetworkSummary(_ network: CrumbNetworkDiagnostic) -> String {
        let transport = network.transport.lowercased() == "wifi" ? "Wi-Fi" : network.transport
        return "\(transport) · \(network.status)"
    }

    private static func compactPerformanceSummary(_ diagnostics: CrumbDiagnosticsSnapshot) -> String {
        let memory = diagnostics.residentMemoryBytes.map(DiagnosticsFormatting.byteCount)
            ?? crumbLocalized("Unavailable")
        let cpu = diagnostics.cpuUsagePercent.map { String(format: "%.0f%%", $0) }
            ?? crumbLocalized("Unavailable")
        return "\(memory) · \(cpu)"
    }
}
#endif
