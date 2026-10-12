import SwiftUI

/// Agent marks drawn in code so no asset catalogue is needed.
struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 14
    var body: some View {
        Group {
            switch agent {
            case .claude: ClaudeMark().fill(Color(red: 0.85, green: 0.47, blue: 0.34))   // Anthropic coral
            case .codex:  CodexMark().fill(.primary)
            case .retiredDeepSeek: Image(systemName: "archivebox").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.displayName)
    }
}

/// Anthropic/Claude starburst: twelve tapered rays of alternating length around a centre.
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6
            let len = i % 3 == 0 ? R : (i % 3 == 1 ? R * 0.78 : R * 0.9)
            let w = R * 0.16
            let tip = CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
            let base1 = CGPoint(x: c.x + cos(a + .pi / 2) * w, y: c.y + sin(a + .pi / 2) * w)
            let base2 = CGPoint(x: c.x - cos(a + .pi / 2) * w, y: c.y - sin(a + .pi / 2) * w)
            p.move(to: base1); p.addLine(to: tip); p.addLine(to: base2); p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - R * 0.22, y: c.y - R * 0.22, width: R * 0.44, height: R * 0.44))
        return p
    }
}

/// OpenAI/Codex blossom: six interlocking rounded loops rotated 60° apart.
struct CodexMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        let stroke = R * 0.17, loopW = R * 0.58, loopH = R * 0.92
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let rect = CGRect(x: -loopW / 2, y: -loopH - stroke / 2 + R * 0.02, width: loopW, height: loopH)
            let loop = Path(roundedRect: rect, cornerRadius: loopW / 2).strokedPath(StrokeStyle(lineWidth: stroke, lineJoin: .round))
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: 0, y: R * 0.28)
            p.addPath(loop.applying(t))
        }
        return p
    }
}
