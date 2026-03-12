#include "CShim.h"

#include <stdlib.h>
#include <string.h>
#if __has_include(<TargetConditionals.h>)
#include <TargetConditionals.h>
#endif

#if __has_include(<libavcodec/avcodec.h>) && __has_include(<libavformat/avformat.h>) && __has_include(<libavutil/imgutils.h>) && __has_include(<libswscale/swscale.h>)
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#define SVP_HAS_VENDOR_FFMPEG 1
#else
#define SVP_HAS_VENDOR_FFMPEG 0
#endif

#if SVP_HAS_VENDOR_FFMPEG
struct svp_ffmpeg_demuxer {
    AVFormatContext *format_ctx;
    AVBSFContext **bsf_by_stream;
    int32_t bsf_count;
};

struct svp_ffmpeg_video_decoder {
    enum AVCodecID codec_id;
    AVCodecContext *codec_ctx;
    AVFrame *frame;
    struct SwsContext *sws_ctx;
};

struct svp_ffmpeg_audio_decoder {
    enum AVCodecID codec_id;
    AVCodecContext *codec_ctx;
    AVFrame *frame;
    SwrContext *swr_ctx;
    int out_sample_rate;
    enum AVSampleFormat out_format;
    AVChannelLayout out_ch_layout;
    uint8_t *pending_packet_data;
    int32_t pending_packet_length;
    int64_t pending_packet_pts90k;
};
#endif

static int32_t map_ffmpeg_codec_to_bridge(int codecID) {
#if SVP_HAS_VENDOR_FFMPEG
    switch (codecID) {
        case AV_CODEC_ID_H264: return 1;
        case AV_CODEC_ID_HEVC: return 2;
        case AV_CODEC_ID_AAC: return 3;
        case AV_CODEC_ID_OPUS: return 4;
        case AV_CODEC_ID_AC3: return 5;
        case AV_CODEC_ID_EAC3: return 6;
        default: return 0;
    }
#else
    (void)codecID;
    return 0;
#endif
}

static int32_t map_ffmpeg_media_type_to_bridge(int mediaType) {
#if SVP_HAS_VENDOR_FFMPEG
    switch (mediaType) {
        case AVMEDIA_TYPE_VIDEO: return 1;
        case AVMEDIA_TYPE_AUDIO: return 2;
        case AVMEDIA_TYPE_SUBTITLE: return 3;
        default: return 0;
    }
#else
    (void)mediaType;
    return 0;
#endif
}

static int map_codec_id(int32_t codecID) {
#if SVP_HAS_VENDOR_FFMPEG
    switch (codecID) {
        case 1: return AV_CODEC_ID_H264;
        case 2: return AV_CODEC_ID_HEVC;
        case 3: return AV_CODEC_ID_AAC;
        case 4: return AV_CODEC_ID_OPUS;
        case 5: return AV_CODEC_ID_AC3;
        case 6: return AV_CODEC_ID_EAC3;
        default: return AV_CODEC_ID_NONE;
    }
#else
    (void)codecID;
    return 0;
#endif
}

static int32_t preferred_output_channels(int32_t inputChannels) {
#if defined(TARGET_OS_TV) && TARGET_OS_TV
    if (inputChannels >= 6) {
        return 6; // keep 5.1 when available on tvOS
    }
    if (inputChannels > 0) {
        return inputChannels;
    }
    return 2;
#else
    (void)inputChannels;
    return 2; // force stereo on iOS/macOS for compatibility
#endif
}

int32_t svp_ffmpeg_bridge_version(void) {
#if SVP_HAS_VENDOR_FFMPEG
    return (int32_t)avcodec_version();
#else
    return 1;
#endif
}

int32_t svp_ffmpeg_bridge_can_decode_codec(int32_t codecID) {
#if SVP_HAS_VENDOR_FFMPEG
    const int ffCodecID = map_codec_id(codecID);
    if (ffCodecID == AV_CODEC_ID_NONE) {
        return 0;
    }
    return avcodec_find_decoder(ffCodecID) != NULL ? 1 : 0;
#else
    if (codecID == 1 || codecID == 2) {
        return 1;
    }
    return 0;
#endif
}

int32_t svp_ffmpeg_bridge_decode_video_packet(int32_t codecID, const uint8_t *data, int32_t length) {
#if SVP_HAS_VENDOR_FFMPEG
    const int ffCodecID = map_codec_id(codecID);
    if (ffCodecID == AV_CODEC_ID_NONE) {
        return -1;
    }
    if (avcodec_find_decoder(ffCodecID) == NULL) {
        return -2;
    }
    (void)data;
    (void)length;
    return 0;
#else
    (void)codecID;
    (void)data;
    (void)length;
    return -38;
#endif
}

int32_t svp_ffmpeg_bridge_has_vendor_backend(void) {
    return SVP_HAS_VENDOR_FFMPEG;
}

#if SVP_HAS_VENDOR_FFMPEG
static void free_demuxer(struct svp_ffmpeg_demuxer *demuxer) {
    int32_t i;
    if (demuxer == NULL) {
        return;
    }
    if (demuxer->bsf_by_stream != NULL) {
        for (i = 0; i < demuxer->bsf_count; i++) {
            if (demuxer->bsf_by_stream[i] != NULL) {
                av_bsf_free(&demuxer->bsf_by_stream[i]);
            }
        }
        free(demuxer->bsf_by_stream);
        demuxer->bsf_by_stream = NULL;
        demuxer->bsf_count = 0;
    }
    if (demuxer->format_ctx != NULL) {
        avformat_close_input(&demuxer->format_ctx);
    }
    free(demuxer);
}

static int init_bitstream_filters(struct svp_ffmpeg_demuxer *demuxer) {
    int32_t streamCount;
    int32_t i;

    if (demuxer == NULL || demuxer->format_ctx == NULL) {
        return -1;
    }

    streamCount = (int32_t)demuxer->format_ctx->nb_streams;
    if (streamCount <= 0) {
        return 0;
    }

    demuxer->bsf_by_stream = (AVBSFContext **)calloc((size_t)streamCount, sizeof(AVBSFContext *));
    if (demuxer->bsf_by_stream == NULL) {
        return -2;
    }
    demuxer->bsf_count = streamCount;

    for (i = 0; i < streamCount; i++) {
        AVStream *stream = demuxer->format_ctx->streams[i];
        AVCodecParameters *codecPar = stream->codecpar;
        const char *filterName = NULL;
        const AVBitStreamFilter *filter = NULL;
        AVBSFContext *bsf = NULL;

        if (codecPar == NULL || codecPar->codec_type != AVMEDIA_TYPE_VIDEO) {
            continue;
        }
        if (codecPar->codec_id == AV_CODEC_ID_H264) {
            filterName = "h264_mp4toannexb";
        } else if (codecPar->codec_id == AV_CODEC_ID_HEVC) {
            filterName = "hevc_mp4toannexb";
        } else {
            continue;
        }

        filter = av_bsf_get_by_name(filterName);
        if (filter == NULL) {
            continue;
        }
        if (av_bsf_alloc(filter, &bsf) < 0 || bsf == NULL) {
            continue;
        }
        if (avcodec_parameters_copy(bsf->par_in, codecPar) < 0) {
            av_bsf_free(&bsf);
            continue;
        }
        bsf->time_base_in = stream->time_base;
        if (av_bsf_init(bsf) < 0) {
            av_bsf_free(&bsf);
            continue;
        }
        demuxer->bsf_by_stream[i] = bsf;
    }

    return 0;
}

static int filter_packet_if_needed(struct svp_ffmpeg_demuxer *demuxer, AVPacket *packet) {
    AVBSFContext *bsf;
    int ret;

    if (demuxer == NULL || packet == NULL) {
        return -1;
    }
    if (demuxer->bsf_by_stream == NULL || packet->stream_index < 0 || packet->stream_index >= demuxer->bsf_count) {
        return 0;
    }

    bsf = demuxer->bsf_by_stream[packet->stream_index];
    if (bsf == NULL) {
        return 0;
    }

    ret = av_bsf_send_packet(bsf, packet);
    if (ret < 0) {
        return ret;
    }

    av_packet_unref(packet);
    ret = av_bsf_receive_packet(bsf, packet);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return 0;
    }
    return ret;
}
#endif

void *svp_ffmpeg_demuxer_create(const char *url) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer;
    AVFormatContext *formatCtx = NULL;

    if (url == NULL) {
        return NULL;
    }

    avformat_network_init();

    if (avformat_open_input(&formatCtx, url, NULL, NULL) < 0) {
        return NULL;
    }
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        avformat_close_input(&formatCtx);
        return NULL;
    }

    demuxer = (struct svp_ffmpeg_demuxer *)calloc(1, sizeof(struct svp_ffmpeg_demuxer));
    if (demuxer == NULL) {
        avformat_close_input(&formatCtx);
        return NULL;
    }
    demuxer->format_ctx = formatCtx;
    if (init_bitstream_filters(demuxer) < 0) {
        free_demuxer(demuxer);
        return NULL;
    }
    return demuxer;
#else
    (void)url;
    return NULL;
#endif
}

void svp_ffmpeg_demuxer_destroy(void *demuxerHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    free_demuxer(demuxer);
#else
    (void)demuxerHandle;
#endif
}

int32_t svp_ffmpeg_demuxer_stream_count(void *demuxerHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    if (demuxer == NULL || demuxer->format_ctx == NULL) {
        return -1;
    }
    return (int32_t)demuxer->format_ctx->nb_streams;
#else
    (void)demuxerHandle;
    return -38;
#endif
}

int32_t svp_ffmpeg_demuxer_stream_info(void *demuxerHandle, int32_t index, svp_ffmpeg_stream_info_t *outInfo) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    AVStream *stream;
    AVCodecParameters *codecPar;

    if (demuxer == NULL || demuxer->format_ctx == NULL || outInfo == NULL) {
        return -1;
    }
    if (index < 0 || index >= (int32_t)demuxer->format_ctx->nb_streams) {
        return -2;
    }

    stream = demuxer->format_ctx->streams[index];
    codecPar = stream->codecpar;
    memset(outInfo, 0, sizeof(*outInfo));
    outInfo->streamIndex = index;
    outInfo->streamID = stream->id;
    outInfo->streamKind = map_ffmpeg_media_type_to_bridge(codecPar->codec_type);
    outInfo->codecID = map_ffmpeg_codec_to_bridge(codecPar->codec_id);
    outInfo->timebaseNum = stream->time_base.num;
    outInfo->timebaseDen = stream->time_base.den;
    return 0;
#else
    (void)demuxerHandle;
    (void)index;
    (void)outInfo;
    return -38;
#endif
}

int32_t svp_ffmpeg_demuxer_read_packet(void *demuxerHandle, svp_ffmpeg_demuxed_packet_t *outPacket) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    AVPacket *packet;
    AVStream *stream;
    AVCodecParameters *codecPar;
    int readStatus;

    if (demuxer == NULL || demuxer->format_ctx == NULL || outPacket == NULL) {
        return -1;
    }
    memset(outPacket, 0, sizeof(*outPacket));

    packet = av_packet_alloc();
    if (packet == NULL) {
        return -2;
    }

    while (1) {
        readStatus = av_read_frame(demuxer->format_ctx, packet);
        if (readStatus == AVERROR_EOF) {
            av_packet_free(&packet);
            return 0;
        }
        if (readStatus < 0) {
            av_packet_free(&packet);
            return readStatus;
        }

        readStatus = filter_packet_if_needed(demuxer, packet);
        if (readStatus < 0) {
            av_packet_free(&packet);
            return readStatus;
        }
        if (packet->size > 0 && packet->data != NULL) {
            break;
        }
        av_packet_unref(packet);
    }

    stream = demuxer->format_ctx->streams[packet->stream_index];
    codecPar = stream->codecpar;

    outPacket->streamIndex = packet->stream_index;
    outPacket->codecID = map_ffmpeg_codec_to_bridge(codecPar->codec_id);
    outPacket->isKeyframe = (packet->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
    outPacket->hasPTS = packet->pts != AV_NOPTS_VALUE ? 1 : 0;
    outPacket->hasDTS = packet->dts != AV_NOPTS_VALUE ? 1 : 0;
    outPacket->hasDuration = packet->duration > 0 ? 1 : 0;
    outPacket->pts = packet->pts;
    outPacket->dts = packet->dts;
    outPacket->duration = packet->duration;
    outPacket->size = packet->size;

    if (packet->size > 0) {
        outPacket->data = (uint8_t *)malloc((size_t)packet->size);
        if (outPacket->data == NULL) {
            av_packet_free(&packet);
            return -3;
        }
        memcpy(outPacket->data, packet->data, (size_t)packet->size);
    }

    av_packet_free(&packet);
    return 1;
#else
    (void)demuxerHandle;
    (void)outPacket;
    return -38;
#endif
}

int32_t svp_ffmpeg_demuxer_seek_seconds(void *demuxerHandle, double seconds) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    int64_t ts;
    int ret;
    if (demuxer == NULL || demuxer->format_ctx == NULL) {
        return -1;
    }
    ts = (int64_t)(seconds * (double)AV_TIME_BASE);
    ret = av_seek_frame(demuxer->format_ctx, -1, ts, AVSEEK_FLAG_BACKWARD);
    if (ret >= 0) {
        int32_t i;
        avformat_flush(demuxer->format_ctx);
        if (demuxer->bsf_by_stream != NULL) {
            for (i = 0; i < demuxer->bsf_count; i++) {
                if (demuxer->bsf_by_stream[i] != NULL) {
                    av_bsf_flush(demuxer->bsf_by_stream[i]);
                }
            }
        }
    }
    return ret;
#else
    (void)demuxerHandle;
    (void)seconds;
    return -38;
#endif
}

double svp_ffmpeg_demuxer_duration_seconds(void *demuxerHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_demuxer *demuxer = (struct svp_ffmpeg_demuxer *)demuxerHandle;
    if (demuxer == NULL || demuxer->format_ctx == NULL) {
        return -1.0;
    }
    if (demuxer->format_ctx->duration <= 0) {
        return -1.0;
    }
    return (double)demuxer->format_ctx->duration / (double)AV_TIME_BASE;
#else
    (void)demuxerHandle;
    return -1.0;
#endif
}

void svp_ffmpeg_demuxed_packet_release(svp_ffmpeg_demuxed_packet_t *packet) {
    if (packet == NULL) {
        return;
    }
    if (packet->data != NULL) {
        free(packet->data);
        packet->data = NULL;
    }
    packet->size = 0;
}

#if SVP_HAS_VENDOR_FFMPEG
static void free_decoder(struct svp_ffmpeg_video_decoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->sws_ctx != NULL) {
        sws_freeContext(decoder->sws_ctx);
        decoder->sws_ctx = NULL;
    }
    if (decoder->frame != NULL) {
        av_frame_free(&decoder->frame);
    }
    if (decoder->codec_ctx != NULL) {
        avcodec_free_context(&decoder->codec_ctx);
    }
    free(decoder);
}
#endif

void *svp_ffmpeg_video_decoder_create(int32_t codecID) {
#if SVP_HAS_VENDOR_FFMPEG
    const int ffCodecID = map_codec_id(codecID);
    const AVCodec *codec;
    struct svp_ffmpeg_video_decoder *decoder;

    if (ffCodecID == AV_CODEC_ID_NONE) {
        return NULL;
    }
    codec = avcodec_find_decoder(ffCodecID);
    if (codec == NULL) {
        return NULL;
    }

    decoder = (struct svp_ffmpeg_video_decoder *)calloc(1, sizeof(struct svp_ffmpeg_video_decoder));
    if (decoder == NULL) {
        return NULL;
    }
    decoder->codec_id = ffCodecID;
    decoder->codec_ctx = avcodec_alloc_context3(codec);
    if (decoder->codec_ctx == NULL) {
        free_decoder(decoder);
        return NULL;
    }
    decoder->codec_ctx->thread_count = 0;
    decoder->codec_ctx->thread_type = FF_THREAD_FRAME;

    if (avcodec_open2(decoder->codec_ctx, codec, NULL) < 0) {
        free_decoder(decoder);
        return NULL;
    }

    decoder->frame = av_frame_alloc();
    if (decoder->frame == NULL) {
        free_decoder(decoder);
        return NULL;
    }

    return decoder;
#else
    (void)codecID;
    return NULL;
#endif
}

void svp_ffmpeg_video_decoder_destroy(void *decoderHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_video_decoder *decoder = (struct svp_ffmpeg_video_decoder *)decoderHandle;
    free_decoder(decoder);
#else
    (void)decoderHandle;
#endif
}

int32_t svp_ffmpeg_video_decoder_flush(void *decoderHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_video_decoder *decoder = (struct svp_ffmpeg_video_decoder *)decoderHandle;
    if (decoder == NULL || decoder->codec_ctx == NULL) {
        return -1;
    }
    avcodec_flush_buffers(decoder->codec_ctx);
    return 0;
#else
    (void)decoderHandle;
    return -38;
#endif
}

void svp_ffmpeg_decoded_frame_release(svp_ffmpeg_decoded_frame_t *frame) {
    if (frame == NULL) {
        return;
    }
    if (frame->planeY != NULL) {
        free(frame->planeY);
        frame->planeY = NULL;
    }
    if (frame->planeUV != NULL) {
        free(frame->planeUV);
        frame->planeUV = NULL;
    }
    frame->width = 0;
    frame->height = 0;
    frame->linesizeY = 0;
    frame->linesizeUV = 0;
    frame->pts90k = 0;
}

#if SVP_HAS_VENDOR_FFMPEG
static void free_audio_decoder(struct svp_ffmpeg_audio_decoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->pending_packet_data != NULL) {
        free(decoder->pending_packet_data);
        decoder->pending_packet_data = NULL;
    }
    if (decoder->swr_ctx != NULL) {
        swr_free(&decoder->swr_ctx);
    }
    if (decoder->frame != NULL) {
        av_frame_free(&decoder->frame);
    }
    if (decoder->codec_ctx != NULL) {
        avcodec_free_context(&decoder->codec_ctx);
    }
    av_channel_layout_uninit(&decoder->out_ch_layout);
    free(decoder);
}
#endif

#if SVP_HAS_VENDOR_FFMPEG
static void clear_pending_audio_packet(struct svp_ffmpeg_audio_decoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->pending_packet_data != NULL) {
        free(decoder->pending_packet_data);
        decoder->pending_packet_data = NULL;
    }
    decoder->pending_packet_length = 0;
    decoder->pending_packet_pts90k = 0;
}

static int32_t stash_pending_audio_packet(
    struct svp_ffmpeg_audio_decoder *decoder,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k
) {
    uint8_t *copy;

    if (decoder == NULL || data == NULL || length <= 0) {
        return -1;
    }

    clear_pending_audio_packet(decoder);
    copy = (uint8_t *)malloc((size_t)length);
    if (copy == NULL) {
        return -12;
    }
    memcpy(copy, data, (size_t)length);
    decoder->pending_packet_data = copy;
    decoder->pending_packet_length = length;
    decoder->pending_packet_pts90k = pts90k;
    return 0;
}

static int32_t fill_decoded_audio_frame(
    struct svp_ffmpeg_audio_decoder *decoder,
    svp_ffmpeg_decoded_audio_frame_t *outFrame
) {
    int outChannels;
    int outSamples;
    int outLineSize = 0;
    uint8_t *outData = NULL;
    int convertedSamples;

    if (decoder == NULL || decoder->frame == NULL || outFrame == NULL) {
        return -1;
    }

    if (decoder->frame->sample_rate > 0) {
        decoder->out_sample_rate = decoder->frame->sample_rate;
    }
    if (decoder->swr_ctx == NULL) {
        const int32_t targetChannels = preferred_output_channels(decoder->frame->ch_layout.nb_channels);
        av_channel_layout_uninit(&decoder->out_ch_layout);
        av_channel_layout_default(&decoder->out_ch_layout, targetChannels);
        if (swr_alloc_set_opts2(
            &decoder->swr_ctx,
            &decoder->out_ch_layout,
            decoder->out_format,
            decoder->out_sample_rate,
            &decoder->frame->ch_layout,
            (enum AVSampleFormat)decoder->frame->format,
            decoder->frame->sample_rate,
            0,
            NULL
        ) < 0) {
            av_frame_unref(decoder->frame);
            return -5;
        }
        if (swr_init(decoder->swr_ctx) < 0) {
            av_frame_unref(decoder->frame);
            return -6;
        }
    }

    outChannels = decoder->out_ch_layout.nb_channels > 0 ? decoder->out_ch_layout.nb_channels : 2;
    outSamples = av_rescale_rnd(
        swr_get_delay(decoder->swr_ctx, decoder->frame->sample_rate) + decoder->frame->nb_samples,
        decoder->out_sample_rate,
        decoder->frame->sample_rate,
        AV_ROUND_UP
    );

    if (av_samples_alloc(&outData, &outLineSize, outChannels, outSamples, decoder->out_format, 1) < 0) {
        av_frame_unref(decoder->frame);
        return -7;
    }

    convertedSamples = swr_convert(
        decoder->swr_ctx,
        &outData,
        outSamples,
        (const uint8_t * const *)decoder->frame->extended_data,
        decoder->frame->nb_samples
    );
    if (convertedSamples < 0) {
        av_freep(&outData);
        av_frame_unref(decoder->frame);
        return -8;
    }

    outFrame->sampleRate = decoder->out_sample_rate;
    outFrame->channels = outChannels;
    outFrame->bytesPerSample = av_get_bytes_per_sample(decoder->out_format);
    outFrame->size = convertedSamples * outChannels * outFrame->bytesPerSample;
    outFrame->data = (uint8_t *)malloc((size_t)outFrame->size);
    if (outFrame->data == NULL) {
        av_freep(&outData);
        av_frame_unref(decoder->frame);
        return -9;
    }
    memcpy(outFrame->data, outData, (size_t)outFrame->size);
    outFrame->pts90k = 0;
    if (decoder->frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        outFrame->pts90k = decoder->frame->best_effort_timestamp;
    }

    av_freep(&outData);
    av_frame_unref(decoder->frame);
    return 1;
}

static int32_t send_audio_packet(
    struct svp_ffmpeg_audio_decoder *decoder,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k
) {
    AVPacket *packet;
    int sendStatus;

    if (decoder == NULL || decoder->codec_ctx == NULL || data == NULL || length <= 0) {
        return -1;
    }

    packet = av_packet_alloc();
    if (packet == NULL) {
        return -3;
    }
    if (av_new_packet(packet, length) < 0) {
        av_packet_free(&packet);
        return -4;
    }
    memcpy(packet->data, data, (size_t)length);
    packet->pts = pts90k;
    packet->dts = pts90k;

    sendStatus = avcodec_send_packet(decoder->codec_ctx, packet);
    av_packet_free(&packet);
    return sendStatus;
}
#endif

void *svp_ffmpeg_audio_decoder_create(int32_t codecID) {
#if SVP_HAS_VENDOR_FFMPEG
    const int ffCodecID = map_codec_id(codecID);
    const AVCodec *codec;
    struct svp_ffmpeg_audio_decoder *decoder;

    if (ffCodecID == AV_CODEC_ID_NONE) {
        return NULL;
    }
    codec = avcodec_find_decoder(ffCodecID);
    if (codec == NULL) {
        return NULL;
    }

    decoder = (struct svp_ffmpeg_audio_decoder *)calloc(1, sizeof(struct svp_ffmpeg_audio_decoder));
    if (decoder == NULL) {
        return NULL;
    }
    decoder->codec_id = ffCodecID;
    decoder->codec_ctx = avcodec_alloc_context3(codec);
    if (decoder->codec_ctx == NULL) {
        free_audio_decoder(decoder);
        return NULL;
    }
    if (avcodec_open2(decoder->codec_ctx, codec, NULL) < 0) {
        free_audio_decoder(decoder);
        return NULL;
    }
    decoder->frame = av_frame_alloc();
    if (decoder->frame == NULL) {
        free_audio_decoder(decoder);
        return NULL;
    }

    decoder->out_format = AV_SAMPLE_FMT_S16;
    decoder->out_sample_rate = decoder->codec_ctx->sample_rate > 0 ? decoder->codec_ctx->sample_rate : 48000;
    av_channel_layout_default(
        &decoder->out_ch_layout,
        preferred_output_channels(decoder->codec_ctx->ch_layout.nb_channels)
    );
    return decoder;
#else
    (void)codecID;
    return NULL;
#endif
}

void svp_ffmpeg_audio_decoder_destroy(void *decoderHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_audio_decoder *decoder = (struct svp_ffmpeg_audio_decoder *)decoderHandle;
    free_audio_decoder(decoder);
#else
    (void)decoderHandle;
#endif
}

int32_t svp_ffmpeg_audio_decoder_flush(void *decoderHandle) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_audio_decoder *decoder = (struct svp_ffmpeg_audio_decoder *)decoderHandle;
    if (decoder == NULL || decoder->codec_ctx == NULL) {
        return -1;
    }
    clear_pending_audio_packet(decoder);
    avcodec_flush_buffers(decoder->codec_ctx);
    return 0;
#else
    (void)decoderHandle;
    return -38;
#endif
}

void svp_ffmpeg_decoded_audio_frame_release(svp_ffmpeg_decoded_audio_frame_t *frame) {
    if (frame == NULL) {
        return;
    }
    if (frame->data != NULL) {
        free(frame->data);
        frame->data = NULL;
    }
    frame->sampleRate = 0;
    frame->channels = 0;
    frame->bytesPerSample = 0;
    frame->pts90k = 0;
    frame->size = 0;
}

int32_t svp_ffmpeg_audio_decoder_decode(
    void *decoderHandle,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k,
    svp_ffmpeg_decoded_audio_frame_t *outFrame
) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_audio_decoder *decoder = (struct svp_ffmpeg_audio_decoder *)decoderHandle;
    int receiveStatus;
    int sendStatus;
    const uint8_t *packetData = data;
    int32_t packetLength = length;
    int64_t packetPTS = pts90k;

    if (decoder == NULL || decoder->codec_ctx == NULL || decoder->frame == NULL || outFrame == NULL) {
        return -1;
    }
    memset(outFrame, 0, sizeof(*outFrame));

    receiveStatus = avcodec_receive_frame(decoder->codec_ctx, decoder->frame);
    if (receiveStatus >= 0) {
        if (data != NULL && length > 0) {
            sendStatus = send_audio_packet(decoder, data, length, pts90k);
            if (sendStatus == AVERROR(EAGAIN)) {
                if (stash_pending_audio_packet(decoder, data, length, pts90k) < 0) {
                    av_frame_unref(decoder->frame);
                    return -12;
                }
            } else if (sendStatus < 0) {
                av_frame_unref(decoder->frame);
                return sendStatus;
            }
        }
        return fill_decoded_audio_frame(decoder, outFrame);
    }
    if (receiveStatus != AVERROR(EAGAIN) && receiveStatus != AVERROR_EOF) {
        return receiveStatus;
    }

    if (decoder->pending_packet_data != NULL) {
        packetData = decoder->pending_packet_data;
        packetLength = decoder->pending_packet_length;
        packetPTS = decoder->pending_packet_pts90k;
    }
    if (packetData == NULL || packetLength <= 0) {
        return 0;
    }

    sendStatus = send_audio_packet(decoder, packetData, packetLength, packetPTS);
    if (sendStatus == AVERROR(EAGAIN)) {
        if (decoder->pending_packet_data == NULL && packetData == data) {
            if (stash_pending_audio_packet(decoder, data, length, pts90k) < 0) {
                return -12;
            }
        }
        return sendStatus;
    }
    if (sendStatus < 0) {
        return sendStatus;
    }
    if (decoder->pending_packet_data == packetData) {
        clear_pending_audio_packet(decoder);
    }

    receiveStatus = avcodec_receive_frame(decoder->codec_ctx, decoder->frame);
    if (receiveStatus == AVERROR(EAGAIN) || receiveStatus == AVERROR_EOF) {
        return 0;
    }
    if (receiveStatus < 0) {
        return receiveStatus;
    }
    return fill_decoded_audio_frame(decoder, outFrame);
#else
    (void)decoderHandle;
    (void)data;
    (void)length;
    (void)pts90k;
    (void)outFrame;
    return -38;
#endif
}

int32_t svp_ffmpeg_audio_decoder_drain(
    void *decoderHandle,
    svp_ffmpeg_decoded_audio_frame_t *outFrame
) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_audio_decoder *decoder = (struct svp_ffmpeg_audio_decoder *)decoderHandle;
    int receiveStatus;
    int sendStatus;

    if (decoder == NULL || decoder->codec_ctx == NULL || decoder->frame == NULL || outFrame == NULL) {
        return -1;
    }
    memset(outFrame, 0, sizeof(*outFrame));

    receiveStatus = avcodec_receive_frame(decoder->codec_ctx, decoder->frame);
    if (receiveStatus >= 0) {
        return fill_decoded_audio_frame(decoder, outFrame);
    }
    if (receiveStatus != AVERROR(EAGAIN) && receiveStatus != AVERROR_EOF) {
        return receiveStatus;
    }

    if (decoder->pending_packet_data == NULL || decoder->pending_packet_length <= 0) {
        return 0;
    }

    sendStatus = send_audio_packet(
        decoder,
        decoder->pending_packet_data,
        decoder->pending_packet_length,
        decoder->pending_packet_pts90k
    );
    if (sendStatus == AVERROR(EAGAIN)) {
        return 0;
    }
    if (sendStatus < 0) {
        return sendStatus;
    }
    clear_pending_audio_packet(decoder);

    receiveStatus = avcodec_receive_frame(decoder->codec_ctx, decoder->frame);
    if (receiveStatus == AVERROR(EAGAIN) || receiveStatus == AVERROR_EOF) {
        return 0;
    }
    if (receiveStatus < 0) {
        return receiveStatus;
    }
    return fill_decoded_audio_frame(decoder, outFrame);
#else
    (void)decoderHandle;
    (void)outFrame;
    return -38;
#endif
}

int32_t svp_ffmpeg_video_decoder_decode(
    void *decoderHandle,
    const uint8_t *data,
    int32_t length,
    int64_t pts90k,
    svp_ffmpeg_decoded_frame_t *outFrame
) {
#if SVP_HAS_VENDOR_FFMPEG
    struct svp_ffmpeg_video_decoder *decoder = (struct svp_ffmpeg_video_decoder *)decoderHandle;
    AVPacket *packet;
    int sendStatus;
    int receiveStatus;
    int dstLinesize[4] = {0};
    uint8_t *dstData[4] = {0};
    int convertedHeight;
    size_t yBytes;
    size_t uvBytes;
    int dstHeight;

    if (decoder == NULL || decoder->codec_ctx == NULL || decoder->frame == NULL || outFrame == NULL) {
        return -1;
    }
    if (data == NULL || length <= 0) {
        return -2;
    }

    memset(outFrame, 0, sizeof(*outFrame));

    packet = av_packet_alloc();
    if (packet == NULL) {
        return -3;
    }
    if (av_new_packet(packet, length) < 0) {
        av_packet_free(&packet);
        return -4;
    }
    memcpy(packet->data, data, (size_t)length);
    packet->pts = pts90k;
    packet->dts = pts90k;

    sendStatus = avcodec_send_packet(decoder->codec_ctx, packet);
    av_packet_free(&packet);
    if (sendStatus < 0) {
        return sendStatus;
    }

    receiveStatus = avcodec_receive_frame(decoder->codec_ctx, decoder->frame);
    if (receiveStatus == AVERROR(EAGAIN) || receiveStatus == AVERROR_EOF) {
        return 0;
    }
    if (receiveStatus < 0) {
        return receiveStatus;
    }

    dstHeight = decoder->frame->height;
    if (decoder->sws_ctx == NULL) {
        decoder->sws_ctx = sws_getContext(
            decoder->frame->width,
            decoder->frame->height,
            (enum AVPixelFormat)decoder->frame->format,
            decoder->frame->width,
            decoder->frame->height,
            AV_PIX_FMT_NV12,
            SWS_BILINEAR,
            NULL,
            NULL,
            NULL
        );
    }
    if (decoder->sws_ctx == NULL) {
        av_frame_unref(decoder->frame);
        return -5;
    }

    if (av_image_alloc(dstData, dstLinesize, decoder->frame->width, decoder->frame->height, AV_PIX_FMT_NV12, 1) < 0) {
        av_frame_unref(decoder->frame);
        return -6;
    }

    convertedHeight = sws_scale(
        decoder->sws_ctx,
        (const uint8_t * const *)decoder->frame->data,
        decoder->frame->linesize,
        0,
        decoder->frame->height,
        dstData,
        dstLinesize
    );
    if (convertedHeight <= 0) {
        av_freep(&dstData[0]);
        av_frame_unref(decoder->frame);
        return -7;
    }

    yBytes = (size_t)dstLinesize[0] * (size_t)dstHeight;
    uvBytes = (size_t)dstLinesize[1] * (size_t)((dstHeight + 1) / 2);

    outFrame->planeY = (uint8_t *)malloc(yBytes);
    outFrame->planeUV = (uint8_t *)malloc(uvBytes);
    if (outFrame->planeY == NULL || outFrame->planeUV == NULL) {
        svp_ffmpeg_decoded_frame_release(outFrame);
        av_freep(&dstData[0]);
        av_frame_unref(decoder->frame);
        return -8;
    }

    memcpy(outFrame->planeY, dstData[0], yBytes);
    memcpy(outFrame->planeUV, dstData[1], uvBytes);

    outFrame->width = decoder->frame->width;
    outFrame->height = decoder->frame->height;
    outFrame->linesizeY = dstLinesize[0];
    outFrame->linesizeUV = dstLinesize[1];
    outFrame->pts90k = pts90k;
    if (decoder->frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        outFrame->pts90k = decoder->frame->best_effort_timestamp;
    }

    av_freep(&dstData[0]);
    av_frame_unref(decoder->frame);
    return 1;
#else
    (void)decoderHandle;
    (void)data;
    (void)length;
    (void)pts90k;
    (void)outFrame;
    return -38;
#endif
}
