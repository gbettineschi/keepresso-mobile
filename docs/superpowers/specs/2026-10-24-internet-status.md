# Mac internet status

Add one compact Internet / Wi-Fi (or Network) row below Battery / Temperature on Android. This describes the Mac, independently of Bluetooth/relay transport. Online requires a successful real HTTPS check; a usable route alone is insufficient. No route is Offline; failed public checks are Check failed, not proof that every internet destination is down. Checking and unknown remain distinct. Keep last-known treatment when the Mac is unreachable. No extra alerts or network controls.

Read the current Wi-Fi SSID through public CoreWLAN, never scan or infer it from saved networks. If macOS hides it, display Name unavailable. An optional Mac settings action requests Location permission only on the owner's click; never collect coordinates. Internet checks work without this permission.

Use small, uncached, credential-free HTTPS HEAD checks (Google's generate_204, Cloudflare fallback), rejecting redirects and unexpected responses. Check on a network change and at most every 15 seconds when snapshots are requested; expire results after 45 seconds. Bound requests, coalesce concurrent reads, discard late results after path changes/stop, reset on sleep/wake. No additional periodic timer, wake assertion, permanent trigger observer or server change. Explain the endpoint limitation in documentation.

Preserve pairing, encryption, command deduplication and backwards compatibility. Official Keepresso and pinned source unchanged. Test interpreted state, probe failures/fallback, malformed snapshots and emulator UI, including offline Wi-Fi, hidden/long SSID and stale status. Package the update but DO NOT install on the owner's Mac or phone until explicit approval.
