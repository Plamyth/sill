# iPad keyboard viewport regression

```sh
python3 Tests/checks/ipad-keyboard-viewport/run.py /absolute/path/to/new-receipt
```

Runs one small Swift check under the Mini heavy gate, using temporary RAM input and isolated compiler output. No app, window, audio, network connection or device is opened. Hashes, source immutability and cleanup are recorded.

The check extracts the production safe-area modifier, Duo/landscape metrics, aspect-fit rectangle and input normalization function. It uses real SwiftUI `SafeAreaRegions` and a synthetic keyboard layout proposal (1194×834 window, top inset 24, docked keyboard beginning at y=482). It verifies that the complete picture/panel stays above the keyboard and that visible points retain their normalized Mac coordinates across frame aspect ratios. Hidden, hardware, floating and assistant-bar geometry are included. Phone keyboard-over-trackpad behavior stays unchanged.

The proposal model is not SwiftUI layout execution. Static integration assertions establish the shared video/input frame and measured viewport path; they do not prove animation, responder preservation, native menu placement or drawing UI behavior. The parent owns SDK build and physical keyboard show/hide, rotation and floating/hardware keyboard checks.
