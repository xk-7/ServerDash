# ServerDashMobile physical-device acceptance checklist

- Target: `ServerDashMobile`
- Minimum OS: iOS/iPadOS 18
- Current status: **not executed on a physical device**
- Simulator automation: iPhone 16e and iPad Air 11-inch (M3), 14/14 tests passed
- Local SSH integration: in-process Citadel test host validates password,
  imported Ed25519 key, host-key callback, stdout/stderr plus exit status, PTY
  Unicode input, and PTY resize on both simulator form factors.

## Connection and security

- [ ] Password authentication to a test SSH host.
- [ ] Imported unencrypted Ed25519 private key.
- [ ] Imported encrypted RSA private key and passphrase.
- [ ] Unknown host key pauses before authentication; reject closes the socket.
- [ ] Changed host key displays old and new fingerprints; reject preserves the
  stored key and approval replaces it only after confirmation.
- [ ] Command timeout and output-limit failures remain distinct.
- [ ] Device logs and exported diagnostics contain no password, passphrase,
  private-key body, command payload, or terminal session output.

## Terminal

- [ ] iPhone full-screen terminal with software-keyboard accessory actions.
- [ ] iPad terminal plus inspector in landscape and portrait.
- [ ] Hardware keyboard input, Command-key navigation, and pointer interaction.
- [ ] Chinese IME composition and wide-character rendering.
- [ ] Rotation and Split View resize update the remote PTY dimensions.
- [ ] Background entry closes the shell; foreground requires explicit reconnect
  and does not claim that the remote process survived.

## SFTP

- [ ] Browse, create, rename, move, and recursive delete.
- [ ] Upload and download through the Files picker/exporter.
- [ ] Overwrite, skip, and automatic-rename conflict choices.
- [ ] Cancel upload/download and retry from the beginning.
- [ ] Chinese, spaces, and special characters in names.
- [ ] Background entry closes transfer state without claiming success.

## Adaptive UI and accessibility

- [ ] iPhone portrait and landscape, including the smallest supported compact
  width used by the test fleet.
- [ ] iPad portrait/landscape, one-third and half Split View, and Stage Manager.
- [ ] Light and dark appearance plus Increase Contrast and Reduce Motion.
- [ ] Largest accessibility Dynamic Type sizes without clipped primary actions.
- [ ] VoiceOver can complete machine selection, trust confirmation, terminal
  reconnect, and SFTP download.
- [ ] All primary touch targets are at least 44 by 44 points.

Record device models, OS versions, SSH server versions, key algorithms, and any
failed rows before a physical-device build is considered release-ready.
