module Pipewire.Stream where

import Language.C.Inline qualified as C

import Control.Exception (finally)
import Data.Vector.Storable qualified as VS
import Foreign (Storable (..), allocaBytes, castPtr, freeHaskellFunPtr)

import Pipewire.CoreAPI.CContext
import Pipewire.CoreAPI.Loop (PwLoop (..))
import Pipewire.Internal
import Pipewire.SPA.CContext qualified as SPAUtils
import Pipewire.Utilities.CContext qualified as Utils
import Pipewire.Utilities.Properties (PwProperties (..))

newtype PwStream = PwStream (Ptr PwStreamStruct) deriving newtype (Storable)
newtype PwStreamEvents = PwStreamEvents (Ptr PwStreamEventsStruct)
newtype PwStreamData = PwStreamData (Ptr (Ptr PwStreamStruct))
newtype PwBuffer = PwBuffer (Ptr PwBufferStruct)

C.context (C.baseCtx <> pwContext <> C.vecCtx <> SPAUtils.pwContext <> Utils.pwContext)

C.include "<pipewire/stream.h>"
C.include "<pipewire/keys.h>"
C.include "<spa/param/audio/format-utils.h>"

-- data PwStreamEvents = PwStreamEvents (Ptr PwStreamEventsStruct) PwStreamData

type OnProcessHandler = PwStream -> IO ()

withAudioStream :: PwLoop -> OnProcessHandler -> (PwStream -> IO a) -> IO a
withAudioStream pwLoop onProcess cb = do
    allocaBytes (fromIntegral [C.pure| size_t {sizeof (struct pw_stream**)} |]) \(streamData :: Ptr ()) -> do
        allocaBytes (fromIntegral [C.pure| size_t {sizeof (struct pw_stream_events)} |]) \(streamEvents :: Ptr PwStreamEventsStruct) -> do
            onProcessP <- $(C.mkFunPtr [t|Ptr () -> IO ()|]) onProcessWrapper
            -- setup pw_stream_events
            [C.block| void{
                struct pw_stream_events* pw_events = $(struct pw_stream_events* streamEvents);
                pw_events->version = PW_VERSION_STREAM_EVENTS;
                pw_events->process = $(void (*onProcessP)(void*));
            }|]
            props <-
                PwProperties
                    <$> [C.exp| struct pw_properties*{pw_properties_new(
                                            PW_KEY_MEDIA_TYPE, "Audio",
                                            PW_KEY_MEDIA_CATEGORY, "Playback",
                                            PW_KEY_MEDIA_ROLE, "Music",
                                            NULL)}|]
            stream <- pw_stream_new_simple pwLoop "audio-src" props (PwStreamEvents streamEvents) streamData
            poke (castPtr streamData) stream
            cb stream `finally` do
                pw_stream_destroy stream
                freeHaskellFunPtr onProcessP
  where
    onProcessWrapper streamData = do
        stream <- PwStream <$> peek (castPtr streamData)
        onProcess stream

type Channels = Int

connectAudioStream :: Channels -> PwStream -> IO ()
connectAudioStream (fromIntegral -> chans) (PwStream pwStream) = do
    [C.block| void{
    const struct spa_pod *params[1];
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat,
                        &SPA_AUDIO_INFO_RAW_INIT(
                                .format = SPA_AUDIO_FORMAT_S16,
                                .channels = $(int chans),
                                .rate = 44100 ));

    pw_stream_connect($(struct pw_stream* pwStream),
                          PW_DIRECTION_OUTPUT,
                          PW_ID_ANY,
                          PW_STREAM_FLAG_AUTOCONNECT |
                          PW_STREAM_FLAG_MAP_BUFFERS |
                          PW_STREAM_FLAG_RT_PROCESS,
                          params, 1);
  }|]

audioFrames :: Channels -> PwBuffer -> IO Int
audioFrames (fromIntegral -> chans) (PwBuffer pwBuffer) =
    fromIntegral
        <$> [C.block| int{
    struct pw_buffer* b = $(struct pw_buffer* pwBuffer);
    struct spa_buffer* buf = b->buffer;
    int stride = sizeof(int16_t) * $(int chans);
    int n_frames = buf->datas[0].maxsize / stride;
    if (b->requested)
      n_frames = SPA_MIN(b->requested, n_frames);

    // This should really be done after writing the audio frame
    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = stride;
    buf->datas[0].chunk->size = n_frames * stride;
    return n_frames;
  }|]

writeAudioFrame :: PwBuffer -> VS.Vector C.CFloat -> IO ()
writeAudioFrame (PwBuffer pwBuffer) samples = do
    [C.block| void {
      struct pw_buffer* b = $(struct pw_buffer* pwBuffer);
      float *src = $vec-ptr:(float *samples);
      int16_t *dst = b->buffer->datas[0].data;
      for (int i = 0; i < $vec-len:samples; i++)
        *dst++ = $vec-ptr:(float *samples)[i] * 32767.0;
    }|]

pw_stream_new_simple :: PwLoop -> Text -> PwProperties -> PwStreamEvents -> Ptr () -> IO PwStream
pw_stream_new_simple (PwLoop pwLoop) name (PwProperties props) (PwStreamEvents pwStreamEvents) (castPtr -> dataPtr) =
    withCString name \nameC -> do
        PwStream
            <$> [C.exp| struct pw_stream*{
               pw_stream_new_simple(
                       $(struct pw_loop* pwLoop),
                       $(const char* nameC),
                       $(struct pw_properties* props),
                       $(struct pw_stream_events* pwStreamEvents),
                       $(void* dataPtr))
               }|]

pw_stream_connect :: PwStream -> IO ()
pw_stream_connect (PwStream _pwStream) = pure ()

pw_stream_destroy :: PwStream -> IO ()
pw_stream_destroy (PwStream pwStream) =
    [C.exp| void{pw_stream_destroy($(struct pw_stream* pwStream))} |]

pw_stream_dequeue_bufer :: PwStream -> IO PwBuffer
pw_stream_dequeue_bufer (PwStream pwStream) =
    PwBuffer <$> [C.exp| struct pw_buffer*{pw_stream_dequeue_buffer($(struct pw_stream* pwStream))} |]

pw_stream_queue_buffer :: PwStream -> PwBuffer -> IO ()
pw_stream_queue_buffer (PwStream pwStream) (PwBuffer pwBuffer) =
    [C.exp| void{pw_stream_queue_buffer($(struct pw_stream* pwStream), $(struct pw_buffer* pwBuffer))} |]