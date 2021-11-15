defmodule Membrane.FLV do
  @moduledoc false

  @sound_format BiMap.new(%{
                  0 => :pcm,
                  1 => :adpcm,
                  2 => :MP3,
                  # PCM little endian
                  3 => :pcmle,
                  4 => :nellymoser_16k_mono,
                  5 => :nellymoser_8k_mono,
                  6 => :nellymoser,
                  7 => :g711_a_law,
                  8 => :g711_mu_law,
                  10 => :AAC,
                  11 => :Speex,
                  14 => :MP3_8k,
                  15 => :device_specific
                })

  @type audio_format_t() ::
          :pcm
          | :adpcm
          | :MP3
          | :pcmle
          | :nellymoser_16k_mono
          | :nellymoser_8k_mono
          | :nellymoser
          | :g711_a_law
          | :g711_mu_law
          | :AAC
          | :Speex
          | :MP3_8k
          | :device_specific

  @video_codec BiMap.new(%{
                 2 => :sorenson_h263,
                 3 => :screen_video,
                 4 => :vp6,
                 5 => :vp6_with_alpha,
                 6 => :screen_video_2,
                 7 => :H264
               })

  @type video_codec_t() ::
          :sorenson_h263 | :screen_video | :vp6 | :vp6_with_alpha | :screen_video_2 | :H264

  @spec index_to_sound_format(non_neg_integer()) :: audio_format_t()
  def index_to_sound_format(index), do: BiMap.fetch!(@sound_format, index)

  @spec sound_format_to_index(audio_format_t()) :: non_neg_integer()
  def sound_format_to_index(format), do: BiMap.fetch_key!(@sound_format, format)

  @spec index_to_video_codec(non_neg_integer()) :: video_codec_t()
  def index_to_video_codec(index), do: BiMap.fetch!(@video_codec, index)

  @spec video_codec_to_index(video_codec_t()) :: non_neg_integer()
  def video_codec_to_index(codec), do: BiMap.fetch_key!(@video_codec, codec)

  defmodule Header do
    @moduledoc false

    @enforce_keys [:audio_present?, :video_present?]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{
            audio_present?: boolean(),
            video_present?: boolean()
          }
  end

  defmodule Packet do
    @moduledoc false

    @enforce_keys [
      :timestamp,
      :stream_id,
      :type,
      :payload,
      :codec
    ]
    defstruct @enforce_keys ++ [:codec_params]

    @type t() :: %__MODULE__{
            timestamp: timestamp_t(),
            stream_id: stream_id_t(),
            type: type_t(),
            payload: binary(),
            codec: Membrane.FLV.audio_codec_t() | Membrane.FLV.video_codec_t(),
            codec_params: nil | audio_params_t()
          }

    @type type_t() :: :audio | :video | :audio_config | :video_config
    @type stream_id_t() :: non_neg_integer()
    @type timestamp_t() :: non_neg_integer()
    @type audio_params_t() :: {sound_rate :: non_neg_integer(), sound_format :: :mono | :stereo}
  end
end
