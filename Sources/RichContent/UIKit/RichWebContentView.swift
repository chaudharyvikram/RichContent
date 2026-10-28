import UIKit
import WebKit

/// Sandboxed, non-scrolling web view for HTML that needs a browser engine.
/// - Page JavaScript is disabled; remote content loads unless
///   `style.allowsRemoteContent` is off (then blocked by a Content-Security-Policy).
/// - Reports its content height so it can sit inside a SwiftUI / UIKit scroll view.
public final class RichWebContentView: UIView, WKNavigationDelegate {

    public var onHeightChange: ((CGFloat) -> Void)?
    public var onOpenURL: ((URL) -> Void)?

    private let webView: WKWebView
    private var sizeObservation: NSKeyValueObservation?
    private var lastWidth: CGFloat = 0
    private var loadedDocument: String?

    public override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = [.link, .phoneNumber]
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        sizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.measure() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func load(html: String, style: RichContentStyle) {
        let document = Self.document(for: html, style: style)
        guard document != loadedDocument else { return }
        loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            measure()
        }
    }

    /// Scales fixed-width email layouts (600px newsletters) down to the view's
    /// width, like Mail does, and reports the resulting height.
    /// App-injected script runs even with page JavaScript disabled.
    private func measure() {
        let width = bounds.width
        guard width > 0 else { return }
        let script = """
        (function () {
          var r = document.getElementById('rc-root');
          if (!r) { return 0; }
          r.style.transform = 'none';
          r.style.width = '';
          var natural = Math.max(r.scrollWidth, r.offsetWidth);
          var scale = natural > \(width) + 1 ? \(width) / natural : 1;
          if (scale < 1) {
            r.style.width = natural + 'px';
            r.style.transformOrigin = '0 0';
            r.style.transform = 'scale(' + scale + ')';
          }
          return Math.ceil(r.scrollHeight * scale);
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let height = (value as? NSNumber).map({ CGFloat($0.doubleValue) }), height > 0 else { return }
            self.onHeightChange?(height)
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        measure()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if let onOpenURL { onOpenURL(url) } else { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    // MARK: Document

    private static func document(for html: String, style: RichContentStyle) -> String {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func hex(_ color: UIColor, _ traits: UITraitCollection) -> String { color.resolvedColor(with: traits).cssHex }

        let font = WebFontEmbedder.css(for: style.font)
        let forcedFont = style.forcesBaseFontInWebContent
            ? "#rc-root *:not(pre):not(code):not(kbd):not(samp):not(tt) { font-family: \(font.family) !important; }"
            : ""

        let csp = style.allowsRemoteContent
            ? "default-src 'none'; style-src 'unsafe-inline' *; img-src * data: cid:; font-src * data:; media-src *"
            : "default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:; font-src data:"

        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        \(font.faces)
        :root {
          color-scheme: light dark;
          --rc-text: \(hex(style.textColor, light)); --rc-secondary: \(hex(style.secondaryTextColor, light));
          --rc-link: \(hex(style.linkColor, light)); --rc-bar: \(hex(style.quoteBarColor, light));
          --rc-code-bg: \(hex(style.codeBackgroundColor, light));
        }
        @media (prefers-color-scheme: dark) { :root {
          --rc-text: \(hex(style.textColor, dark)); --rc-secondary: \(hex(style.secondaryTextColor, dark));
          --rc-link: \(hex(style.linkColor, dark)); --rc-bar: \(hex(style.quoteBarColor, dark));
          --rc-code-bg: \(hex(style.codeBackgroundColor, dark));
        } }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body {
          font-family: \(font.family); font-size: \(Int(style.font.pointSize.rounded()))px;
          line-height: 1.4; color: var(--rc-text);
          -webkit-text-size-adjust: none; overflow-wrap: anywhere;
        }
        #rc-root { display: flow-root; }
        \(forcedFont)
        #rc-root > :first-child { margin-top: 0; }
        p { margin: 0 0 \(Int(style.paragraphSpacing))px 0; }
        a { color: var(--rc-link); }
        img, video, svg { max-width: 100% !important; height: auto !important; }
        table { max-width: 100% !important; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; background: var(--rc-code-bg); border-radius: 4px; }
        pre { padding: 8px; white-space: pre-wrap; }
        blockquote {
          margin: 6px 0; padding: 0 0 0 \(Int(style.quoteIndent - style.quoteBarWidth))px;
          border-left: \(Int(style.quoteBarWidth))px solid var(--rc-bar);
          color: \(style.dimsQuotedText ? "var(--rc-secondary)" : "inherit");
        }
        </style></head>
        <body><div id="rc-root">\(html)</div></body></html>
        """
    }
}
