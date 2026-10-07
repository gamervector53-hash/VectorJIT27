# VectorJIT27

VectorJIT27 is a full StikDebug-based build focused on reliable on-device JIT workflows on newer iOS releases, including the iOS 27.2 tunnel changes being tested in this repository.

## Why this build exists

The iOS 27.2 failure reported upstream as missing field public_key exposed two different pairing formats that were being treated as the same file:

- A classic MobileDevice pairing record contains lockdown certificates and host keys and is commonly exported by pairing tools.
- An RPPairing identity is used by Apple's newer remote-pairing/tunnel protocol. The idevice library expects a plist containing a 32-byte public_key, a 32-byte private_key, an identifier, and optionally a 16-byte alt_irk.

Feeding the first format to rp_pairing_file_read cannot work because it is not an RPPairing record.

## VectorJIT27 design

VectorJIT27 separates the two formats. Imported classic records are preserved intact, while the app keeps its own RPPairing identity in Application Support. If no valid RPPairing identity exists, it is generated with rp_pairing_file_generate.

The tunnel path uses that record with tunnel_create_rppairing. Because the library can update the record during pair-setup, VectorJIT27 persists it after every tunnel attempt, including attempts where pairing succeeds but the later TLS tunnel step fails. The alt_irk learned during pairing therefore survives the retry.

The app also invalidates stale adapter/handshake handles when the tunnel is marked disconnected and performs bounded retries for transient socket/TLS failures. Invalid remote records are quarantined rather than silently reused.

## Storage

- Application Support/Pairing/rp_pairing_file.plist — canonical RPPairing identity used by the tunnel.
- Application Support/Pairing/classic_pairing_file.plist — preserved imported classic MobileDevice record.
- Application Support/Pairing/Invalid/ — quarantined malformed remote records.

Pairing files are written with owner-only 0600 permissions where the platform supports POSIX permissions.

## Build

The GitHub Actions workflow produces a Release-configured unsigned IPA on a macOS 26 runner. The IPA is intended to be signed by the user's own sideloading/signing workflow.

The build verifies the RPPairing generation/persistence source path, archives the complete app, validates the packaged Info.plist and executable, generates a SHA-256 digest, uploads an artifact, and publishes a prerelease.

## iOS 27.2 status

This build fixes the application-side missing field public_key class of failure by ensuring the tunnel never consumes a classic pairing plist as an RPPairing file. It also preserves pairing updates across a later TLS timeout.

A successful cloud build proves the source compiles and packages. Actual iOS 27.2 tunnel/JIT behavior still requires device testing because the LocalDevVPN route and Apple's runtime remote-pairing behavior cannot be exercised by GitHub Actions.
