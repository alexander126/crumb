import CrumbCore
import CrumbUI
import OSLog
import UIKit

final class MainViewController: UIViewController {
    private static let logger = Logger(subsystem: "dev.crumb.nativepoc.ios", category: "checkout")
    private let activityLabel = UILabel()
    private let qualityLabel = UILabel()
    private var cpuPressureRunning = false

    init(modeDescription: String) {
        self.modeDescription = modeDescription
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private let modeDescription: String

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Crumb native demo"
        view.backgroundColor = .systemBackground
        configureInterface()
    }

    private func configureInterface() {
        let titleLabel = UILabel()
        titleLabel.text = "Checkout preview"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true

        let body = UILabel()
        body.text = "Crumb stays idle until you report a problem. The card field below must be hidden in the captured screenshot."
        body.font = .preferredFont(forTextStyle: .body)
        body.textColor = .secondaryLabel
        body.numberOfLines = 0

        let modeLabel = UILabel()
        modeLabel.text = modeDescription
        modeLabel.font = .preferredFont(forTextStyle: .caption1)
        modeLabel.textColor = modeDescription == "Staging upload enabled" ? .systemGreen : .secondaryLabel
        modeLabel.accessibilityIdentifier = "demo.delivery-mode"

        let cardField = UITextField()
        cardField.text = "4242 4242 4242 4242"
        cardField.placeholder = "Card number"
        cardField.borderStyle = .roundedRect
        cardField.textContentType = .creditCardNumber
        cardField.accessibilityIdentifier = "demo.sensitive-card"

        activityLabel.text = "No simulated problem running"
        activityLabel.font = .preferredFont(forTextStyle: .subheadline)
        activityLabel.textColor = .secondaryLabel
        activityLabel.accessibilityIdentifier = "demo.activity-count"

        var activityConfiguration = UIButton.Configuration.tinted()
        activityConfiguration.title = "Simulate CPU pressure"
        activityConfiguration.cornerStyle = .large
        let activityButton = UIButton(configuration: activityConfiguration)
        activityButton.accessibilityIdentifier = "demo.simulate-activity"
        activityButton.addAction(UIAction { [weak self] _ in self?.simulateActivity() }, for: .touchUpInside)

        var reportConfiguration = UIButton.Configuration.filled()
        reportConfiguration.title = "Report a problem"
        reportConfiguration.cornerStyle = .large
        let reportButton = UIButton(configuration: reportConfiguration)
        reportButton.accessibilityIdentifier = "demo.report-problem"
        reportButton.addAction(UIAction { _ in
            Self.logger.notice("Problem reporter invoked by button")
            if DemoQualityRecorder.isEnabled {
                DemoQualityRecorder.shared.beginReport()
            }
            Crumb.show()
        }, for: .touchUpInside)
        let shakePreview = UILongPressGestureRecognizer(
            target: self,
            action: #selector(showShakeReporter(_:))
        )
        shakePreview.minimumPressDuration = 0.8
        reportButton.addGestureRecognizer(shakePreview)

        let hint = UILabel()
        hint.text = "You can also shake a physical device."
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .tertiaryLabel
        hint.textAlignment = .center

        var arrangedSubviews: [UIView] = [
            titleLabel,
            modeLabel,
            body,
            cardField,
            activityLabel,
            activityButton,
            reportButton,
            hint
        ]
        if DemoQualityRecorder.isEnabled {
            qualityLabel.accessibilityIdentifier = "demo.quality-results"
            qualityLabel.font = .preferredFont(forTextStyle: .caption2)
            qualityLabel.numberOfLines = 0
            qualityLabel.text = DemoQualityRecorder.shared.summary
            arrangedSubviews.append(qualityLabel)
            DemoQualityRecorder.shared.onUpdate = { [weak self] summary in
                self?.qualityLabel.text = summary
            }
        }
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 18
        stack.setCustomSpacing(28, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            cardField.heightAnchor.constraint(equalToConstant: 48),
            activityButton.heightAnchor.constraint(equalToConstant: 50),
            reportButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    @objc private func showShakeReporter(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        Self.logger.notice("Problem reporter invoked by simulated shake")
        Crumb.show(trigger: .shake)
    }

    private func simulateActivity() {
        guard !cpuPressureRunning else { return }
        Self.logger.warning("Demo CPU pressure started")
        cpuPressureRunning = true
        activityLabel.text = "CPU pressure active for 4 seconds"
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
            var accumulator = 0.0
            while DispatchTime.now().uptimeNanoseconds < deadline {
                accumulator += Double.random(in: 0...1).squareRoot()
            }
            _ = accumulator
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.cpuPressureRunning = false
            self?.activityLabel.text = "CPU pressure finished"
            Self.logger.notice("Demo CPU pressure finished")
        }
    }
}
