import SwiftUI
import UIKit

struct AppNavigationContainer<Content: View>: View {
    @AppStorage("APP_THEME") private var appThemeRawValue = AppTheme.system.rawValue
    @ViewBuilder private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        let appTheme = AppTheme(rawValue: appThemeRawValue) ?? .system

        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    content()
                }
            } else {
                NavigationView {
                    content()
                }
                .navigationViewStyle(.stack)
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .background {
            AppThemeHostingBridge(appTheme: appTheme)
                .frame(width: 0, height: 0)
        }
    }
}

private struct AppThemeHostingBridge: UIViewControllerRepresentable {
    let appTheme: AppTheme

    func makeUIViewController(context: Context) -> AppThemeHostingController {
        let controller = AppThemeHostingController()
        controller.overrideStyle = userInterfaceStyle(for: appTheme)
        return controller
    }

    func updateUIViewController(_ uiViewController: AppThemeHostingController, context: Context) {
        uiViewController.overrideStyle = userInterfaceStyle(for: appTheme)
    }

    private func userInterfaceStyle(for appTheme: AppTheme) -> UIUserInterfaceStyle {
        switch appTheme {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private final class AppThemeHostingController: UIViewController {
    var overrideStyle: UIUserInterfaceStyle = .unspecified {
        didSet {
            applyThemeOverrideIfNeeded()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyThemeOverrideIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyThemeOverrideIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyThemeOverrideIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyThemeOverrideIfNeeded()
    }

    private func applyThemeOverrideIfNeeded() {
        let targets = [
            parent,
            parent?.navigationController,
            view.window?.rootViewController
        ]

        for target in targets.compactMap({ $0 }) where target.overrideUserInterfaceStyle != overrideStyle {
            target.overrideUserInterfaceStyle = overrideStyle
        }

        if let window = view.window, window.overrideUserInterfaceStyle != overrideStyle {
            window.overrideUserInterfaceStyle = overrideStyle
        }
    }
}

struct ChildTopBackButton: View {
    var foreground: Color = AppColors.black
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("common.back"))
    }
}

struct ChildTitleBar<Leading: View, Trailing: View>: View {
    let title: String
    var titleColor: Color = AppColors.black
    var horizontalPadding: CGFloat = 20
    var topPadding: CGFloat = 10
    var bottomPadding: CGFloat = 24
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
                .frame(width: 30, height: 30, alignment: .leading)

            Spacer()

            Text(title)
                .font(AppTypography.unbounded(20, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer()

            trailing()
                .frame(width: 30, height: 30, alignment: .trailing)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}

extension View {
    @ViewBuilder
    func appInteractiveKeyboardDismiss() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func appMediumLargeSheetPresentation() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func appNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(
                NavigationLink(isActive: isPresented) {
                    destination()
                } label: {
                    EmptyView()
                }
                .hidden()
            )
        }
    }
}
