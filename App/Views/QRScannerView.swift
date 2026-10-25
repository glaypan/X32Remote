import SwiftUI
import AVFoundation

/// 扫码连接：直接用 AVFoundation 取景，不引第三方扫码库。
///
/// 三个容易踩的点：
///   1. `startRunning()` 会阻塞几百毫秒，必须丢到后台队列 —— 主线程调用会把
///      整个界面冻住，用户以为"扫不出来"其实界面根本没转起来。
///   2. 识别到就必须 **立刻停 session 且只回调一次**：同一张码每帧都会命中，
///      不停会连发十几次 connect()。
///   3. 相机权限被拒时不能只留一块黑屏 —— 明确告诉用户去哪儿开，并给按钮。
struct QRScannerView: UIViewControllerRepresentable {
    /// 扫到内容（原样字符串，交给 PairCode.parse 判定）
    var onCode: (String) -> Void
    /// 用户主动关闭 / 权限被拒后退出
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onCode: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var handled = false

    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let frameLayer = CAShapeLayer()
    private var deniedView: UIView?

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildChrome()
        requestCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard previewLayer != nil, !session.isRunning else { return }
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        layoutFrame()
    }

    // MARK: - 界面

    private func buildChrome() {
        titleLabel.text = "扫码连接"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        hintLabel.text = "对准电脑端「手机连接」里的二维码"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        frameLayer.strokeColor = UIColor.systemOrange.cgColor
        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.lineWidth = 3
        frameLayer.lineCap = .round
        view.layer.addSublayer(frameLayer)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            hintLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -26),
        ])
    }

    /// 取景框：四角 + 中间方框（比整块半透明遮罩轻，也不挡画面）
    private func layoutFrame() {
        let side = min(view.bounds.width, view.bounds.height) * 0.62
        let rect = CGRect(x: (view.bounds.width - side) / 2,
                          y: (view.bounds.height - side) / 2 - 20,
                          width: side, height: side)
        let path = UIBezierPath()
        let arm = side * 0.18
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + arm), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + arm, y: rect.minY)),
            (CGPoint(x: rect.maxX - arm, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + arm)),
            (CGPoint(x: rect.maxX, y: rect.maxY - arm), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - arm, y: rect.maxY)),
            (CGPoint(x: rect.minX + arm, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - arm)),
        ]
        for (a, b, c) in corners {
            path.move(to: a); path.addLine(to: b); path.addLine(to: c)
        }
        frameLayer.path = path.cgPath
        frameLayer.frame = view.bounds
    }

    // MARK: - 相机

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureSession() } else { self.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showDenied("找不到可用的摄像头")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        output.setMetadataObjectsDelegate(self, queue: .main)
        // 只认二维码：现场可能同时贴了条形码/二维码两张，别抓错
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        startSession()
    }

    private func startSession() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !handled,
              let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              code.type == .qr,
              let text = code.stringValue, !text.isEmpty else { return }
        handled = true
        stopSession()
        onCode?(text)
    }

    // MARK: - 权限被拒

    private func showDenied(_ detail: String? = nil) {
        guard deniedView == nil else { return }
        let box = UIView(frame: view.bounds)
        box.backgroundColor = UIColor(white: 0.07, alpha: 1)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let icon = UILabel()
        icon.text = "📷"
        icon.font = .systemFont(ofSize: 44)
        icon.textAlignment = .center

        let label = UILabel()
        label.text = detail ?? "没有相机权限，扫不了码"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 2

        let tip = UILabel()
        tip.text = "设置 → X32 Remote → 相机，打开后回来重试。\n也可以返回上一页手填 IP。"
        tip.textColor = UIColor.white.withAlphaComponent(0.66)
        tip.font = .systemFont(ofSize: 13)
        tip.textAlignment = .center
        tip.numberOfLines = 3

        let settings = UIButton(type: .system)
        settings.setTitle("去设置", for: .normal)
        settings.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        settings.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, tip, settings])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        view.addSubview(box)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -36),
        ])
        deniedView = box
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func closeTapped() {
        stopSession()
        onClose?()
    }
}
