# VectorJIT

Personal experimental fork of [StikDebug](https://github.com/StikDebug/StikDebug), an on-device debugger/JIT enabler for iOS 17.4+.

## Pairing-file rule

VectorJIT **does not split, trim, or rewrite the pairing record**. If the pairing file contains fields used for more than one purpose, the complete file is imported and kept intact. The JIT engine reads the fields it needs at runtime.

The pairing file stays on-device and is never committed to this repository.

## Build

GitHub Actions builds an unsigned IPA on a macOS 26 runner. Sign/install it with your own sideloading method.

This fork remains under the upstream AGPL-3.0 license.
