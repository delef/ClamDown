/// One screen of the setup assistant.
public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, helper, notifications, startup, done
}

public enum SetupMode: Equatable, Sendable {
    /// All steps, for someone who has not finished setup yet.
    case full
    /// The helper step alone, for someone whose finished setup lost the helper's approval.
    case helperOnly
}

/// Where a request to show the assistant comes from.
public enum SetupEntry: Sendable {
    case launch
    /// Turn On found that the helper needs approval.
    case turnOnNeedsApproval
    case menu
    case settings
}

public struct SetupPresentation: Equatable, Sendable {
    public let mode: SetupMode
    public let step: SetupStep

    public init(mode: SetupMode, step: SetupStep) {
        self.mode = mode
        self.step = step
    }
}

/// The rules of the setup assistant: when it shows, in which mode, and how its steps follow each other.
public enum SetupFlow {
    /// What to show for an entry point. Nil means nothing: the user's setup works, or they finished it before.
    public static func presentation(for entry: SetupEntry, completed: Bool, helper: HelperAvailability) -> SetupPresentation? {
        switch entry {
        case .launch:
            guard !completed, helper != .ready else { return nil }
            return SetupPresentation(mode: .full, step: .welcome)
        case .turnOnNeedsApproval:
            return SetupPresentation(mode: completed ? .helperOnly : .full, step: .helper)
        case .menu:
            return completed ? SetupPresentation(mode: .helperOnly, step: .helper)
                             : SetupPresentation(mode: .full, step: .welcome)
        case .settings:
            return SetupPresentation(mode: .full, step: .welcome)
        }
    }

    /// True when a launch finds a working helper and no finished setup: an existing user, who is never shown the assistant.
    public static func completesSilently(completed: Bool, helper: HelperAvailability) -> Bool {
        !completed && helper == .ready
    }

    public static func steps(for mode: SetupMode) -> [SetupStep] {
        switch mode {
        case .full: SetupStep.allCases
        case .helperOnly: [.helper]
        }
    }

    public static func next(after step: SetupStep, mode: SetupMode) -> SetupStep? {
        neighbor(of: step, mode: mode, offset: 1)
    }

    public static func previous(before step: SetupStep, mode: SetupMode) -> SetupStep? {
        neighbor(of: step, mode: mode, offset: -1)
    }

    /// Only the helper step holds the user back: nothing works without the helper.
    public static func canContinue(from step: SetupStep, helper: HelperAvailability) -> Bool {
        step != .helper || helper == .ready
    }

    private static func neighbor(of step: SetupStep, mode: SetupMode, offset: Int) -> SetupStep? {
        let all = steps(for: mode)
        guard let index = all.firstIndex(of: step), all.indices.contains(index + offset) else { return nil }
        return all[index + offset]
    }
}
