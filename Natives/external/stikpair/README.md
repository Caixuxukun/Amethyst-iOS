// StikPair - on-device pairing host, vendored from
// https://github.com/StikDebug/StikPair (commit 7c911d8319dc5bcc411bf299d963689e26009b0b),
// rust/ directory only.
//
// License: MIT, non-commercial. Free for personal/non-commercial use; for
// commercial use contact the StikPair author (see LICENSE and the upstream
// README). Amethyst ships this for its on-device pairing flow only.
//
// Build (in CI): rustup target add aarch64-apple-ios
//                cargo build --release --target aarch64-apple-ios
//
// The C interface is include/stikpair.h; Natives/jit/StikPairBridge.m wraps it
// for the launcher.
