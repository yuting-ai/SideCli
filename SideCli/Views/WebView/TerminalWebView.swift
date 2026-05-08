//
//  TerminalWebView.swift
//  SideCli
//
//  WebView wrapper for xterm.js terminal
//

import SwiftUI
import WebKit

struct TerminalWebView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let onReady: (() -> Void)?
    var isDark: Bool
    var fontSize: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "terminalInput")
        userContentController.add(context.coordinator, name: "terminalCopy")
        userContentController.add(context.coordinator, name: "terminalPaste")
        userContentController.add(context.coordinator, name: "terminalResize")
        userContentController.add(context.coordinator, name: "terminalReady")
        userContentController.add(context.coordinator, name: "terminalError")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        loadTerminalHTML(into: webView)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if session.isActive {
            nsView.evaluateJavaScript("window.focusTerminal()", completionHandler: nil)
        }
        context.coordinator.isDark = isDark
        nsView.evaluateJavaScript("window.setTheme(\(isDark))", completionHandler: nil)
        context.coordinator.fontSize = fontSize
        nsView.evaluateJavaScript("window.setFontSize(\(fontSize))", completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func loadTerminalHTML(into webView: WKWebView) {
        let candidateURLs = [
            Bundle.main.url(forResource: "terminal", withExtension: "html"),
            Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "Resources")
        ]

        if let url = candidateURLs.compactMap({ $0 }).first {
            let urlWithId = url.appendingQueryItem(name: "id", value: session.id.uuidString)
            webView.loadFileURL(urlWithId, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }

        let escapedId = session.id.uuidString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let fallbackHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    margin: 0;
                    padding: 20px;
                    background: #1e1e1e;
                    color: #d4d4d4;
                    font: 13px Menlo, Monaco, monospace;
                }
                .error {
                    color: #f48771;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body>
            <div class="error">Unable to load terminal UI resources.\nExpected bundled file: terminal.html\nSession: \(escapedId)</div>
        </body>
        </html>
        """

        webView.loadHTMLString(fallbackHTML, baseURL: nil)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: TerminalWebView
        var webView: WKWebView?
        var isReady = false
        var isDark: Bool
        var fontSize: Int
        private var didStartSession = false

        init(_ parent: TerminalWebView) {
            self.parent   = parent
            self.isDark   = parent.isDark
            self.fontSize = parent.fontSize
            super.init()

            parent.session.onDataReceived = { [weak self] data in
                self?.sendDataToWebView(data)
            }

            parent.session.onStateChanged = { [weak self] state in
                if case .running = state { }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("WebView navigation failed: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("WebView provisional navigation failed: \(error)")
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let terminalIdString = body["terminalId"] as? String,
                  let terminalId = UUID(uuidString: terminalIdString),
                  terminalId == parent.session.id else {
                return
            }

            switch message.name {
            case "terminalInput":
                if let data = body["data"] as? String {
                    handleTerminalInput(data)
                }

            case "terminalCopy":
                if let text = body["text"] as? String {
                    handleTerminalCopy(text)
                }

            case "terminalPaste":
                handleTerminalPasteRequest()

            case "terminalResize":
                if let cols = body["cols"] as? Int,
                   let rows = body["rows"] as? Int {
                    handleTerminalResize(cols: cols, rows: rows)
                }

            case "terminalReady":
                if let cols = body["cols"] as? Int,
                   let rows = body["rows"] as? Int {
                    handleTerminalReady(cols: cols, rows: rows)
                }

            case "terminalError":
                if let error = body["error"] as? String {
                    print("Terminal error: \(error)")
                }

            default:
                break
            }
        }

        // MARK: - Private Methods

        private func handleTerminalInput(_ data: String) {
            if parent.session.handleTerminalControlInput(data) {
                return
            }
            parent.session.write(data)
        }

        private func handleTerminalCopy(_ text: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        private func handleTerminalPasteRequest() {
            let pasteboard = NSPasteboard.general
            guard let text = pasteboard.string(forType: .string),
                  let data = text.data(using: .utf8) else { return }
            let base64Text = data.base64EncodedString()
            let js = "window.pasteToTerminal('\(base64Text)')"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func handleTerminalResize(cols: Int, rows: Int) {
            parent.session.resize(cols: cols, rows: rows)
            startSessionIfNeeded(cols: cols, rows: rows)
        }

        private func handleTerminalReady(cols: Int, rows: Int) {
            isReady = true

            parent.session.resize(cols: cols, rows: rows)
            startSessionIfNeeded(cols: cols, rows: rows)

            webView?.evaluateJavaScript("window.setTheme(\(isDark))", completionHandler: nil)
            webView?.evaluateJavaScript("window.setFontSize(\(fontSize))", completionHandler: nil)

            DispatchQueue.main.async {
                self.parent.onReady?()
            }
        }

        private func startSessionIfNeeded(cols: Int, rows: Int) {
            guard !didStartSession else { return }
            // Split views may briefly report degenerate dimensions before layout settles.
            // Delay shell startup until terminal geometry is usable to avoid corrupted
            // first-prompt rendering (e.g. stray `%` on first line).
            guard cols > 2, rows > 1 else { return }
            didStartSession = true
            parent.session.start()
        }

        private func sendDataToWebView(_ data: Data) {
            guard let webView = webView else { return }

            // base64-encode to avoid escaping issues in the JS string literal
            let base64Data = data.base64EncodedString()
            let js = """
                (function() {
                    const data = atob('\(base64Data)');
                    const bytes = new Uint8Array(data.length);
                    for (let i = 0; i < data.length; i++) {
                        bytes[i] = data.charCodeAt(i);
                    }
                    const decoder = new TextDecoder('utf-8');
                    window.writeToTerminal(decoder.decode(bytes));
                })();
            """

            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("JavaScript execution error: \(error)")
                }
            }
        }
    }
}

// MARK: - URL Extension

extension URL {
    func appendingQueryItem(name: String, value: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: name, value: value))
        components?.queryItems = queryItems
        return components?.url ?? self
    }
}
