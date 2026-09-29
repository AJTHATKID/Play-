from pathlib import Path

def replace_exact(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"Patch marker not found for {label}: {path}")
    p.write_text(s.replace(old, new))
    print(f"patched {label}")

# 1) Make external JIT requests one-tap for the dedicated Play! flow.
replace_exact(
    "StikDebug/App/AppBootstrapper.swift",
    "UserDefaults.Keys.confirmExternalJITRequests: true,",
    "UserDefaults.Keys.confirmExternalJITRequests: false,",
    "external request confirmation default"
)

# 2) Don't forcibly tear down/restart a working tunnel just because JIT arrived
# through stikjit://. If the DDI is already mounted, go straight to the fresh
# debug tunnel used for the actual attach.
replace_exact(
    "StikDebug/Views/HomeView.swift",
    """        if triggeredByURLScheme {
            markTunnelDisconnected()
            startTunnelInBackground(showErrorUI: false)
        }
""",
    """        if triggeredByURLScheme &&
            !TunnelManager.shared.isConnected &&
            !MountingProgress.shared.coolisMounted {
            startTunnelInBackground(showErrorUI: false)
        }
""",
    "external tunnel restart"
)

# 3) A mounted DDI persists until reboot. Requiring the long-lived UI tunnel to
# also report connected can reject an otherwise valid external JIT request.
replace_exact(
    "StikDebug/Views/HomeView.swift",
    """    private func waitForJITPrerequisites(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted {
                return true
            }
            usleep(250_000)
        }
        return TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted
    }
""",
    """    private func waitForJITPrerequisites(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Once the developer image is mounted, the debug session creates
            // its own fresh RSD tunnel. Don't gate that on the UI tunnel.
            if MountingProgress.shared.coolisMounted {
                return true
            }
            usleep(250_000)
        }
        return MountingProgress.shared.coolisMounted
    }
""",
    "JIT prerequisite wait"
)

# 4) Retry a transient PID attach once. iOS 27 has shown occasional E96 /
# NotConnected failures on the first fresh debug tunnel even with a valid
# pairing file and LocalDevVPN route.
replace_exact(
    "StikDebug/Views/HomeView.swift",
    """            var success: Bool
            if let pid {
                success = JITEnableContext.shared.debugApp(withPID: Int32(pid), logger: logger, jsCallback: callback)
            } else if let bundleID {
                success = JITEnableContext.shared.debugApp(withBundleID: bundleID, logger: logger, jsCallback: callback)
            } else {
                lastDebugMessage = "Either bundle ID or PID should be specified.".localized
                success = false
            }
""",
    """            var success: Bool
            if let pid {
                success = JITEnableContext.shared.debugApp(withPID: Int32(pid), logger: logger, jsCallback: callback)
                if !success {
                    LogManager.shared.addWarningLog("First PID attach failed; retrying once with a fresh debug tunnel")
                    usleep(350_000)
                    success = JITEnableContext.shared.debugApp(withPID: Int32(pid), logger: logger, jsCallback: callback)
                }
            } else if let bundleID {
                success = JITEnableContext.shared.debugApp(withBundleID: bundleID, logger: logger, jsCallback: callback)
            } else {
                lastDebugMessage = "Either bundle ID or PID should be specified.".localized
                success = false
            }
""",
    "PID attach retry"
)

# 5) The heartbeat helper used to wait forever for its startup tunnel. Keep the
# script flow recoverable if that auxiliary connection wedges.
replace_exact(
    "StikDebug/Device/JITEnableContext.swift",
    """            startupSemaphore.wait()
            if let startupError {
                throw startupError
            }
""",
    """            guard startupSemaphore.wait(timeout: .now() + .seconds(8)) == .success else {
                throw NSError(
                    domain: "StikDebug",
                    code: -31,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out starting the debug heartbeat"]
                )
            }
            if let startupError {
                throw startupError
            }
""",
    "heartbeat startup timeout"
)

print("StikDebug iOS 27 hardening patch applied successfully")
