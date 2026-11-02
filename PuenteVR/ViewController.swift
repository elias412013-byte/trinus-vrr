import UIKit
import CoreMotion
import simd

class ViewController: UIViewController, UITextFieldDelegate {

    private enum Mode: Int { case game = 0, cinema = 1 }

    // Red
    private let client = MJPEGClient()
    private let udp = UDPSender()
    private let beacon = BeaconListener()
    private let videoPort = 8081
    private let headPort: UInt16 = 5006

    // Estado
    private var mode: Mode = .game
    private var sbs = false
    private var sens: Float = 1.0
    private var zoom: CGFloat = 1.0
    private var sep: CGFloat = 0
    private var vrActive = false
    private var headControl = true
    private var needsRef = true
    private var yawRef: Float = 0
    private var pitchRef: Float = 0
    private var curYaw: Float = 0
    private var curPitch: Float = 0
    private var gotFrame = false
    private var fpsCount = 0
    private var fps = 0
    private var fpsTimer: Timer?
    private var hintToken = 0
    private var autoFilledIP = ""

    // Movimiento de la cabeza
    private let motion = CMMotionManager()

    // Pantalla de ajustes
    private let scroll = UIScrollView()
    private let statusLabel = UILabel()
    private let ipField = UITextField()
    private let modeControl = UISegmentedControl(items: ["Juego (cabeza = mouse)", "Cine (pantalla fija)"])
    private let sbsSwitch = UISwitch()
    private let sensSlider = UISlider()
    private let zoomSlider = UISlider()
    private let sepSlider = UISlider()
    private let sensValue = UILabel()
    private let zoomValue = UILabel()
    private let sepValue = UILabel()
    private let startButton = UIButton(type: .system)

    // Vista VR (pantalla dividida)
    private let vrView = UIView()
    private let leftHolder = CALayer()
    private let rightHolder = CALayer()
    private let leftImg = CALayer()
    private let rightImg = CALayer()
    private let leftHint = CATextLayer()
    private let rightHint = CATextLayer()

    override var prefersStatusBarHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    override var shouldAutorotate: Bool { return true }

    // MARK: Inicio
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        buildSetupUI()
        buildVRView()
        loadPrefs()
        sliderChanged()

        client.onFrame = { [weak self] cg in self?.showFrame(cg) }
        client.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.showHint(text, 3) }
        }
        beacon.onFound = { [weak self] ip in self?.foundPC(ip) }
        beacon.start()
    }

    // MARK: Pantalla de ajustes
    private func makeRow(_ title: String, _ control: UIView, _ value: UILabel?) -> UIStackView {
        let l = UILabel()
        l.text = title
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 15)
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        var views: [UIView] = [l, control]
        if let v = value {
            v.textColor = .lightGray
            v.font = UIFont.systemFont(ofSize: 14)
            v.textAlignment = .right
            v.widthAnchor.constraint(equalToConstant: 56).isActive = true
            views.append(v)
        }
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }

    private func buildSetupUI() {
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scroll)

        let title = UILabel()
        title.text = "PuenteVR"
        title.font = UIFont.boldSystemFont(ofSize: 28)
        title.textColor = .white

        statusLabel.text = "Buscando la PC… (abrí puente_vr.py en la PC)"
        statusLabel.textColor = .lightGray
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.numberOfLines = 0

        ipField.placeholder = "IP de la PC (ej. 192.168.1.20)"
        ipField.borderStyle = .roundedRect
        ipField.keyboardType = .numbersAndPunctuation
        ipField.returnKeyType = .done
        ipField.autocorrectionType = .no
        ipField.autocapitalizationType = .none
        ipField.delegate = self

        modeControl.selectedSegmentIndex = 0

        sensSlider.minimumValue = 0.3
        sensSlider.maximumValue = 3.0
        sensSlider.value = 1.0
        zoomSlider.minimumValue = 0.5
        zoomSlider.maximumValue = 2.0
        zoomSlider.value = 1.0
        sepSlider.minimumValue = -30
        sepSlider.maximumValue = 30
        sepSlider.value = 0
        for s in [sensSlider, zoomSlider, sepSlider] {
            s.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        }

        let help = UILabel()
        help.text = "En el visor: tocá la pantalla = pausar/activar la cabeza (Juego) o recentrar (Cine). Mantené 1 segundo = volver a esta pantalla."
        help.textColor = .lightGray
        help.font = UIFont.systemFont(ofSize: 12)
        help.numberOfLines = 0

        startButton.setTitle("Iniciar VR", for: .normal)
        startButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 20)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = UIColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        startButton.layer.cornerRadius = 10
        startButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            title,
            statusLabel,
            ipField,
            modeControl,
            makeRow("3D lado a lado (SBS)", sbsSwitch, nil),
            makeRow("Sensibilidad", sensSlider, sensValue),
            makeRow("Zoom", zoomSlider, zoomValue),
            makeRow("Separación ojos", sepSlider, sepValue),
            help,
            startButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func sliderChanged() {
        sens = sensSlider.value
        zoom = CGFloat(zoomSlider.value)
        sep = CGFloat(sepSlider.value)
        sensValue.text = String(format: "%.1fx", sensSlider.value)
        zoomValue.text = String(format: "%.1fx", zoomSlider.value)
        sepValue.text = String(format: "%.0f", sepSlider.value)
        if vrActive { applyImageTransforms() }
    }

    private func foundPC(_ ip: String) {
        statusLabel.text = "PC encontrada: " + ip + "  ✓"
        let current = ipField.text ?? ""
        if current.isEmpty || current == autoFilledIP {
            ipField.text = ip
            autoFilledIP = ip
        }
    }

    // MARK: Preferencias
    private func loadPrefs() {
        let d = UserDefaults.standard
        if let ip = d.string(forKey: "ip") { ipField.text = ip }
        modeControl.selectedSegmentIndex = d.integer(forKey: "mode")
        sbsSwitch.isOn = d.bool(forKey: "sbs")
        if d.object(forKey: "sens") != nil { sensSlider.value = d.float(forKey: "sens") }
        if d.object(forKey: "zoom") != nil { zoomSlider.value = d.float(forKey: "zoom") }
        if d.object(forKey: "sep") != nil { sepSlider.value = d.float(forKey: "sep") }
    }

    private func savePrefs() {
        let d = UserDefaults.standard
        d.set(ipField.text ?? "", forKey: "ip")
        d.set(modeControl.selectedSegmentIndex, forKey: "mode")
        d.set(sbsSwitch.isOn, forKey: "sbs")
        d.set(sensSlider.value, forKey: "sens")
        d.set(zoomSlider.value, forKey: "zoom")
        d.set(sepSlider.value, forKey: "sep")
    }

    // MARK: Vista VR
    private func buildVRView() {
        vrView.frame = view.bounds
        vrView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vrView.backgroundColor = .black
        vrView.isHidden = true
        view.addSubview(vrView)

        for h in [leftHolder, rightHolder] {
            h.masksToBounds = true
            h.backgroundColor = UIColor.black.cgColor
            vrView.layer.addSublayer(h)
        }
        leftHolder.addSublayer(leftImg)
        rightHolder.addSublayer(rightImg)
        for l in [leftImg, rightImg] {
            l.contentsGravity = .resizeAspect
            l.magnificationFilter = .linear
        }
        for (holder, hint) in [(leftHolder, leftHint), (rightHolder, rightHint)] {
            hint.fontSize = 15
            hint.alignmentMode = .center
            hint.isWrapped = true
            hint.foregroundColor = UIColor.white.cgColor
            hint.backgroundColor = UIColor(white: 0, alpha: 0.65).cgColor
            hint.cornerRadius = 8
            hint.contentsScale = UIScreen.main.scale
            hint.isHidden = true
            hint.zPosition = 10
            holder.addSublayer(hint)
        }

        vrView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(vrTapped)))
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(vrLong(_:)))
        lp.minimumPressDuration = 1.0
        vrView.addGestureRecognizer(lp)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutVR()
    }

    private func layoutVR() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = view.bounds.width / 2
        let h = view.bounds.height
        leftHolder.frame = CGRect(x: 0, y: 0, width: w, height: h)
        rightHolder.frame = CGRect(x: w, y: 0, width: w, height: h)
        for l in [leftImg, rightImg] {
            l.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        }
        leftHint.frame = CGRect(x: 8, y: 8, width: max(10, w - 16), height: 48)
        rightHint.frame = CGRect(x: 8, y: 8, width: max(10, w - 16), height: 48)
        CATransaction.commit()
        applyImageTransforms()
    }

    private func applyImageTransforms() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = view.bounds.width / 2
        let h = view.bounds.height
        var ox: CGFloat = 0
        var oy: CGFloat = 0
        if mode == .cinema {
            var dy = curYaw - yawRef
            while dy > Float.pi { dy -= 2 * Float.pi }
            while dy < -Float.pi { dy += 2 * Float.pi }
            let k = w * 1.05
            ox = -CGFloat(dy) * k
            oy = CGFloat(curPitch - pitchRef) * k
        }
        leftImg.position = CGPoint(x: w / 2 + ox - sep, y: h / 2 + oy)
        rightImg.position = CGPoint(x: w / 2 + ox + sep, y: h / 2 + oy)
        let t = CATransform3DMakeScale(zoom, zoom, 1)
        leftImg.transform = t
        rightImg.transform = t
        // 3D lado a lado: la mitad izquierda del cuadro para el ojo izquierdo y la derecha para el derecho
        leftImg.contentsRect = sbs ? CGRect(x: 0, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
        rightImg.contentsRect = sbs ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
    }

    private func showHint(_ text: String, _ secs: Double) {
        hintToken += 1
        let token = hintToken
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for h in [leftHint, rightHint] {
            h.string = text
            h.isHidden = false
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self = self, token == self.hintToken else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.leftHint.isHidden = true
            self.rightHint.isHidden = true
            CATransaction.commit()
        }
    }

    private func showFrame(_ cg: CGImage) {
        guard vrActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftImg.contents = cg
        rightImg.contents = cg
        CATransaction.commit()
        fpsCount += 1
        if !gotFrame {
            gotFrame = true
            showHint("Conectado ✓", 2)
        }
    }

    // MARK: Entrar y salir de VR
    @objc private func startTapped() {
        view.endEditing(true)
        let host = (ipField.text ?? "").trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            statusLabel.text = "Escribí la IP de la PC (la muestra puente_vr.py)"
            return
        }
        savePrefs()
        mode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .game
        sbs = sbsSwitch.isOn
        sliderChanged()
        if !udp.configure(host: host, port: headPort) {
            statusLabel.text = "La IP no es válida"
            return
        }
        gotFrame = false
        client.start(host: host, port: videoPort)
        enterVR()
    }

    private func enterVR() {
        vrActive = true
        headControl = true
        needsRef = true
        scroll.isHidden = true
        vrView.isHidden = false
        udp.send("R")
        startMotion()
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(fpsTick),
                                        userInfo: nil, repeats: true)
        layoutVR()
        showHint("Conectando…", 3)
    }

    private func exitVR() {
        vrActive = false
        client.stop()
        motion.stopDeviceMotionUpdates()
        fpsTimer?.invalidate()
        fpsTimer = nil
        vrView.isHidden = true
        scroll.isHidden = false
    }

    @objc private func fpsTick() {
        fps = fpsCount
        fpsCount = 0
    }

    @objc private func vrTapped() {
        if mode == .game {
            headControl.toggle()
            udp.send("R")
            showHint("Cabeza → mouse: " + (headControl ? "ACTIVADO" : "PAUSADO") + "  (" + String(fps) + " fps)", 2)
        } else {
            needsRef = true
            showHint("Pantalla recentrada  (" + String(fps) + " fps)", 1.5)
        }
    }

    @objc private func vrLong(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { exitVR() }
    }

    // MARK: Movimiento de la cabeza
    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let m = m else { return }
            self?.handleMotion(m)
        }
    }

    private func handleMotion(_ m: CMDeviceMotion) {
        let a = m.attitude.quaternion
        let q = simd_quatf(ix: Float(a.x), iy: Float(a.y), iz: Float(a.z), r: Float(a.w))
        let landscapeRight = UIApplication.shared.statusBarOrientation != .landscapeLeft
        let c = simd_quatf(angle: landscapeRight ? -Float.pi / 2 : Float.pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let w = simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let head = w * q * c
        let f = head.act(SIMD3<Float>(0, 0, -1))
        // yaw positivo = mirar a la derecha; pitch positivo = mirar arriba
        let yawRight = -atan2(-f.x, -f.z)
        let pitch = asin(max(-1, min(1, f.y)))
        curYaw = yawRight
        curPitch = pitch
        if needsRef {
            yawRef = yawRight
            pitchRef = pitch
            needsRef = false
        }
        guard vrActive else { return }
        if mode == .game {
            if headControl {
                udp.send(String(format: "H,%.5f,%.5f,%.2f", yawRight, pitch, sens))
            }
        } else {
            applyImageTransforms()
        }
    }
}
