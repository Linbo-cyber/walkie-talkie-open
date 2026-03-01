#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

// Packet types
#define PKT_AUDIO_STREAM    0x01  // Real-time voice data
#define PKT_AUDIO_FILE      0x02  // Audio file chunk
#define PKT_AUDIO_FILE_END  0x03  // Audio file transfer complete
#define PKT_CMD             0x04  // Command packet
#define PKT_STATUS          0x05  // Status response

// Commands
#define CMD_STOP_PLAYBACK   0x01  // Stop current playback
#define CMD_START_STREAM    0x02  // Start voice stream
#define CMD_STOP_STREAM     0x03  // Stop voice stream
#define CMD_MUTE            0x04  // Mute speaker
#define CMD_UNMUTE          0x05  // Unmute speaker
#define CMD_FILE_START      0x06  // Begin file transfer
#define CMD_PING            0x07  // Keepalive ping
#define CMD_PONG            0x08  // Keepalive pong

// Status codes
#define STATUS_OK           0x00
#define STATUS_PLAYING      0x01
#define STATUS_STREAMING    0x02
#define STATUS_IDLE         0x03
#define STATUS_ERROR        0xFF

// Protocol limits
#define MAX_PACKET_SIZE     1400
#define HEADER_SIZE         8
#define MAX_PAYLOAD_SIZE    (MAX_PACKET_SIZE - HEADER_SIZE)
#define OPUS_FRAME_MS       20
#define SAMPLE_RATE         16000
#define CHANNELS            1
#define OPUS_BITRATE        16000

// Packet header: [type(1) | seq(2) | len(2) | flags(1) | reserved(2)]
typedef struct __attribute__((packed)) {
    uint8_t  type;
    uint16_t seq;
    uint16_t len;
    uint8_t  flags;
    uint16_t reserved;
} pkt_header_t;

typedef struct {
    pkt_header_t header;
    uint8_t payload[MAX_PAYLOAD_SIZE];
} packet_t;

// Build a packet
static inline size_t pkt_build(packet_t *pkt, uint8_t type, uint16_t seq,
                                const uint8_t *data, uint16_t len, uint8_t flags) {
    pkt->header.type = type;
    pkt->header.seq = seq;
    pkt->header.len = len;
    pkt->header.flags = flags;
    pkt->header.reserved = 0;
    if (data && len > 0) {
        memcpy(pkt->payload, data, len);
    }
    return HEADER_SIZE + len;
}

// Parse header from raw buffer
static inline int pkt_parse(const uint8_t *buf, size_t buf_len, pkt_header_t *hdr) {
    if (buf_len < HEADER_SIZE) return -1;
    memcpy(hdr, buf, HEADER_SIZE);
    if (hdr->len > MAX_PAYLOAD_SIZE) return -1;
    if (buf_len < (size_t)(HEADER_SIZE + hdr->len)) return -1;
    return 0;
}

#endif // PROTOCOL_H
