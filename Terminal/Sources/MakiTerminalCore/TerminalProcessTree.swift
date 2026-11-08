import Darwin
import Foundation

/// Whether closing a pane would end a running command (F4 safety).
///
/// Ghostty exposes the terminal's foreground process id, which is the process
/// group the shell puts in front. The shell itself sits just below the `login`
/// wrapper (`MakiTerminal → login → zsh → command`); without the wrapper it is
/// the helper's direct child. A deeper foreground process is a command, an
/// equal one is the idle shell.
///
/// `ghostty_surface_needs_confirm_quit` is the fallback when the process tree
/// cannot be read. It can answer "yes" for an idle shell when prompt markers
/// are unavailable, so the tree is preferred whenever it is complete.
public enum TerminalProcessTree {
    /// The shell or configured command that owns the pane. Nil when the chain
    /// cannot be followed (dead process, recycled pid, unreadable path).
    public static func baselinePID(foreground: pid_t,
                                   helper: pid_t,
                                   parent: (pid_t) -> pid_t,
                                   path: (pid_t) -> String) -> pid_t? {
        guard foreground > 1, helper > 1, foreground != helper else { return nil }
        var current = foreground
        var belowWrapper: pid_t?
        var parentPID = parent(current)
        var steps = 0
        while parentPID > 1, parentPID != helper, steps < 64 {
            belowWrapper = current
            current = parentPID
            parentPID = parent(current)
            steps += 1
        }
        guard parentPID == helper else { return nil }
        let executable = path(current)
        guard executable.isEmpty == false else { return nil }
        if executable.hasSuffix("/login") {
            return belowWrapper
        }
        return current
    }

    /// The close rule: a configured SSH/tmux session always asks; otherwise a
    /// readable tree decides, and Ghostty's answer is used only when the tree
    /// is unknown.
    public static func shouldConfirmClose(configuredCommand: Bool,
                                          ghosttySaysConfirm: Bool,
                                          foreground: pid_t?,
                                          baseline: pid_t?) -> Bool {
        if configuredCommand { return true }
        if let foreground, let baseline, foreground > 1 {
            return foreground != baseline
        }
        return ghosttySaysConfirm
    }

    /// Parent pid for a live process, including setuid wrappers such as
    /// `/usr/bin/login`. `proc_pidinfo(PROC_PIDTBSDINFO)` refuses those, while
    /// `sysctl(KERN_PROC_PID)` still answers. 0 when the process is gone.
    public static func parentPID(of pid: pid_t) -> pid_t {
        guard pid > 1 else { return 0 }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let read = sysctl(&mib, 4, &info, &size, nil, 0)
        guard read == 0, size > 0 else { return 0 }
        return pid_t(info.kp_eproc.e_ppid)
    }

    /// The executable behind a pid, or an empty string when it cannot be read.
    public static func executablePath(of pid: pid_t) -> String {
        guard pid > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }
}
