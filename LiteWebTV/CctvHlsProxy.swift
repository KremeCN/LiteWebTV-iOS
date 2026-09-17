import Foundation
import Network

/// 本机环回 HLS：改写 playlist，分片交给 H5E 会话后再给 AVPlayer。
final class CctvHlsProxy {
    static let shared = CctvHlsProxy()

    private let queue = DispatchQueue(label: "com.kremecn.litewebtv.hls-proxy")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var inbox: [String: Data] = [:]
    private var outbox: [String: Data] = [:]
    private let boxLock = NSLock()
    private var currentSlug = "cctv1"
    private var decryptor: CctvH5eSession?
    private let session: URLSession

    var userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func start(decryptor: CctvH5eSession) throws {
        self.decryptor = decryptor
        if listener != nil, port != 0 { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let value = listener.port?.rawValue {
                    self?.port = value
                }
                started.signal()
            case .failed:
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = started.wait(timeout: .now() + 2)
        guard port != 0 else {
            throw ProxyError.listenFailed
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        decryptor = nil
        boxLock.lock()
        inbox.removeAll()
        outbox.removeAll()
        boxLock.unlock()
    }

    func playURL(for slug: String) -> URL? {
        currentSlug = slug
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8?slug=\(slug)")
    }

    func storeInbox(_ data: Data, id: String) {
        boxLock.lock()
        inbox[id] = data
        boxLock.unlock()
    }

    func takeInbox(id: String) -> Data? {
        boxLock.lock()
        defer { boxLock.unlock() }
        let data = inbox[id]
        inbox[id] = nil
        return data
    }

    func storeOutbox(_ data: Data, id: String) {
        boxLock.lock()
        outbox[id] = data
        boxLock.unlock()
    }

    func takeOutbox(id: String) -> Data? {
        boxLock.lock()
        defer { boxLock.unlock() }
        let data = outbox[id]
        outbox[id] = nil
        return data
    }

    var loopbackOrigin: String {
        "http://127.0.0.1:\(port)"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            guard let headerRange = next.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                    return
                }
                self.readRequest(connection, buffer: next)
                return
            }
            let header = String(data: next[..<headerRange.lowerBound], encoding: .utf8) ?? ""
            let rest = Data(next[headerRange.upperBound...])
            let length = self.contentLength(in: header)
            if rest.count < length {
                self.readBody(connection, header: header, body: rest, needed: length)
                return
            }
            self.serve(header: header, body: Data(rest.prefix(length)), connection: connection)
        }
    }

    private func readBody(_ connection: NWConnection, header: String, body: Data, needed: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = body
            if let data { next.append(data) }
            if next.count >= needed {
                self.serve(header: header, body: Data(next.prefix(needed)), connection: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.readBody(connection, header: header, body: next, needed: needed)
        }
    }

    private func contentLength(in header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func serve(header: String, body: Data, connection: NWConnection) {
        let first = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: String(parts[1]), relativeTo: URL(string: loopbackOrigin)) else {
            respond(connection, status: 400, contentType: "text/plain", body: Data("url\n".utf8))
            return
        }
        let method = String(parts[0])
        if method == "OPTIONS" {
            respond(connection, status: 204, contentType: "text/plain", body: Data())
            return
        }
        if method == "PUT", url.path.hasPrefix("/outbox/") {
            let id = String(url.path.dropFirst("/outbox/".count))
            storeOutbox(body, id: id)
            respond(connection, status: 204, contentType: "text/plain", body: Data())
            return
        }
        guard method == "GET" else {
            respond(connection, status: 405, contentType: "text/plain", body: Data("method\n".utf8))
            return
        }
        let path = url.path
        if path == "/master.m3u8" {
            let slug = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "slug" })?.value ?? currentSlug
            serveMaster(slug: slug, connection: connection)
            return
        }
        if path == "/media.m3u8" {
            guard let target = queryURL(url, name: "u") else {
                respond(connection, status: 400, contentType: "text/plain", body: Data("u\n".utf8))
                return
            }
            serveMedia(target, connection: connection)
            return
        }
        if path == "/seg.ts" {
            guard let target = queryURL(url, name: "u") else {
                respond(connection, status: 400, contentType: "text/plain", body: Data("u\n".utf8))
                return
            }
            serveSegment(target, connection: connection)
            return
        }
        if path == "/h5e.html" {
            respond(connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(Self.h5eHTML.utf8))
            return
        }
        if path.lowercased().hasPrefix("/library/") {
            serveLibrary(path, connection: connection)
            return
        }
        if path == "/h5e.js" {
            if let url = Bundle.main.url(forResource: "cctv_h5e_host", withExtension: "js"),
               let data = try? Data(contentsOf: url) {
                respond(connection, status: 200, contentType: "text/javascript; charset=utf-8", body: data)
                return
            }
            respond(connection, status: 404, contentType: "text/plain", body: Data("js\n".utf8))
            return
        }
        if path.hasPrefix("/inbox/") {
            let id = String(path.dropFirst("/inbox/".count))
            let body = takeInbox(id: id) ?? Data()
            respond(connection, status: body.isEmpty ? 404 : 200, contentType: "application/octet-stream", body: body)
            return
        }
        respond(connection, status: 404, contentType: "text/plain", body: Data("missing\n".utf8))
    }

    /// InitPlayer 会按页面源去拉 `/Library/H5player.json`。隐藏页在 127.0.0.1，必须转给官网。
    private static let h5playerFallback = Data(
        #"{"h5player":{"ver":20190904,"md5":"c7ed5a71dbe4dee1a2ba171f660ee98d","BTime":"2019-09-04-20:25:10"}}"#.utf8
    )

    private static let h5eHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <script>
    (function () {
      function rewrite(url) {
        try {
          var u = new URL(String(url), location.href);
          var path = u.pathname;
          if (path.indexOf('/Library/') === 0 || path.indexOf('/library/') === 0) {
            return location.origin + path + u.search;
          }
        } catch (err) {}
        return url;
      }
      window.__lwtvH5eConfigLoaded = false;
      function markConfig() { window.__lwtvH5eConfigLoaded = true; }
      var ofetch = window.fetch.bind(window);
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? rewrite(input) : (input && input.url ? rewrite(input.url) : input);
        var req = (typeof input === 'string') ? url : (input && input.url ? new Request(url, input) : input);
        var p = ofetch(req, init);
        if (String(url).toLowerCase().indexOf('h5player.json') >= 0) p.then(markConfig, markConfig);
        return p;
      };
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        var next = typeof url === 'string' ? rewrite(url) : url;
        arguments[1] = next;
        if (String(next).toLowerCase().indexOf('h5player.json') >= 0) {
          this.addEventListener('loadend', markConfig);
        }
        return open.apply(this, arguments);
      };
    })();
    </script>
    <script src="https://js.player.cntv.cn/creator/live.worker.js"></script>
    <script src="/h5e.js"></script>
    </head><body></body></html>
    """

    private func serveLibrary(_ path: String, connection: NWConnection) {
        if path.lowercased().hasSuffix("/h5player.json") {
            respond(connection, status: 200, contentType: "application/json", body: Self.h5playerFallback)
            return
        }
        guard let remote = URL(string: "https://tv.cctv.com" + path) else {
            respond(connection, status: 404, contentType: "text/plain", body: Data("library\n".utf8))
            return
        }
        fetch(remote, slug: currentSlug) { [weak self] data, type in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.respond(
                    connection,
                    status: 200,
                    contentType: type ?? "application/octet-stream",
                    body: data
                )
                return
            }
            self.respond(connection, status: 404, contentType: "text/plain", body: Data("library\n".utf8))
        }
    }

    private func serveMaster(slug: String, connection: NWConnection) {
        guard let masterURL = CctvNativeCatalog.masterURL(for: slug) else {
            respond(connection, status: 404, contentType: "text/plain", body: Data("slug\n".utf8))
            return
        }
        fetch(masterURL, slug: slug) { [weak self] data, type in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                self?.respond(connection, status: 502, contentType: "text/plain", body: Data("master\n".utf8))
                return
            }
            if let variant = CctvHlsRewriter.selectHighestVariant(from: text, masterURL: masterURL) {
                let proxied = self.mediaProxyURL(variant)
                let body = """
                #EXTM3U
                #EXT-X-INDEPENDENT-SEGMENTS
                #EXT-X-STREAM-INF:BANDWIDTH=4000000
                \(proxied)

                """
                self.respond(connection, status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(body.utf8))
                return
            }
            let rewritten = CctvHlsRewriter.rewriteMediaPlaylist(text, mediaURL: masterURL) { [weak self] url in
                self?.segmentProxyURL(url) ?? url.absoluteString
            }
            self.respond(connection, status: 200, contentType: type ?? "application/vnd.apple.mpegurl", body: Data(rewritten.utf8))
        }
    }

    private func serveMedia(_ target: URL, connection: NWConnection) {
        fetch(target, slug: currentSlug) { [weak self] data, type in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                self?.respond(connection, status: 502, contentType: "text/plain", body: Data("media\n".utf8))
                return
            }
            let rewritten = CctvHlsRewriter.rewriteMediaPlaylist(text, mediaURL: target) { [weak self] url in
                self?.segmentProxyURL(url) ?? url.absoluteString
            }
            self.respond(connection, status: 200, contentType: type ?? "application/vnd.apple.mpegurl", body: Data(rewritten.utf8))
        }
    }

    private func serveSegment(_ target: URL, connection: NWConnection) {
        fetch(target, slug: currentSlug) { [weak self] data, _ in
            guard let self, let data else {
                self?.respond(connection, status: 502, contentType: "text/plain", body: Data("seg\n".utf8))
                return
            }
            guard let decryptor = self.decryptor else {
                self.respond(connection, status: 502, contentType: "text/plain", body: Data("session\n".utf8))
                return
            }
            decryptor.decrypt(data) { decrypted in
                guard let decrypted else {
                    self.respond(connection, status: 502, contentType: "text/plain", body: Data("drop\n".utf8))
                    return
                }
                self.respond(connection, status: 200, contentType: "video/MP2T", body: decrypted)
            }
        }
    }

    private func fetch(_ url: URL, slug: String, completion: @escaping (Data?, String?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(CctvNativeCatalog.referer(for: slug).absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://tv.cctv.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion(nil, nil)
                return
            }
            completion(data, http.value(forHTTPHeaderField: "Content-Type"))
        }.resume()
    }

    private func encodedProxyURL(path: String, target: URL) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        components.queryItems = [URLQueryItem(name: "u", value: target.absoluteString)]
        return components.url?.absoluteString ?? "\(loopbackOrigin)\(path)"
    }

    private func mediaProxyURL(_ url: URL) -> String {
        encodedProxyURL(path: "/media.m3u8", target: url)
    }

    private func segmentProxyURL(_ url: URL) -> String {
        encodedProxyURL(path: "/seg.ts", target: url)
    }

    private func queryURL(_ url: URL, name: String) -> URL? {
        let items = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)?.queryItems
        guard let value = items?.first(where: { $0.name == name })?.value else { return nil }
        return URL(string: value)
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason = (200..<300).contains(status) ? "OK" : "ERR"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, PUT, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    enum ProxyError: Error {
        case listenFailed
    }
}
