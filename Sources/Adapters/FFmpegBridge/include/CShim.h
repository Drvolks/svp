#ifndef CShim_h
#define CShim_h

#include <stdint.h>

typedef struct svp_ffmpeg_decoded_frame {
    int32_t width;
    int32_t height;
    int32_t linesizeY;
    int32_t linesizeUV;
    int64_t pts90k;
    uint8_t *planeY;
    uint8_t *planeUV;
} svp_ffmpeg_decoded_frame_t;

typedef struct svp_ffmpeg_stream_info {
    int32_t streamIndex;
    int32_t streamID;
    int32_t streamKind;
    int32_t codecID;
    int32_t timebaseNum;
    int32_t timebaseDen;
} svp_ffmpeg_stream_info_t;

typedef struct svp_ffmpeg_demuxed_packet {
    int32_t streamIndex;
    int32_t codecID;
    int32_t isKeyframe;
    int32_t hasPTS;
    int32_t hasDTS;
    int32_t hasDuration;
    int64_t pts;
    int64_t dts;
    int64_t duration;
    uint8_t *data;
    int32_t size;
    int32_t sideDataType;
    uint8_t *sideData;
    int32_t sideDataSize;
} svp_ffmpeg_demuxed_packet_t;

typedef struct svp_ffmpeg_codec_config {
    uint8_t *data;
    int32_t size;
} svp_ffmpeg_codec_config_t;

typedef struct svp_ffmpeg_decoded_audio_frame {
    int32_t sampleRate;
    int32_t channels;
    int32_t bytesPerSample;
    int64_t pts90k;
    uint8_t *data;
    int32_t size;
} svp_ffmpeg_decoded_audio_frame_t;

int32_t svp_ffmpeg_bridge_version(void);
int32_t svp_ffmpeg_bridge_can_decode_codec(int32_t codecID);
int32_t svp_ffmpeg_bridge_decode_video_packet(int32_t codecID, const uint8_t *data, int32_t length);
int32_t svp_ffmpeg_bridge_has_vendor_backend(void);
void *svp_ffmpeg_demuxer_create(const char *url);
void svp_ffmpeg_demuxer_destroy(void *demuxer);
int32_t svp_ffmpeg_demuxer_stream_count(void *demuxer);
int32_t svp_ffmpeg_demuxer_stream_info(void *demuxer, int32_t index, svp_ffmpeg_stream_info_t *outInfo);
int32_t svp_ffmpeg_demuxer_stream_codec_config(void *demuxer, int32_t index, svp_ffmpeg_codec_config_t *outConfig);
int32_t svp_ffmpeg_demuxer_read_packet(void *demuxer, svp_ffmpeg_demuxed_packet_t *outPacket);
int32_t svp_ffmpeg_demuxer_seek_seconds(void *demuxer, double seconds);
double svp_ffmpeg_demuxer_duration_seconds(void *demuxer);
void svp_ffmpeg_demuxed_packet_release(svp_ffmpeg_demuxed_packet_t *packet);
void svp_ffmpeg_codec_config_release(svp_ffmpeg_codec_config_t *config);
void *svp_ffmpeg_video_decoder_create(int32_t codecID);
void *svp_ffmpeg_video_decoder_create_with_extradata(int32_t codecID, const uint8_t *data, int32_t length);
void svp_ffmpeg_video_decoder_destroy(void *decoder);
int32_t svp_ffmpeg_video_decoder_flush(void *decoder);
int32_t svp_ffmpeg_video_decoder_decode(
    void *decoder,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k,
    int32_t sideDataType,
    const uint8_t *sideData,
    int32_t sideDataSize,
    svp_ffmpeg_decoded_frame_t *outFrame
);
void svp_ffmpeg_decoded_frame_release(svp_ffmpeg_decoded_frame_t *frame);
void *svp_ffmpeg_audio_decoder_create(int32_t codecID);
void *svp_ffmpeg_audio_decoder_create_with_extradata(int32_t codecID, const uint8_t *data, int32_t length);
void svp_ffmpeg_audio_decoder_destroy(void *decoder);
int32_t svp_ffmpeg_audio_decoder_flush(void *decoder);
int32_t svp_ffmpeg_audio_decoder_decode(
    void *decoder,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k,
    svp_ffmpeg_decoded_audio_frame_t *outFrame
);
int32_t svp_ffmpeg_audio_decoder_drain(
    void *decoder,
    svp_ffmpeg_decoded_audio_frame_t *outFrame
);
void svp_ffmpeg_decoded_audio_frame_release(svp_ffmpeg_decoded_audio_frame_t *frame);

#endif
