import SwiftUI
import GPUWatchCore

/// First-run state.
///
/// Two real paths forward, not a decorative placeholder: add a host, or look at
/// the demo fleet. The demo option matters because it lets an operator judge
/// whether the app is worth configuring before they hand it any credentials.
struct EmptyFleetView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Add your first GPU server")
                    .font(DS.TextStyle.title)
                Text(
                    "GPU Watch connects over SSH with your existing keys and config. "
                    + "Nothing is installed on the server."
                )
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.Space.s) {
                PrimaryAction("Add Host", symbol: "plus", action: coordinator.beginAddHost)
                SecondaryAction("Try Demo", symbol: "sparkles") {
                    coordinator.setDemoMode(true)
                }
            }

            Text("Demo mode shows a synthetic fleet. It never opens a network connection.")
                .font(DS.TextStyle.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(DS.TextStyle.bodyStrong)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                        .fill(Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SecondaryAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(DS.TextStyle.bodyStrong)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
