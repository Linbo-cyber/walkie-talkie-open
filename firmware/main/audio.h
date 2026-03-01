#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

// I2S pin config
#define I2S_MIC_SCK     2
#define I2S_MIC_WS      3
#define I2S_MIC_SD      4
#define I2S_SPK_BCLK    5
#define I2S_SPK_LRC     6
#define I2S_SPK_DIN     7

// Audio params
#define AUDIO_SAMPLE_RATE   16000
#define AUDIO_CHANNELS      1
#define AUDIO_BITS          16
#define AUDIO_FRAME_MS      20
#define AUDIO_FRAME_SAMPLES (AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS / 1000)
#define AUDIO_FRAME_BYTES   (AUDIO_FRAME_SAMPLES * AUDIO_CHANNELS * (AUDIO_BITS / 8))

typedef enum {
    AUDIO_STATE_IDLE,
    AUDIO_STATE_STREAMING,
    AUDIO_STATE_PLAYING_FILE,
} audio_state_t;

esp_err_t audio_init(void);
esp_err_t audio_deinit(void);

// Speaker
esp_err_t audio_play_pcm(const int16_t *data, size_t samples);
esp_err_t audio_play_opus(const uint8_t *data, size_t len);
void audio_stop_playback(void);
void audio_set_mute(bool mute);
bool audio_is_muted(void);

// Microphone
esp_err_t audio_mic_read(int16_t *buf, size_t samples, size_t *bytes_read);
int audio_mic_encode_opus(const int16_t *pcm, size_t samples, uint8_t *out, size_t out_max);

// File playback buffer
esp_err_t audio_file_feed(const uint8_t *data, size_t len);
esp_err_t audio_file_play_start(void);
void audio_file_play_stop(void);

audio_state_t audio_get_state(void);

#endif // AUDIO_H
