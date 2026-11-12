// One screen: the tomato, the countdown, the four tomatoes, and Sign in with Apple for syncing.
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: TimerModel
    @AppStorage("display", store: appGroup) private var style = DisplayStyle.numbers
    @AppStorage("restMinutes", store: appGroup) private var rest = 5.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = model.state
            let done = s.running && (s.endAt ?? 0) <= ctx.date.timeIntervalSince1970
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                if done && s.phase == .focus {
                    BreakDial(minutes: $rest).frame(width: 240, height: 240)
                } else if style == .clock {
                    RedClock(fraction: clockFraction(s, now: ctx.date), color: s.phase == .rest ? tierColor("Break") : clockRed)
                        .frame(width: 240, height: 240)
                } else {
                    Image("Tomato").resizable().scaledToFit().frame(width: 170)
                        .opacity(s.phase == .rest ? 0.45 : 1)
                }
                Text(heading(s, done: done)).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                Group {
                    if s.phase == .idle {
                        Text(clock(tomatoTiers[model.tierIndex].minutes * 60)).monospacedDigit()
                    } else {
                        Countdown(running: s.running, endAt: s.endAt ?? 0, left: s.left)
                    }
                }
                .font(.system(size: style == .clock ? 40 : 76, weight: .semibold, design: .rounded))
                .foregroundStyle(tierColor(s.phase == .idle ? tomatoTiers[model.tierIndex].name : s.tier))
                .contentTransition(.numericText())

                if s.phase == .idle { TierPicker(selection: $model.tierIndex) }
                buttons(s, done: done)
                Spacer()
                Picker("Display", selection: $style) {
                    Text("Numbers").tag(DisplayStyle.numbers)
                    Text("Red clock").tag(DisplayStyle.clock)
                }
                .pickerStyle(.segmented)
                .onChange(of: style) { model.displayChanged() }
                SyncFooter()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private func heading(_ s: TimerState, done: Bool) -> String {
        if done { return s.phase == .rest ? "Break's over" : "Tomato done! Drag to set your break" }
        switch s.phase {
        case .idle: return "Pick a tomato"
        case .rest: return s.running ? "Break" : "Break · paused"
        case .focus: return s.running ? "\(s.tier) tomato" : "\(s.tier) tomato · paused"
        }
    }

    @ViewBuilder private func buttons(_ s: TimerState, done: Bool) -> some View {
        HStack(spacing: 14) {
            if done {
                if s.phase == .focus { big("Break · \(Int(rest)) min", tint: tierColor("Break")) { model.startBreak(minutes: rest) } }
                big(s.phase == .focus ? "Done" : "Next tomato", tint: .red) {
                    s.phase == .focus ? model.stop() : model.startTomato()
                }
            } else if s.phase == .idle {
                big("Start", tint: .red) { model.startTomato() }
            } else {
                big(s.running ? "Pause" : "Resume", tint: .red) { s.running ? model.pause() : model.resume() }
                big("Stop", tint: .gray) { model.stop() }
            }
        }
    }

    private func big(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34) }
            .buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
    }
}

struct TierPicker: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(tomatoTiers.indices, id: \.self) { i in
                let t = tomatoTiers[i]
                Button { selection = i } label: {
                    VStack(spacing: 4) {
                        Circle().fill(tierColor(t.name)).frame(width: 22, height: 22)
                        Text(t.name).font(.caption.weight(.semibold))
                        Text("\(Int(t.minutes)) min").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selection == i ? Color(.secondarySystemFill) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Signed out: this phone only. Signed in (the same Apple ID as Tomatime Groups on the Mac): shared timer.
struct SyncFooter: View {
    @EnvironmentObject var model: TimerModel
    @State private var nonce = ""
    @State private var error: String?

    var body: some View {
        if FirebaseApp.app() == nil {
            EmptyView()
        } else if model.uid != nil {
            HStack {
                Label("Synced with your Mac and Watch", systemImage: "checkmark.circle.fill").font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out") { model.signOut() }.font(.footnote)
            }
        } else {
            VStack(spacing: 6) {
                Text("Sync with Tomatime on your Mac and Apple Watch").font(.footnote).foregroundStyle(.secondary)
                SignInWithAppleButton(.signIn) { req in
                    nonce = UUID().uuidString + UUID().uuidString
                    req.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
                } onCompletion: { result in
                    guard case .success(let auth) = result, let apple = auth.credential as? ASAuthorizationAppleIDCredential,
                          let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
                    let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil)
                    Auth.auth().signIn(with: credential) { _, e in error = e?.localizedDescription }
                }
                .frame(height: 46)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

// Set the break like a kitchen timer: drag around the circle (a full turn is 30 minutes).
struct BreakDial: View {
    @Binding var minutes: Double
    var body: some View {
        GeometryReader { g in
            RedClock(fraction: minutes / maxRestMinutes, color: tierColor("Break"))
                .overlay(Text("\(Int(minutes)) min").font(.title2.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule()))
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let dx = v.location.x - g.size.width / 2, dy = g.size.height / 2 - v.location.y
                    var a = atan2(dx, dy) * 180 / .pi  // 0 at 12 o'clock, clockwise
                    if a < 0 { a += 360 }
                    minutes = max(1, min(maxRestMinutes, (a / 360 * maxRestMinutes).rounded()))
                })
                .sensoryFeedback(.selection, trigger: minutes)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
