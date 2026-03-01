# WalkieTalkie

基于 ESP32-C6 + Flutter 的无线对讲机，SoftAP + UDP 通信，无需互联网。

## 功能

- 长按对讲，实时语音传输
- 音频文件远程播放，对讲可打断
- 静音控制
- 自动连接，断线重连
- Material 3 UI，深色模式

## 硬件

- ESP32-C6 × 1
- INMP441 麦克风模块
- MAX98357A I2S 功放 + 喇叭

### 接线

| ESP32-C6 | INMP441 | MAX98357A |
|----------|---------|-----------|
| GPIO2 | SCK | - |
| GPIO3 | WS | - |
| GPIO4 | SD | - |
| GPIO5 | - | BCLK |
| GPIO6 | - | LRC |
| GPIO7 | - | DIN |

## 使用

1. 烧录固件到 ESP32-C6
2. 安装 APK 到手机
3. 手机连接 WiFi `WalkieTalkie`（密码 `walkie1234`）
4. 打开 App，自动连接

## 构建

### 固件

```bash
cd firmware
pio run
pio run -t upload
```

### App

```bash
cd app
flutter pub get
flutter build apk --release
```

## 通信协议

SoftAP + UDP，端口 8888，自定义二进制协议，8 字节头 + 变长 payload。

## License

MIT
