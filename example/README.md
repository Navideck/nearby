# Nearby example

Demonstrates connected peer discovery, authenticated sessions, byte/file/stream transfers, and connectionless UDP/BLE broadcasts.

Run with:

```bash
flutter run
```

Use the campaign button in the connected-session screen to open the broadcast demo.

## App icon generation

From this example directory, regenerate the approved launcher assets with:

```sh
dart pub global activate flutter_launcher_icons 0.14.4
dart pub global run flutter_launcher_icons -f flutter_launcher_icons.yaml
```

The standalone generator avoids changing the example app's SDK or package dependencies.
