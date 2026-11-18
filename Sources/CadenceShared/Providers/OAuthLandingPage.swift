import Foundation

/// The page the browser shows after Google redirects back to the loopback server.
/// Self-contained (no external fonts, scripts or images) so it renders offline and instantly.
enum OAuthLandingPage {
    /// Builds the page for a redirect. `error` is Google's `error` query value, if any.
    static func html(error: String?) -> String {
        let success = error == nil
        let title = success ? "You're connected" : "Couldn't connect"
        let message = success
            ? "Cadence can now see your Google Calendar. You can close this tab and head back to the app."
            : "Google didn't grant access, so nothing was connected. Close this tab and try again from Cadence."
        let detail = error.map { "<p class=\"detail\">Google said: <code>\(escape($0))</code></p>" } ?? ""
        let icon = success
            ? """
              <svg viewBox="0 0 52 52" aria-hidden="true"><circle class="ring" cx="26" cy="26" r="24"/><path class="mark" d="M15 27l7 7 15-16"/></svg>
              """
            : """
              <svg viewBox="0 0 52 52" aria-hidden="true"><circle class="ring" cx="26" cy="26" r="24"/><path class="mark" d="M18 18l16 16M34 18L18 34"/></svg>
              """

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Cadence · \(title)</title>
        <style>
        :root {
          --bg-1: #f4f6fb; --bg-2: #e8ecf7;
          --card: rgba(255,255,255,.78); --border: rgba(15,23,42,.08);
          --text: #0f172a; --muted: #5b6478;
          --accent: \(success ? "#22a06b" : "#e5484d");
          --accent-soft: \(success ? "rgba(34,160,107,.14)" : "rgba(229,72,77,.14)");
          --glow-a: rgba(99,102,241,.28); --glow-b: rgba(236,72,153,.18);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg-1: #0b0d14; --bg-2: #131726;
            --card: rgba(24,28,42,.72); --border: rgba(255,255,255,.08);
            --text: #eef1f8; --muted: #9aa3b8;
            --accent: \(success ? "#3ddc97" : "#ff6b6f");
            --glow-a: rgba(99,102,241,.35); --glow-b: rgba(236,72,153,.22);
          }
        }
        * { box-sizing: border-box; margin: 0; }
        html, body { height: 100%; }
        body {
          font: 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
          color: var(--text);
          background: linear-gradient(160deg, var(--bg-1), var(--bg-2));
          display: grid; place-items: center; padding: 24px; overflow: hidden;
          -webkit-font-smoothing: antialiased;
        }
        body::before, body::after {
          content: ""; position: fixed; width: 60vmax; height: 60vmax; border-radius: 50%;
          filter: blur(80px); z-index: -1; animation: drift 18s ease-in-out infinite alternate;
        }
        body::before { background: var(--glow-a); top: -25vmax; left: -15vmax; }
        body::after { background: var(--glow-b); bottom: -25vmax; right: -15vmax; animation-delay: -9s; }
        @keyframes drift { to { transform: translate(6vmax, 4vmax) scale(1.08); } }
        .card {
          width: 100%; max-width: 420px; padding: 44px 36px 36px; text-align: center;
          background: var(--card); border: 1px solid var(--border); border-radius: 24px;
          backdrop-filter: blur(24px) saturate(1.4); -webkit-backdrop-filter: blur(24px) saturate(1.4);
          box-shadow: 0 1px 0 rgba(255,255,255,.06) inset, 0 24px 60px -20px rgba(15,23,42,.35);
          animation: rise .6s cubic-bezier(.2,.8,.2,1) both;
        }
        @keyframes rise { from { opacity: 0; transform: translateY(14px) scale(.98); } }
        .badge {
          width: 88px; height: 88px; margin: 0 auto 24px; border-radius: 50%;
          display: grid; place-items: center; background: var(--accent-soft);
        }
        .badge svg { width: 56px; height: 56px; fill: none; stroke: var(--accent); stroke-width: 3.5; stroke-linecap: round; stroke-linejoin: round; }
        .ring { stroke-dasharray: 151; stroke-dashoffset: 151; animation: draw .7s .15s ease-out forwards; }
        .mark { stroke-dasharray: 48; stroke-dashoffset: 48; animation: draw .4s .7s ease-out forwards; }
        @keyframes draw { to { stroke-dashoffset: 0; } }
        .brand {
          display: inline-flex; align-items: center; gap: 8px; margin-bottom: 14px;
          font-size: 13px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--muted);
        }
        .brand svg { width: 16px; height: 16px; }
        h1 { font-size: 26px; font-weight: 700; letter-spacing: -.02em; margin-bottom: 10px; }
        p { color: var(--muted); }
        .detail { margin-top: 16px; font-size: 13px; }
        code {
          font: 12px ui-monospace, "SF Mono", Menlo, monospace; padding: 2px 6px; border-radius: 6px;
          background: var(--accent-soft); color: var(--text);
        }
        .hint {
          margin-top: 28px; padding-top: 20px; border-top: 1px solid var(--border);
          font-size: 13px; color: var(--muted);
        }
        kbd {
          font: 600 12px -apple-system, sans-serif; padding: 2px 7px; border-radius: 6px;
          border: 1px solid var(--border); border-bottom-width: 2px; background: var(--card); color: var(--text);
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after { animation: none !important; }
          .ring, .mark { stroke-dashoffset: 0; }
        }
        </style>
        </head>
        <body>
        <main class="card">
          <div class="badge">\(icon)</div>
          <div class="brand">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="2" y="3" width="12" height="11" rx="2.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" stroke-linecap="round"/></svg>
            Cadence
          </div>
          <h1>\(title)</h1>
          <p>\(message)</p>
          \(detail)
          <p class="hint">Close this tab with <kbd>⌘</kbd> <kbd>W</kbd></p>
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
