#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"

#include "audio.h"
#include "protocol.h"

static const char *TAG = "main";

#define WIFI_SSID       "WalkieTalkie"
#define WIFI_PASS       "walkie1234"
#define WIFI_CHANNEL    1
#define WIFI_MAX_CONN   1
#define UDP_PORT        8888
#define MIC_TASK_STACK  8192
#define UDP_TASK_STACK  8192
// 客户端超时：10秒没收到任何包就断开
#define CLIENT_TIMEOUT_MS  10000

static int udp_sock = -1;
static struct sockaddr_in client_addr;
static socklen_t client_addr_len = 0;
static volatile bool client_connected = false;
static uint16_t tx_seq = 0;
static volatile TickType_t last_rx_tick = 0; // 最后收到包的时间

// ── WiFi SoftAP ──

static void wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT) {
        if (id == WIFI_EVENT_AP_STACONNECTED) {
            ESP_LOGI(TAG, "Client connected");
        } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
            ESP_LOGI(TAG, "Client disconnected");
            client_connected = false;
        }
    }
}

static void wifi_init_softap(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                         &wifi_event_handler, NULL, NULL));

    wifi_config_t wifi_cfg = {
        .ap = {
            .ssid = WIFI_SSID,
            .ssid_len = strlen(WIFI_SSID),
            .channel = WIFI_CHANNEL,
            .password = WIFI_PASS,
            .max_connection = WIFI_MAX_CONN,
            .authmode = WIFI_AUTH_WPA2_PSK,
            .pmf_cfg = { .required = false },
        },
    };

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    esp_wifi_set_max_tx_power(80); // 20dBm
    esp_wifi_set_protocol(WIFI_IF_AP, WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G | WIFI_PROTOCOL_11N);

    ESP_LOGI(TAG, "SoftAP started: SSID=%s PASS=%s CH=%d", WIFI_SSID, WIFI_PASS, WIFI_CHANNEL);
}

// ── UDP ──

static void udp_send_pkt(uint8_t type, const uint8_t *data, uint16_t len, uint8_t flags) {
    if (!client_connected || udp_sock < 0) return;
    packet_t pkt;
    size_t total = pkt_build(&pkt, type, tx_seq++, data, len, flags);
    sendto(udp_sock, &pkt, total, 0, (struct sockaddr *)&client_addr, client_addr_len);
}

static void udp_send_status(uint8_t status_code) {
    udp_send_pkt(PKT_STATUS, &status_code, 1, 0);
}

static void handle_command(uint8_t cmd) {
    switch (cmd) {
        case CMD_STOP_PLAYBACK:
            audio_stop_playback();
            udp_send_status(STATUS_OK);
            break;
        case CMD_START_STREAM:
            audio_stop_playback();
            udp_send_status(STATUS_OK);
            break;
        case CMD_STOP_STREAM:
            udp_send_status(STATUS_OK);
            break;
        case CMD_MUTE:
            audio_set_mute(true);
            udp_send_status(STATUS_OK);
            break;
        case CMD_UNMUTE:
            audio_set_mute(false);
            udp_send_status(STATUS_OK);
            break;
        case CMD_FILE_START:
            audio_stop_playback();
            audio_file_play_start();
            udp_send_status(STATUS_OK);
            break;
        case CMD_PING:
            udp_send_pkt(PKT_CMD, (uint8_t[]){CMD_PONG}, 1, 0);
            break;
        default:
            ESP_LOGW(TAG, "Unknown command: 0x%02x", cmd);
            break;
    }
}

static void handle_packet(const uint8_t *buf, size_t len, struct sockaddr_in *from, socklen_t from_len) {
    pkt_header_t hdr;
    if (pkt_parse(buf, len, &hdr) != 0) return;

    // 更新最后收包时间
    last_rx_tick = xTaskGetTickCount();

    // 注册/更新客户端
    if (!client_connected || memcmp(&client_addr, from, sizeof(struct sockaddr_in)) != 0) {
        memcpy(&client_addr, from, sizeof(struct sockaddr_in));
        client_addr_len = from_len;
        client_connected = true;
        ESP_LOGI(TAG, "Client registered");
    }

    const uint8_t *payload = buf + HEADER_SIZE;

    switch (hdr.type) {
        case PKT_AUDIO_STREAM:
            if (audio_get_state() == AUDIO_STATE_PLAYING_FILE) {
                audio_stop_playback();
            }
            audio_play_pcm((const int16_t *)payload, hdr.len / sizeof(int16_t));
            break;
        case PKT_AUDIO_FILE:
            audio_file_feed(payload, hdr.len);
            break;
        case PKT_AUDIO_FILE_END:
            ESP_LOGI(TAG, "File transfer complete");
            break;
        case PKT_CMD:
            if (hdr.len >= 1) handle_command(payload[0]);
            break;
        default:
            ESP_LOGW(TAG, "Unknown packet type: 0x%02x", hdr.type);
            break;
    }
}

static void udp_rx_task(void *arg) {
    uint8_t buf[MAX_PACKET_SIZE];
    struct sockaddr_in from;
    socklen_t from_len;

    while (1) {
        from_len = sizeof(from);
        int n = recvfrom(udp_sock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &from_len);
        if (n > 0) {
            handle_packet(buf, n, &from, from_len);
        }
    }
}

// 客户端超时检测任务
static void watchdog_task(void *arg) {
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(2000));
        if (client_connected && last_rx_tick > 0) {
            TickType_t now = xTaskGetTickCount();
            uint32_t elapsed_ms = (now - last_rx_tick) * portTICK_PERIOD_MS;
            if (elapsed_ms > CLIENT_TIMEOUT_MS) {
                ESP_LOGI(TAG, "Client timeout, disconnecting");
                client_connected = false;
                last_rx_tick = 0;
                audio_stop_playback();
            }
        }
    }
}

// ── Microphone capture → send to phone ──

static void mic_task(void *arg) {
    int16_t pcm[AUDIO_FRAME_SAMPLES];

    while (1) {
        size_t bytes_read = 0;
        esp_err_t err = audio_mic_read(pcm, AUDIO_FRAME_SAMPLES, &bytes_read);
        if (err != ESP_OK || bytes_read == 0) {
            vTaskDelay(pdMS_TO_TICKS(5));
            continue;
        }
        // 只有客户端连接且没在播放文件时才发麦克风数据
        if (client_connected && audio_get_state() != AUDIO_STATE_PLAYING_FILE) {
            udp_send_pkt(PKT_AUDIO_STREAM, (const uint8_t *)pcm, bytes_read, 0);
        }
    }
}

// ── Main ──

void app_main(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    ESP_ERROR_CHECK(audio_init());
    wifi_init_softap();

    udp_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (udp_sock < 0) {
        ESP_LOGE(TAG, "Socket create failed");
        return;
    }

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(UDP_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(udp_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "Socket bind failed");
        close(udp_sock);
        return;
    }

    ESP_LOGI(TAG, "UDP listening on port %d", UDP_PORT);

    xTaskCreate(udp_rx_task,   "udp_rx",   UDP_TASK_STACK, NULL, 6, NULL);
    xTaskCreate(mic_task,      "mic",       MIC_TASK_STACK, NULL, 5, NULL);
    xTaskCreate(watchdog_task, "watchdog",  2048,           NULL, 3, NULL);

    ESP_LOGI(TAG, "WalkieTalkie ready");
}
