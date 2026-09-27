# Distribute outside the Mac App Store, without App Sandbox

Mac Pulse ships as a Developer ID–signed, notarized app with hardened runtime and no App Sandbox. The sandbox restricts `proc_pidinfo`/`task_info` for other users' and system processes (incomplete process list and top-process attribution), and blocks the Phase 3 features that read the Docker socket, listening ports, and proxy/VPN configuration. We give up App Store discovery and store-managed updates (Sparkle will handle updates) in exchange for complete system visibility — the same trade other tools in this category make.
