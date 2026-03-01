#include "audio.h"
#include "protocol.h"
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/ringbuf.h"
#include "driver/i2s_std.h"
#include "esp_log.h"

static const char *TAG = "audio";

static i2s_chan_handle_t rx_chan = NULL; // mic
static i2s_chan_handle_t tx_chan = NULL; // speaker
static bool muted = false;
static volatile audio_state_t state = AUDIO_STATE_IDLE;
static RingbufHandle_t file_ringbuf = NULL;
static volatile bool file_playing = false;
static TaskHandle_t file_task_handle = NULL;

esp_err_t audio_init(void) {
    // ESP32-C6 has 1 I2S controller — allocate both TX and RX from it
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    chan_cfg.dma_desc_num = 8;
    chan_cfg.dma_frame_num = 240;
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_chan, &rx_chan));

    // --- Speaker (TX) ---
    i2s_std_config_t tx_std = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(AUDIO_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = (gpio_num_t)I2S_SPK_BCLK,
            .ws = (gpio_num_t)I2S_SPK_LRC,
            .dout = (gpio_num_t)I2S_SPK_DIN,
            .din = (gpio_num_t)I2S_MIC_SD,
            .invert_flags = { .mclk_inv = false, .bclk_inv = false, .ws_inv = false },
        },
    };
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx_chan, &tx_std));
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx_chan, &tx_std));
    ESP_ERROR_CHECK(i2s_channel_enable(tx_chan));
    ESP_ERROR_CHECK(i2s_channel_enable(rx_chan));

    // --- File playback ring buffer (64KB) ---
    file_ringbuf = xRingbufferCreate(65536, RINGBUF_TYPE_BYTEBUF);
    if (!file_ringbuf) {
        ESP_LOGE(TAG, "Ring buffer create failed");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Audio initialized (raw PCM, single I2S)");
    return ESP_OK;
}

esp_err_t audio_deinit(void) {
    audio_file_play_stop();
    if (tx_chan) { i2s_channel_disable(tx_chan); }
    if (rx_chan) { i2s_channel_disable(rx_chan); }
    if (tx_chan) { i2s_del_channel(tx_chan); tx_chan = NULL; }
    if (rx_chan) { i2s_del_channel(rx_chan); rx_chan = NULL; }
    if (file_ringbuf) { vRingbufferDelete(file_ringbuf); file_ringbuf = NULL; }
    return ESP_OK;
}

esp_err_t audio_play_pcm(const int16_t *data, size_t samples) {
    if (muted || !tx_chan) return ESP_OK;
    size_t bytes = samples * sizeof(int16_t);
    size_t written = 0;
    return i2s_channel_write(tx_chan, data, bytes, &written, pdMS_TO_TICKS(100));
}

void audio_stop_playback(void) {
    audio_file_play_stop();
    state = AUDIO_STATE_IDLE;
}

void audio_set_mute(bool m) { muted = m; }
bool audio_is_muted(void) { return muted; }

esp_err_t audio_mic_read(int16_t *buf, size_t samples, size_t *bytes_read) {
    if (!rx_chan) return ESP_FAIL;
    size_t want = samples * sizeof(int16_t);
    return i2s_channel_read(rx_chan, buf, want, bytes_read, pdMS_TO_TICKS(100));
}

esp_err_t audio_file_feed(const uint8_t *data, size_t len) {
    if (!file_ringbuf) return ESP_FAIL;
    if (xRingbufferSend(file_ringbuf, data, len, pdMS_TO_TICKS(50)) != pdTRUE) {
        ESP_LOGW(TAG, "File ringbuf full, dropping");
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

static void file_play_task(void *arg) {
    ESP_LOGI(TAG, "File playback started");
    state = AUDIO_STATE_PLAYING_FILE;

    while (file_playing) {
        size_t item_size = 0;
        uint8_t *data = (uint8_t *)xRingbufferReceiveUpTo(file_ringbuf, &item_size,
                                                            pdMS_TO_TICKS(200),
                                                            AUDIO_FRAME_BYTES);
        if (data && item_size > 0) {
            audio_play_pcm((const int16_t *)data, item_size / sizeof(int16_t));
            vRingbufferReturnItem(file_ringbuf, data);
        } else if (!file_playing) {
            break;
        }
    }

    state = AUDIO_STATE_IDLE;
    file_task_handle = NULL;
    ESP_LOGI(TAG, "File playback stopped");
    vTaskDelete(NULL);
}

esp_err_t audio_file_play_start(void) {
    if (file_playing) return ESP_OK;
    file_playing = true;
    xTaskCreate(file_play_task, "file_play", 8192, NULL, 5, &file_task_handle);
    return ESP_OK;
}

void audio_file_play_stop(void) {
    file_playing = false;
    if (file_task_handle) {
        for (int i = 0; i < 50 && file_task_handle; i++) {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
    if (file_ringbuf) {
        size_t sz;
        void *item;
        while ((item = xRingbufferReceive(file_ringbuf, &sz, 0)) != NULL) {
            vRingbufferReturnItem(file_ringbuf, item);
        }
    }
}

audio_state_t audio_get_state(void) { return state; }
