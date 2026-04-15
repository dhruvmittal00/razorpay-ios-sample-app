//
//  ViewController.swift
//  DuitNow Pay A2A Test App
//
//  Custom Checkout flow — no WebView.
//  1. Pre-fetch session_token from devstack /v1/checkout/public
//  2. Create payment via /v1/payments/create/ajax with session token
//  3. Handle CIMB redirect URL → transform to app deep link
//  4. Handle callback → verify payment status via Razorpay API
//

import UIKit
import os.log

class ViewController: UIViewController, UITextFieldDelegate {

    // MARK: - Devstack Configuration

    let razorpayKey = "rzp_test_1NHe5VeS1wt4NO"
    let razorpaySecret = "MpFmQdSmSGmopJDP1iFsRXbr"
    let devstackBaseURL = "https://api-web-duitnowpay.ext.dev.razorpay.in"
    let forceTerminalId = "term_Q8aiqHEwFoCyHK"
    let bankCode = "CIMY"

    // MARK: - Blade Design Tokens

    struct Blade {
        static let surfaceBackground = UIColor(hex: "#F7F8F9")
        static let surfaceCard = UIColor.white
        static let borderSubtle = UIColor(hex: "#E4E7EB")
        static let borderNormal = UIColor(hex: "#CBD5E1")
        static let textPrimary = UIColor(hex: "#1B2533")
        static let textSecondary = UIColor(hex: "#5F6D7E")
        static let textSubdued = UIColor(hex: "#8B95A2")
        static let textLink = UIColor(hex: "#0D6FFF")
        static let actionPrimary = UIColor(hex: "#0D6FFF")
        static let actionPrimaryHover = UIColor(hex: "#0553CC")
        static let actionPrimaryDisabled = UIColor(hex: "#CBD5E1")
        static let feedbackSuccessText = UIColor(hex: "#1A7F37")
        static let feedbackSuccessBg = UIColor(hex: "#DAFBE8")
        static let feedbackErrorText = UIColor(hex: "#D1242F")
        static let feedbackErrorBg = UIColor(hex: "#FFEBE9")
        static let feedbackInfoBg = UIColor(hex: "#DDF4FF")
        static let feedbackInfoText = UIColor(hex: "#0550AE")
        static let cimbRed = UIColor(hex: "#EC1C24")
        static let cimbDark = UIColor(hex: "#8B0304")

        static let spacing2: CGFloat = 4
        static let spacing3: CGFloat = 8
        static let spacing4: CGFloat = 12
        static let spacing5: CGFloat = 16
        static let spacing6: CGFloat = 20
        static let spacing7: CGFloat = 24
        static let spacing8: CGFloat = 32

        static let radiusMedium: CGFloat = 8
        static let radiusLarge: CGFloat = 12

        static func heading(_ size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
            .systemFont(ofSize: size, weight: weight)
        }
        static func body(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            .systemFont(ofSize: size, weight: weight)
        }
    }

    // MARK: - Optimized Networking

    /// Dedicated URLSession with connection keep-alive and caching
    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 20 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Image cache — avoids re-downloading logos every launch
    private static let imageCache = NSCache<NSString, UIImage>()

    // MARK: - Pre-fetched State

    /// Pre-fetched session token (fetched on viewDidLoad, ready by tap time)
    private var cachedSessionToken: String?
    private var sessionTokenFetchTime: Date?
    private var isPreFetchingToken = false
    private let tokenMaxAge: TimeInterval = 300 // 5 min validity

    /// Last payment ID for verification after callback
    private var lastPaymentId: String?

    // MARK: - UI Elements

    var scrollView: UIScrollView!
    var contentStack: UIStackView!
    var amountField: UITextField!
    var cimbButton: UIView!
    var cimbLogoImageView: UIImageView!
    var rzpLogoImageView: UIImageView!
    var statusCard: UIView!
    var statusIndicator: UIView!
    var statusTitle: UILabel!
    var statusMessage: UILabel!
    var statusLogLabel: UILabel!
    var activityIndicator: UIActivityIndicatorView!
    var resultCard: UIView!
    var resultStack: UIStackView!
    var lastResponseHeaders: [String: String]?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Blade.surfaceBackground
        setupUI()
        setupKeyboardDismissal()
        registerForDeepLinks()
        preFetchSessionToken()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    // MARK: - UI Setup

    func setupUI() {
        scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = Blade.spacing5
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Blade.spacing5),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Blade.spacing5),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Blade.spacing5),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -Blade.spacing8),
        ])

        contentStack.addArrangedSubview(buildHeaderCard())
        contentStack.addArrangedSubview(buildAmountCard())
        contentStack.addArrangedSubview(buildPaymentMethodCard())

        statusCard = buildStatusCard()
        statusCard.isHidden = true
        contentStack.addArrangedSubview(statusCard)

        resultCard = buildResultCard()
        resultCard.isHidden = true
        contentStack.addArrangedSubview(resultCard)

        contentStack.addArrangedSubview(buildEnvInfoCard())
    }

    // MARK: - Card Builders

    func buildHeaderCard() -> UIView {
        let card = makeCard()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Blade.spacing2
        stack.alignment = .center
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(stack, card: card)

        rzpLogoImageView = UIImageView()
        rzpLogoImageView.contentMode = .scaleAspectFit
        rzpLogoImageView.translatesAutoresizingMaskIntoConstraints = false
        rzpLogoImageView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        rzpLogoImageView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        stack.addArrangedSubview(rzpLogoImageView)
        loadCachedImage(from: "https://rzp-1415-prod-dashboard-activation.s3.ap-south-1.amazonaws.com/org_KjWRtYXwpK6VfK/payment_apps_logo/phplelIPA", into: rzpLogoImageView)

        let titleLabel = UILabel()
        titleLabel.text = "DuitNow Pay"
        titleLabel.font = Blade.heading(28)
        titleLabel.textColor = Blade.textPrimary
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "App-to-App Payment Test"
        subtitleLabel.font = Blade.body(15)
        subtitleLabel.textColor = Blade.textSecondary
        stack.addArrangedSubview(subtitleLabel)

        stack.setCustomSpacing(Blade.spacing3, after: rzpLogoImageView)
        return card
    }

    func buildAmountCard() -> UIView {
        let card = makeCard()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Blade.spacing3
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(stack, card: card)

        let label = UILabel()
        label.text = "Payment Amount"
        label.font = Blade.body(13, weight: .semibold)
        label.textColor = Blade.textSecondary
        stack.addArrangedSubview(label)

        amountField = UITextField()
        amountField.placeholder = "1.00"
        amountField.text = "1.00"
        amountField.font = Blade.heading(20, weight: .semibold)
        amountField.textColor = Blade.textPrimary
        amountField.keyboardType = .decimalPad
        amountField.borderStyle = .none
        amountField.delegate = self
        amountField.backgroundColor = Blade.surfaceBackground
        amountField.layer.cornerRadius = Blade.radiusMedium
        amountField.layer.borderWidth = 1
        amountField.layer.borderColor = Blade.borderSubtle.cgColor
        amountField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 0))
        amountField.leftViewMode = .always

        let myrContainer = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 48))
        let myrLabel = UILabel()
        myrLabel.text = "MYR"
        myrLabel.font = Blade.body(14, weight: .medium)
        myrLabel.textColor = Blade.textSubdued
        myrLabel.sizeToFit()
        myrLabel.center = CGPoint(x: myrContainer.bounds.width / 2 - 2, y: myrContainer.bounds.height / 2)
        myrContainer.addSubview(myrLabel)
        amountField.rightView = myrContainer
        amountField.rightViewMode = .always

        amountField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        stack.addArrangedSubview(amountField)

        let helperLabel = UILabel()
        helperLabel.text = "Minimum: MYR 0.10 (10 cents)"
        helperLabel.font = Blade.body(12)
        helperLabel.textColor = Blade.textSubdued
        stack.addArrangedSubview(helperLabel)

        return card
    }

    func buildPaymentMethodCard() -> UIView {
        let card = makeCard()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Blade.spacing4
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(stack, card: card)

        let sectionLabel = UILabel()
        sectionLabel.text = "Pay Using"
        sectionLabel.font = Blade.body(13, weight: .semibold)
        sectionLabel.textColor = Blade.textSecondary
        stack.addArrangedSubview(sectionLabel)

        cimbButton = buildCIMBButton()
        stack.addArrangedSubview(cimbButton)
        return card
    }

    func buildCIMBButton() -> UIView {
        let container = UIView()
        container.backgroundColor = .white
        container.layer.cornerRadius = Blade.radiusMedium
        container.layer.borderWidth = 1.5
        container.layer.borderColor = Blade.borderSubtle.cgColor

        let hStack = UIStackView()
        hStack.axis = .horizontal
        hStack.spacing = Blade.spacing4
        hStack.alignment = .center
        container.addSubview(hStack)
        hStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Blade.spacing4),
            hStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Blade.spacing4),
            hStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Blade.spacing5),
            hStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Blade.spacing5),
        ])

        cimbLogoImageView = UIImageView()
        cimbLogoImageView.contentMode = .scaleAspectFit
        cimbLogoImageView.layer.cornerRadius = 6
        cimbLogoImageView.clipsToBounds = true
        cimbLogoImageView.backgroundColor = UIColor(hex: "#F5F5F5")
        cimbLogoImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cimbLogoImageView.widthAnchor.constraint(equalToConstant: 40),
            cimbLogoImageView.heightAnchor.constraint(equalToConstant: 40),
        ])
        loadCachedImage(from: "https://cdn.razorpay.com/bank/CIBB.gif", into: cimbLogoImageView)

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2

        let bankName = UILabel()
        bankName.text = "CIMB Bank"
        bankName.font = Blade.body(16, weight: .semibold)
        bankName.textColor = Blade.textPrimary
        textStack.addArrangedSubview(bankName)

        let methodLabel = UILabel()
        methodLabel.text = "DuitNow Pay  \u{2022}  App-to-App"
        methodLabel.font = Blade.body(13)
        methodLabel.textColor = Blade.textSecondary
        textStack.addArrangedSubview(methodLabel)

        let chevron = UILabel()
        chevron.text = "\u{203A}"
        chevron.font = Blade.heading(24, weight: .medium)
        chevron.textColor = Blade.textSubdued

        activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = Blade.actionPrimary

        hStack.addArrangedSubview(cimbLogoImageView)
        hStack.addArrangedSubview(textStack)
        hStack.addArrangedSubview(UIView()) // spacer
        hStack.addArrangedSubview(activityIndicator)
        hStack.addArrangedSubview(chevron)

        let tapButton = UIButton(type: .custom)
        tapButton.backgroundColor = .clear
        tapButton.addTarget(self, action: #selector(cimbButtonTapped), for: .touchUpInside)
        tapButton.addTarget(self, action: #selector(cimbButtonTouchDown), for: .touchDown)
        tapButton.addTarget(self, action: #selector(cimbButtonTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        container.addSubview(tapButton)
        tapButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tapButton.topAnchor.constraint(equalTo: container.topAnchor),
            tapButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tapButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    func buildStatusCard() -> UIView {
        let card = makeCard()
        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = Blade.spacing3
        card.addSubview(outerStack)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(outerStack, card: card)

        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.spacing = Blade.spacing3
        titleRow.alignment = .center

        statusIndicator = UIView()
        statusIndicator.layer.cornerRadius = 4
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIndicator.widthAnchor.constraint(equalToConstant: 8),
            statusIndicator.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusTitle = UILabel()
        statusTitle.font = Blade.body(14, weight: .semibold)
        statusTitle.textColor = Blade.textPrimary

        titleRow.addArrangedSubview(statusIndicator)
        titleRow.addArrangedSubview(statusTitle)
        outerStack.addArrangedSubview(titleRow)

        statusMessage = UILabel()
        statusMessage.font = Blade.body(13)
        statusMessage.textColor = Blade.textSecondary
        statusMessage.numberOfLines = 0
        outerStack.addArrangedSubview(statusMessage)

        statusLogLabel = UILabel()
        statusLogLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLogLabel.textColor = Blade.textSubdued
        statusLogLabel.numberOfLines = 0
        statusLogLabel.isHidden = true
        outerStack.addArrangedSubview(statusLogLabel)

        return card
    }

    func buildResultCard() -> UIView {
        let card = makeCard()
        resultStack = UIStackView()
        resultStack.axis = .vertical
        resultStack.spacing = Blade.spacing3
        card.addSubview(resultStack)
        resultStack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(resultStack, card: card)
        return card
    }

    func buildEnvInfoCard() -> UIView {
        let card = makeCard()
        card.backgroundColor = Blade.surfaceBackground
        card.layer.borderColor = Blade.borderSubtle.cgColor
        card.layer.borderWidth = 1

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Blade.spacing2
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pinToCard(stack, card: card)

        let envTitle = UILabel()
        envTitle.text = "Environment"
        envTitle.font = Blade.body(11, weight: .semibold)
        envTitle.textColor = Blade.textSubdued
        stack.addArrangedSubview(envTitle)

        for (label, value) in [
            ("Server", "Devstack (UAT)"),
            ("Key", razorpayKey),
            ("Terminal", forceTerminalId),
            ("Bank Code", bankCode),
        ] {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fill

            let keyLabel = UILabel()
            keyLabel.text = label
            keyLabel.font = Blade.body(12)
            keyLabel.textColor = Blade.textSubdued
            keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let valueLabel = UILabel()
            valueLabel.text = value
            valueLabel.font = Blade.body(12, weight: .medium)
            valueLabel.textColor = Blade.textSecondary
            valueLabel.textAlignment = .right
            valueLabel.lineBreakMode = .byTruncatingMiddle

            row.addArrangedSubview(keyLabel)
            row.addArrangedSubview(valueLabel)
            stack.addArrangedSubview(row)
        }

        return card
    }

    // MARK: - Card Helpers

    func makeCard() -> UIView {
        let card = UIView()
        card.backgroundColor = Blade.surfaceCard
        card.layer.cornerRadius = Blade.radiusLarge
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.04
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowRadius = 8
        // Rasterize shadow for scroll performance
        card.layer.shouldRasterize = true
        card.layer.rasterizationScale = UIScreen.main.scale
        return card
    }

    func pinToCard(_ subview: UIView, card: UIView, inset: CGFloat = 16) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            subview.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            subview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            subview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
    }

    // MARK: - Button Interactions

    @objc func cimbButtonTapped() {
        amountField.resignFirstResponder()
        startPayment()
    }

    @objc func cimbButtonTouchDown() {
        UIView.animate(withDuration: 0.1) {
            self.cimbButton.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
            self.cimbButton.layer.borderColor = Blade.actionPrimary.cgColor
            self.cimbButton.backgroundColor = Blade.surfaceBackground
        }
    }

    @objc func cimbButtonTouchUp() {
        UIView.animate(withDuration: 0.15) {
            self.cimbButton.transform = .identity
            self.cimbButton.layer.borderColor = Blade.borderSubtle.cgColor
            self.cimbButton.backgroundColor = .white
        }
    }

    // MARK: - Pre-fetch Session Token

    /// Called on viewDidLoad — fetches session token in background so it's ready when user taps pay.
    /// Token is valid for ~5 minutes. Silently re-fetches if expired.
    func preFetchSessionToken() {
        guard !isPreFetchingToken else { return }
        isPreFetchingToken = true
        os_log(">>> Pre-fetching session token...")

        // Use default amount for pre-fetch (will be overridden if amount changes)
        getSessionToken(amount: 100) { [weak self] result in
            self?.isPreFetchingToken = false
            switch result {
            case .success(let token):
                self?.cachedSessionToken = token
                self?.sessionTokenFetchTime = Date()
                os_log(">>> Session token pre-fetched and cached")
            case .failure(let error):
                os_log(">>> Pre-fetch failed (will retry on tap): %{public}@", error.localizedDescription)
            }
        }
    }

    /// Returns cached token if still valid, otherwise fetches fresh
    func getValidSessionToken(amount: Int, completion: @escaping (Result<String, Error>) -> Void) {
        if let token = cachedSessionToken,
           let fetchTime = sessionTokenFetchTime,
           Date().timeIntervalSince(fetchTime) < tokenMaxAge {
            os_log(">>> Using cached session token (age: %.0fs)", Date().timeIntervalSince(fetchTime))
            completion(.success(token))
            return
        }

        // Token expired or not available — fetch fresh
        os_log(">>> Cached token expired/missing, fetching fresh...")
        getSessionToken(amount: amount, completion: completion)
    }

    // MARK: - Payment Flow

    func startPayment() {
        guard let amountText = amountField.text, let amountDouble = Double(amountText) else {
            showStatus(.error, title: "Invalid Amount", message: "Please enter a valid amount.")
            return
        }

        let amountInCents = Int(amountDouble * 100)
        guard amountInCents >= 10 else {
            showStatus(.error, title: "Amount Too Low", message: "Minimum amount is MYR 0.10")
            return
        }

        setLoading(true)
        showStatus(.info, title: "Initializing", message: "Getting checkout session...")

        // Use cached token if available (saves ~500ms-1s)
        getValidSessionToken(amount: amountInCents) { [weak self] result in
            switch result {
            case .success(let token):
                self?.showStatus(.info, title: "Creating Payment", message: "Sending DuitNow Pay request...")
                self?.createPayment(sessionToken: token, amount: amountInCents)
            case .failure(let error):
                self?.setLoading(false)
                self?.showStatus(.error, title: "Session Failed", message: error.localizedDescription)
            }
        }
    }

    /// Step 1: Get session_token from /v1/checkout/public
    func getSessionToken(amount: Int, completion: @escaping (Result<String, Error>) -> Void) {
        var components = URLComponents(string: "\(devstackBaseURL)/v1/checkout/public")!
        components.queryItems = [
            URLQueryItem(name: "key_id", value: razorpayKey),
            URLQueryItem(name: "amount", value: "\(amount)"),
            URLQueryItem(name: "currency", value: "MYR"),
        ]

        guard let url = components.url else {
            completion(.failure(PaymentError.invalidURL))
            return
        }

        os_log(">>> Fetching session token from: %{public}@", url.absoluteString)

        apiSession.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    completion(.failure(PaymentError.noData))
                    return
                }
                if let range = html.range(of: "session_token=\""),
                   let endRange = html[range.upperBound...].range(of: "\"") {
                    let token = String(html[range.upperBound..<endRange.lowerBound])
                    os_log(">>> Got session token: %{public}@...", String(token.prefix(20)))
                    completion(.success(token))
                } else {
                    completion(.failure(PaymentError.noSessionToken))
                }
            }
        }.resume()
    }

    /// Step 2: Create payment via /v1/payments/create/ajax
    func createPayment(sessionToken: String, amount: Int) {
        guard let url = URL(string: "\(devstackBaseURL)/v1/payments/create/ajax") else {
            setLoading(false)
            showStatus(.error, title: "Error", message: "Invalid payment URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken, forHTTPHeaderField: "X-Razorpay-SessionToken")
        request.cachePolicy = .reloadIgnoringLocalCacheData // Never cache payment creation

        let params: [(String, String)] = [
            ("key_id", razorpayKey),
            ("amount", "\(amount)"),
            ("currency", "MYR"),
            ("method", "duitnow_pay"),
            ("bank", bankCode),
            ("force_terminal_id", forceTerminalId),
            ("email", "test@curlec.com"),
            ("contact", "+60123456789"),
            ("_[library]", "custom"),
            ("_[platform]", "mobile"),
        ]

        let body = params.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
        }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        os_log(">>> Creating payment: amount=%d, bank=%{public}@", amount, bankCode)

        apiSession.dataTask(with: request) { [weak self] data, response, error in
            var headerLog: [String: String] = [:]
            if let httpResponse = response as? HTTPURLResponse {
                headerLog["Status"] = "\(httpResponse.statusCode)"
                for (key, value) in httpResponse.allHeaderFields {
                    headerLog["\(key)"] = "\(value)"
                }
            }
            DispatchQueue.main.async {
                self?.lastResponseHeaders = headerLog
                self?.setLoading(false)

                if let error = error {
                    self?.showStatus(.error, title: "Network Error", message: error.localizedDescription)
                    return
                }
                guard let data = data else {
                    self?.showStatus(.error, title: "Error", message: "No response data")
                    return
                }
                self?.handlePaymentResponse(data)

                // Invalidate cached token so next payment gets a fresh one
                self?.cachedSessionToken = nil
            }
        }.resume()
    }

    // MARK: - Payment Response Handling

    func buildHeaderLog() -> String {
        guard let headers = lastResponseHeaders else { return "" }
        var lines: [String] = []
        if let status = headers["Status"] { lines.append("HTTP \(status)") }
        for key in ["X-Razorpay-Request-Id", "X-Request-Id", "Content-Type", "Date", "X-Razorpay-Mode"] {
            if let val = headers[key] { lines.append("\(key): \(val)") }
        }
        return lines.joined(separator: "\n")
    }

    func handlePaymentResponse(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                showStatus(.error, title: "Parse Error", message: "Invalid JSON response")
                return
            }

            os_log(">>> Payment response: %{public}@", String(data: data, encoding: .utf8) ?? "nil")
            let headerLog = buildHeaderLog()

            if let error = json["error"] as? [String: Any] {
                let desc = error["description"] as? String ?? "Unknown error"
                let code = error["code"] as? String ?? ""
                let paymentId = (error["metadata"] as? [String: Any])?["payment_id"] as? String
                lastPaymentId = paymentId

                var message = desc
                if let pid = paymentId { message += "\n\nPayment ID: \(pid)" }

                showStatus(.error, title: "Payment Error (\(code))", message: message, logText: headerLog)
                showResultDetails(json, isError: true)
                return
            }

            let paymentId = json["payment_id"] as? String ?? json["razorpay_payment_id"] as? String ?? "N/A"
            lastPaymentId = paymentId

            if let requestInfo = json["request"] as? [String: Any],
               let redirectUrl = requestInfo["url"] as? String {
                showStatus(.success, title: "Payment Created!", message: "Payment ID: \(paymentId)\nRedirecting to CIMB...", logText: headerLog)
                showResultDetails(json, isError: false)
                handleCIMBRedirect(redirectUrl, paymentId: paymentId)
            } else {
                showStatus(.success, title: "Payment Created", message: "Payment ID: \(paymentId)\n\nNo redirect URL — payment may have been processed directly.", logText: headerLog)
                showResultDetails(json, isError: false)
            }
        } catch {
            showStatus(.error, title: "Parse Error", message: error.localizedDescription)
        }
    }

    // MARK: - Payment Status Verification (Razorpay API)

    /// After CIMB callback, verify the payment status on Razorpay's side.
    /// GET /v1/payments/{payment_id} with Basic auth (key:secret)
    func verifyPaymentStatus(_ paymentId: String) {
        guard let url = URL(string: "\(devstackBaseURL)/v1/payments/\(paymentId)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Basic auth: key_id:key_secret
        let credentials = "\(razorpayKey):\(razorpaySecret)"
        if let credentialData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credentialData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        os_log(">>> Verifying payment status: %{public}@", paymentId)

        apiSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    os_log(">>> Payment verification failed: %{public}@", error?.localizedDescription ?? "no data")
                    return
                }

                let status = json["status"] as? String ?? "unknown"
                let amount = json["amount"] as? Int
                let method = json["method"] as? String
                let rzpPaymentId = json["id"] as? String ?? paymentId

                os_log(">>> Razorpay payment status: %{public}@ for %{public}@", status, rzpPaymentId)

                // Update the result card with verified status
                self?.appendVerificationResult(
                    paymentId: rzpPaymentId,
                    status: status,
                    amount: amount,
                    method: method
                )
            }
        }.resume()
    }

    /// Append Razorpay verification result below the existing callback details
    func appendVerificationResult(paymentId: String, status: String, amount: Int?, method: String?) {
        guard resultStack != nil else { return }

        // Divider
        let divider = UIView()
        divider.backgroundColor = Blade.borderSubtle
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        resultStack.addArrangedSubview(divider)

        let headerLabel = UILabel()
        headerLabel.text = "Razorpay Verification"
        headerLabel.font = Blade.body(13, weight: .semibold)
        headerLabel.textColor = Blade.textSecondary
        resultStack.addArrangedSubview(headerLabel)

        let statusColor: UIColor
        let statusText: String
        switch status {
        case "authorized": statusColor = Blade.feedbackSuccessText; statusText = "Authorized"
        case "captured": statusColor = Blade.feedbackSuccessText; statusText = "Captured"
        case "created": statusColor = Blade.feedbackInfoText; statusText = "Created (pending)"
        case "failed": statusColor = Blade.feedbackErrorText; statusText = "Failed"
        default: statusColor = Blade.textSubdued; statusText = status
        }

        var rows: [(String, String, UIColor?)] = [
            ("Payment ID", paymentId, nil),
            ("Status", statusText, statusColor),
        ]
        if let amount = amount {
            rows.append(("Amount", String(format: "MYR %.2f", Double(amount) / 100.0), nil))
        }
        if let method = method {
            rows.append(("Method", method, nil))
        }

        for (key, value, color) in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fill
            row.spacing = 8

            let keyLabel = UILabel()
            keyLabel.text = key
            keyLabel.font = Blade.body(12, weight: .medium)
            keyLabel.textColor = Blade.textSubdued
            keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            keyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            let valueLabel = UILabel()
            valueLabel.text = value
            valueLabel.font = Blade.body(12, weight: color != nil ? .bold : .regular)
            valueLabel.textColor = color ?? Blade.textPrimary
            valueLabel.textAlignment = .right
            valueLabel.numberOfLines = 0

            row.addArrangedSubview(keyLabel)
            row.addArrangedSubview(valueLabel)
            resultStack.addArrangedSubview(row)
        }

        // Scroll to show verification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.scrollView.scrollRectToVisible(self.resultCard.frame, animated: true)
        }
    }

    // MARK: - Status Display

    enum StatusType { case info, success, error }

    func showStatus(_ type: StatusType, title: String, message: String, logText: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.statusCard.isHidden = false

            switch type {
            case .info:
                self.statusCard.backgroundColor = Blade.feedbackInfoBg
                self.statusIndicator.backgroundColor = Blade.feedbackInfoText
                self.statusTitle.textColor = Blade.feedbackInfoText
                self.statusMessage.textColor = Blade.feedbackInfoText
            case .success:
                self.statusCard.backgroundColor = Blade.feedbackSuccessBg
                self.statusIndicator.backgroundColor = Blade.feedbackSuccessText
                self.statusTitle.textColor = Blade.feedbackSuccessText
                self.statusMessage.textColor = Blade.feedbackSuccessText
            case .error:
                self.statusCard.backgroundColor = Blade.feedbackErrorBg
                self.statusIndicator.backgroundColor = Blade.feedbackErrorText
                self.statusTitle.textColor = Blade.feedbackErrorText
                self.statusMessage.textColor = Blade.feedbackErrorText
            }

            self.statusTitle.text = title
            self.statusMessage.text = message

            if let logText = logText, !logText.isEmpty {
                self.statusLogLabel.text = logText
                self.statusLogLabel.isHidden = false
            } else {
                self.statusLogLabel.isHidden = true
            }

            UIView.animate(withDuration: 0.2) {
                self.statusCard.alpha = 1
                self.view.layoutIfNeeded()
            }
        }
    }

    func showResultDetails(_ json: [String: Any], isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.resultStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            let headerLabel = UILabel()
            headerLabel.text = "Response Details"
            headerLabel.font = Blade.body(13, weight: .semibold)
            headerLabel.textColor = Blade.textSecondary
            self.resultStack.addArrangedSubview(headerLabel)

            func addRow(_ key: String, _ value: String) {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .fill
                row.spacing = 8

                let keyLabel = UILabel()
                keyLabel.text = key
                keyLabel.font = Blade.body(12, weight: .medium)
                keyLabel.textColor = Blade.textSubdued
                keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                keyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

                let valueLabel = UILabel()
                valueLabel.text = value
                valueLabel.font = Blade.body(12)
                valueLabel.textColor = Blade.textPrimary
                valueLabel.textAlignment = .right
                valueLabel.numberOfLines = 0
                valueLabel.lineBreakMode = .byCharWrapping

                row.addArrangedSubview(keyLabel)
                row.addArrangedSubview(valueLabel)
                self.resultStack.addArrangedSubview(row)
            }

            if let paymentId = json["payment_id"] as? String {
                addRow("Payment ID", paymentId)
            } else if let metadata = (json["error"] as? [String: Any])?["metadata"] as? [String: Any],
                      let paymentId = metadata["payment_id"] as? String {
                addRow("Payment ID", paymentId)
            }
            if let amount = json["amount"] as? String { addRow("Amount", amount) }
            if let error = json["error"] as? [String: Any] {
                if let code = error["code"] as? String { addRow("Error Code", code) }
                if let desc = error["description"] as? String { addRow("Description", desc) }
                if let source = error["source"] as? String { addRow("Source", source) }
                if let step = error["step"] as? String { addRow("Step", step) }
                if let reason = error["reason"] as? String { addRow("Reason", reason) }
            }
            if let request = json["request"] as? [String: Any] {
                if let method = request["method"] as? String { addRow("Method", method) }
                if let url = request["url"] as? String {
                    addRow("Redirect URL", String(url.prefix(80)) + "...")
                }
            }

            self.resultCard.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.resultCard.alpha = 1
                self.view.layoutIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.scrollView.scrollRectToVisible(self.resultCard.frame, animated: true)
            }
        }
    }

    func setLoading(_ loading: Bool) {
        DispatchQueue.main.async { [weak self] in
            if loading {
                self?.activityIndicator.startAnimating()
                self?.cimbButton.isUserInteractionEnabled = false
                self?.cimbButton.alpha = 0.7
            } else {
                self?.activityIndicator.stopAnimating()
                self?.cimbButton.isUserInteractionEnabled = true
                self?.cimbButton.alpha = 1.0
            }
        }
    }

    // MARK: - CIMB Deep Link Handling

    func handleCIMBRedirect(_ webUrl: String, paymentId: String) {
        let appDeepLink = transformToAppDeepLink(webUrl)
        os_log(">>> A2A Deep Link: %{public}@", appDeepLink)

        guard let url = URL(string: appDeepLink) else {
            showStatus(.error, title: "Deep Link Error", message: "Invalid deep link URL: \(appDeepLink)")
            return
        }

        if UIApplication.shared.canOpenURL(url) {
            showStatus(.success, title: "Opening CIMB App", message: "Payment ID: \(paymentId)\nRedirecting to CIMB UAT app...")
            UIApplication.shared.open(url) { [weak self] success in
                if !success {
                    self?.showStatus(.error, title: "Failed to Open", message: "Could not open CIMB app.\nDeep link: \(appDeepLink)")
                }
            }
        } else {
            showStatus(.info, title: "CIMB App Not Installed", message: "The CIMB UAT app (novuscimboctouat://) is not installed.\n\nPayment ID: \(paymentId)\n\nDeep link:\n\(appDeepLink)")
        }
    }

    /// Transform CIMB web URL → app deep link
    /// Per Paynet A2A Framework Section 4.2:
    /// Replace https://uat3.cimbclicks.com.my/dobb2c/ → novuscimboctouat://
    func transformToAppDeepLink(_ webUrl: String) -> String {
        var appUrl = webUrl.replacingOccurrences(
            of: "https://uat3.cimbclicks.com.my/dobb2c/",
            with: "novuscimboctouat://"
        )
        if !appUrl.contains("Callback=") {
            let separator = appUrl.contains("?") ? "&" : "?"
            let callback = "rzpcurlectestapp://payment/callback"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "rzpcurlectestapp%3A%2F%2Fpayment%2Fcallback"
            appUrl += "\(separator)Callback=\(callback)"
        }
        return appUrl
    }

    // MARK: - Deep Link Callback (from CIMB app via SceneDelegate)

    static let deepLinkNotification = Notification.Name("DuitNowDeepLinkCallback")

    func registerForDeepLinks() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveDeepLink(_:)),
            name: ViewController.deepLinkNotification,
            object: nil
        )
    }

    @objc func didReceiveDeepLink(_ notification: Notification) {
        if let url = notification.userInfo?["url"] as? URL {
            handleDeepLinkCallback(url: url)
        }
    }

    func handleDeepLinkCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else { return }

        let status = queryItems.first(where: { $0.name == "Sts" })?.value
        let endToEndId = queryItems.first(where: { $0.name == "EndtoEndId" })?.value ?? "N/A"
        let dbtrAgt = queryItems.first(where: { $0.name == "DbtrAgt" })?.value ?? "N/A"

        os_log(">>> Callback: Sts=%{public}@, EndtoEndId=%{public}@, DbtrAgt=%{public}@", status ?? "nil", endToEndId, dbtrAgt)

        let callbackLog = "Callback URL: \(url.absoluteString)\nSts: \(status ?? "nil")\nEndtoEndId: \(endToEndId)\nDbtrAgt: \(dbtrAgt)"

        switch status {
        case "00":
            showStatus(.success, title: "Payment Processed",
                        message: "Transaction has been processed.\n\nEndtoEndId: \(endToEndId)\nBank: \(dbtrAgt)\n\nVerifying with Razorpay...",
                        logText: callbackLog)
            showCallbackResult(status: "00", endToEndId: endToEndId, dbtrAgt: dbtrAgt, url: url)
            // Verify Razorpay-side payment status
            if let pid = lastPaymentId { verifyPaymentStatus(pid) }
        case "97":
            showStatus(.error, title: "Bank App Unavailable",
                        message: "CIMB app could not process this transaction.\nRetrying via web channel is recommended.",
                        logText: callbackLog)
            showCallbackResult(status: "97", endToEndId: endToEndId, dbtrAgt: dbtrAgt, url: url)
        case "98":
            showStatus(.error, title: "PayNet Error",
                        message: "Transaction failed at PayNet level.\nPlease try another payment method.",
                        logText: callbackLog)
            showCallbackResult(status: "98", endToEndId: endToEndId, dbtrAgt: dbtrAgt, url: url)
        case "99":
            showStatus(.error, title: "Issuer Error",
                        message: "Transaction failed at CIMB (issuer) level.\nPlease try another bank.",
                        logText: callbackLog)
            showCallbackResult(status: "99", endToEndId: endToEndId, dbtrAgt: dbtrAgt, url: url)
        default:
            showStatus(.info, title: "Callback Received",
                        message: "Status: \(status ?? "nil")\nEndtoEndId: \(endToEndId)",
                        logText: callbackLog)
            showCallbackResult(status: status ?? "unknown", endToEndId: endToEndId, dbtrAgt: dbtrAgt, url: url)
        }

        // Pre-fetch a new session token for next payment
        preFetchSessionToken()
    }

    func showCallbackResult(status: String, endToEndId: String, dbtrAgt: String, url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.resultStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            let headerLabel = UILabel()
            headerLabel.text = "Callback Details"
            headerLabel.font = Blade.body(13, weight: .semibold)
            headerLabel.textColor = Blade.textSecondary
            self.resultStack.addArrangedSubview(headerLabel)

            let statusDesc: String
            switch status {
            case "00": statusDesc = "Processed"
            case "97": statusDesc = "App Unavailable"
            case "98": statusDesc = "PayNet Error"
            case "99": statusDesc = "Issuer Error"
            default: statusDesc = "Unknown"
            }

            for (key, value) in [
                ("Status Code", status),
                ("Status", statusDesc),
                ("EndtoEndId", endToEndId),
                ("Debtor Agent", dbtrAgt),
                ("Callback URL", url.absoluteString),
            ] {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .fill
                row.spacing = 8

                let keyLabel = UILabel()
                keyLabel.text = key
                keyLabel.font = Blade.body(12, weight: .medium)
                keyLabel.textColor = Blade.textSubdued
                keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                keyLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

                let valueLabel = UILabel()
                valueLabel.text = value
                valueLabel.font = Blade.body(12)
                valueLabel.textColor = Blade.textPrimary
                valueLabel.textAlignment = .right
                valueLabel.numberOfLines = 0
                valueLabel.lineBreakMode = .byCharWrapping

                row.addArrangedSubview(keyLabel)
                row.addArrangedSubview(valueLabel)
                self.resultStack.addArrangedSubview(row)
            }

            self.resultCard.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.resultCard.alpha = 1
                self.view.layoutIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.scrollView.scrollRectToVisible(self.resultCard.frame, animated: true)
            }
        }
    }

    // MARK: - Keyboard

    func setupKeyboardDismissal() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - Image Loading (with NSCache)

    func loadCachedImage(from urlString: String, into imageView: UIImageView) {
        let cacheKey = urlString as NSString

        // Check memory cache first
        if let cached = ViewController.imageCache.object(forKey: cacheKey) {
            imageView.image = cached
            return
        }

        guard let url = URL(string: urlString) else { return }

        apiSession.dataTask(with: url) { data, _, _ in
            if let data = data, let image = UIImage(data: data) {
                ViewController.imageCache.setObject(image, forKey: cacheKey)
                DispatchQueue.main.async {
                    UIView.transition(with: imageView, duration: 0.15, options: .transitionCrossDissolve) {
                        imageView.image = image
                    }
                }
            }
        }.resume()
    }

    // MARK: - Errors

    enum PaymentError: LocalizedError {
        case invalidURL, noData, noSessionToken

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL configuration"
            case .noData: return "No data received from server"
            case .noSessionToken: return "Could not extract session token from checkout page"
            }
        }
    }
}

// MARK: - UIColor hex extension

extension UIColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
