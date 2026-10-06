# AstroRescue v0.1

AstroRescue is a dedicated iPhone storage-rescue utility for safely offloading likely astrophotography from Apple Photos to an external USB drive.

## v0.1 workflow

1. Plug the USB drive into the iPhone.
2. Open AstroRescue and choose a destination folder on the USB.
3. Scan Apple Photos.
4. Review every likely astrophotography match.
5. Select the files to offload.
6. AstroRescue writes the original Photos resource to USB.
7. It independently hashes the Photos resource and the USB copy with SHA-256.
8. Only verified matches become eligible for deletion.
9. Deletion is always a separate explicit action and remains under iOS Photos control.

## Safety

- No automatic deletion.
- No generative image processing.
- No recompression or enhancement.
- Nothing in another app's private sandbox is accessed.
- v0.1 scans image assets in Apple Photos only.
- The future Smart Cleanup feature is intentionally not included until protected-document safeguards are added.

## Build

The GitHub Actions workflow produces:

AstroRescue-v0.1.0-unsigned.ipa

That IPA can then be signed with the user's normal iOS sideloading/signing method.
