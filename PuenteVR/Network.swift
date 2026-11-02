import Foundation
import ImageIO
import CoreGraphics

// MARK: - Cliente de video (MJPEG por HTTP)
/// Se conecta a la PC, recibe un flujo de imágenes JPEG y entrega siempre la más reciente.
final class MJPEGClient: NSObject, URLSessionDataDelegate {
    var onFrame: ((CGImage) -> Void)?
    var onStatus: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let opQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let decodeQueue = DispatchQueue(label: "mjpeg.decode")
    private let lock = NSLock()
    private var busy = false
    private var running = false
    private var host = ""
    private var port = 8081
    private var generation = 0

    func start(host: String, port: Int) {
        stop()
        self.host = host
        self.port = port
        running = true
        generation += 1
        connect()
    }

    private func connect() {
        guard running, let url = URL(string: "http://\(host):\(port)/") else {
            onStatus?("IP inválida")
            return
        }
        session?.invalidateAndCancel()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 86400
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
        session = s
        opQueue.addOperation { [weak self] in self?.buffer.removeAll() }
        let t = s.dataTask(with: url)
        task = t
        t.resume()
        onStatus?("Conectando a \(host)…")
    }

    func stop() {
        running = false
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        opQueue.addOperation { [weak self] in self?.buffer.removeAll() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        buffer.removeAll()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard running else { return }
        buffer.append(data)

        // Buscar imágenes JPEG completas (de FFD8 a FFD9)
        var frames: [Data] = []
        var consumed = 0
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            while i < n - 1 {
                if p[i] == 0xFF {
                    let b = p[i + 1]
                    if b == 0xD8 && start < 0 {
                        start = i
                        i += 2
                        continue
                    }
                    if b == 0xD9 && start >= 0 {
                        frames.append(Data(p[start...(i + 1)]))
                        start = -1
                        i += 2
                        continue
                    }
                }
                i += 1
            }
            consumed = start >= 0 ? start : max(0, n - 1)
        }
        if consumed > 0 { buffer.removeSubrange(0..<consumed) }

        // Solo decodificamos la más nueva (así no se acumula retraso)
        guard let last = frames.last else { return }
        lock.lock()
        let skip = busy
        if !skip { busy = true }
        lock.unlock()
        if skip { return }

        let gen = generation
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            var out: CGImage? = nil
            if let src = CGImageSourceCreateWithData(last as CFData, nil) {
                out = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
            }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
            if let img = out, self.running, gen == self.generation {
                DispatchQueue.main.async { self.onFrame?(img) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running else { return }
        onStatus?("Conexión perdida. Reintentando…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.running else { return }
            self.connect()
        }
    }
}

// MARK: - Envío de datos de la cabeza a la PC (UDP)
final class UDPSender {
    private var fd: Int32 = -1
    private var addr = sockaddr_in()
    private var ready = false

    func configure(host: String, port: UInt16) -> Bool {
        shutdownSocket()
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else {
            Darwin.close(s)
            return false
        }
        fd = s
        addr = a
        ready = true
        return true
    }

    func send(_ text: String) {
        guard ready, let data = text.data(using: .utf8) else { return }
        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var a = addr
            withUnsafePointer(to: &a) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    _ = sendto(fd, raw.baseAddress, count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func shutdownSocket() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        ready = false
    }
}

// MARK: - Aviso de la PC ("acá estoy"), para no tener que escribir la IP
final class BeaconListener {
    var onFound: ((String) -> Void)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(5007).bigEndian
            addr.sin_addr.s_addr = 0
            let result = withUnsafePointer(to: &addr) { p -> Int32 in
                return p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int32 in
                    return bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                Darwin.close(fd)
                return
            }
            var buf = [UInt8](repeating: 0, count: 64)
            let cap = buf.count
            while true {
                var sender = sockaddr_in()
                var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &sender) { sp -> Int in
                    return sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { rp -> Int in
                        return recvfrom(fd, &buf, cap, 0, rp, &slen)
                    }
                }
                if n <= 0 {
                    usleep(50000)
                    continue
                }
                let text = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                if text.hasPrefix("PUENTEVR") {
                    let ip = String(cString: inet_ntoa(sender.sin_addr))
                    DispatchQueue.main.async { self?.onFound?(ip) }
                }
            }
        }
    }
}
