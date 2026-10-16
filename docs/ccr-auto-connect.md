# iPad reconnects to its saved Mac

The iPad app previously started Bonjour browsing after launch but waited for a tap even when it had a valid pairing. A fresh process has no in-memory `Reconnect` value, so the existing lost-session retry path cannot make the first connection.

`SavedMacs.automaticTarget` selects a formally paired Mac with a valid fingerprint, recognition key, and TLS home door. Once the app has stored `Sill.preferredTrustedMacID`, it selects only that Mac. Older installs without a preference select the uniquely newest eligible pairing once. A missing, revoked, or changed preferred record leaves the app disconnected; it never selects a different Mac by name.

After `startRemote`, the iOS client arms one startup attempt. It waits for an exact network row whose Mac ID and recognition tag match the saved record. `homeDecision` must recognize the pinned TLS door. The dial uses the saved certificate fingerprint and the existing device key. A successful authenticated session records that Mac as the preference. Manual connection and disconnection stop the startup attempt. The app does not open pairing, generate a device key, or use a plain home door for this path.

This path uses the existing saved pairing instead of constructing a synthetic lost-session `Reconnect` value. That keeps initial selection separate from retries after an established session ends. It does not add a background poller. If the saved Mac is absent or its trust record is invalid, the normal Mac list remains available for an explicit user choice.

The pure saved-Mac policy checks cover explicit preference, older-record migration, invalid trust records, and ambiguous pairing order. A signed build was installed on the iPad Pro with bundle `com.ambrion.sillcanvas.ipad`. Two consecutive process relaunches connected to the separate `CCR Sill.app` Mac host without a tap or another pairing code. The Canvas scene file hash matched before and after installation. This verifies local automatic connection on that device and host; remote network recovery and another Apple device still need their own physical checks.
