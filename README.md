# Toolbox App — Wheelz controller

Flutter app with **Manual** and **Automatic** tabs for Wheelz.

- Manual: hold-to-drive controls, direct ESP sensor display, gyro-bias calibration,
  run IDs and the existing manual cloud-data logger.
- Automatic: pair with the ROS PC, enter X/Y coordinates in metres, inspect
  position/readiness/navigation status, and Navigate or Cancel/Stop.
- While paired, both tabs use the ROS host. Switching to Manual cancels autonomy.
- Cancel/Stop and error feedback remain visible while scrolling.
- The app never executes suggestions from the old cloud Auto endpoint.

The trained model runs on the PC in ROS, not on the phone. Install/build the
matching [Wheelz host](https://github.com/donovan-creator/Wheelz) and follow its
[app setup guide](https://github.com/donovan-creator/Wheelz/blob/main/ros2_ws/APP_SETUP.md)
for WSL launch, pairing token and phone-to-PC networking.

## Build and install

```powershell
cd toolbox_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Install `toolbox_app/build/app/outputs/flutter-apk/app-debug.apk` on an Android
phone, or use `flutter install --debug` with a connected phone. This is a local
development APK, not a store-signed release. No APK is committed to Git.

Android's manifest allows local HTTP and declares Internet permission.
iOS declares local-network access; an iOS build still requires macOS/Xcode and
has not been tested here.

## Operation

1. Start the ROS app host on your PC. Start with its simulated-hardware mode.
2. Open **Automatic**, enter the PC URL and generated pairing token, then connect.
3. Enter a goal such as X=1.0, Y=0.0. Coordinates are absolute in the odometry
   frame: initial forward +X, initial left +Y, in metres.
4. Press Navigate. Readiness requires fresh calibrated odometry; goals more than
   4 m away are rejected.
5. Use Cancel/Stop or switch to Manual to cancel. Paired manual control also
   travels through ROS. Stop and disconnect before returning to direct ESP mode.

The saved direct-control address is still `http://172.20.10.3` and is editable.
It may change with the hotspot. Do not run the ROS host while using direct mode:
its stop commands can compete with app commands.

Connection details and the pairing token are kept only for the current app
session. Navigation stops through the host when app heartbeats disappear.
Manual hold requests have their own short expiration. Monotonic request numbers
prevent a delayed movement request from superseding a newer stop.

The ESP firmware is unchanged and has no Wi-Fi-loss watchdog. A phone/host
acknowledgment does not prove physical standstill if the board is unreachable.
The model has no obstacle avoidance and needs physical calibration before use.

## Validation

Flutter analysis and widget/API-client tests cover coordinates, readiness,
navigation, stop and returning to Manual. The ROS repository tests the real
HTTP-to-ROS-to-emulated-ESP path, including authentication, command ordering,
session ownership and disconnect stopping. The Flutter web app was also operated
in a real browser against the ROS emulator, including a completed one-metre goal.
No physical robot was driven during testing.
