defmodule Membrane.FLV do
  @moduledoc """
  Format utilities and internal struct definitions for Membrane FLV Plugin
  """

  @typedoc """
  List of audio codecs supported by the FLV format.
  """
  @type audio_codec_t() ::
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

  @typedoc """
  List of video codecs supported by the FLV format.
  """
  @type video_codec_t() ::
          :sorenson_h263 | :screen_video | :vp6 | :vp6_with_alpha | :screen_video_2 | :H264

  @spec index_to_sound_format(non_neg_integer()) :: audio_codec_t()
  def index_to_sound_format(0), do: :pcm
  def index_to_sound_format(1), do: :adpcm
  def index_to_sound_format(2), do: :MP3
  def index_to_sound_format(3), do: :pcmle
  def index_to_sound_format(4), do: :nellymoser_16k_mono
  def index_to_sound_format(5), do: :nellymoser_8k_mono
  def index_to_sound_format(6), do: :nellymoser
  def index_to_sound_format(7), do: :g711_a_law
  def index_to_sound_format(8), do: :g711_mu_law
  def index_to_sound_format(10), do: :AAC
  def index_to_sound_format(11), do: :Speex
  def index_to_sound_format(14), do: :MP3_8k
  def index_to_sound_format(15), do: :device_specific

  @spec sound_format_to_index(audio_codec_t()) :: non_neg_integer()
  def sound_format_to_index(:pcm), do: 0
  def sound_format_to_index(:adpcm), do: 1
  def sound_format_to_index(:MP3), do: 2
  def sound_format_to_index(:pcmle), do: 3
  def sound_format_to_index(:nellymoser_16k_mono), do: 4
  def sound_format_to_index(:nellymoser_8k_mono), do: 5
  def sound_format_to_index(:nellymoser), do: 6
  def sound_format_to_index(:g711_a_law), do: 7
  def sound_format_to_index(:g711_mu_law), do: 8
  def sound_format_to_index(:AAC), do: 10
  def sound_format_to_index(:Speex), do: 11
  def sound_format_to_index(:MP3_8k), do: 14
  def sound_format_to_index(:device_specific), do: 15

  @spec index_to_video_codec(non_neg_integer()) :: video_codec_t()
  def index_to_video_codec(2), do: :sorenson_h263
  def index_to_video_codec(3), do: :screen_video
  def index_to_video_codec(4), do: :vp6
  def index_to_video_codec(5), do: :vp6_with_alpha
  def index_to_video_codec(6), do: :screen_video_2
  def index_to_video_codec(7), do: :H264

  @spec video_codec_to_index(video_codec_t()) :: non_neg_integer()
  def video_codec_to_index(:sorenson_h263), do: 2
  def video_codec_to_index(:screen_video), do: 3
  def video_codec_to_index(:vp6), do: 4
  def video_codec_to_index(:vp6_with_alpha), do: 5
  def video_codec_to_index(:screen_video_2), do: 6
  def video_codec_to_index(:H264), do: 7

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
      :pts,
      :dts,
      :stream_id,
      :type,
      :payload,
      :codec
    ]
    defstruct @enforce_keys ++
                [
                  codec_params: %{},
                  frame_type: :interframe
                ]

    @type t() :: %__MODULE__{
            pts: timestamp_t(),
            dts: timestamp_t() | nil,
            stream_id: stream_id_t(),
            type: type_t(),
            payload: binary(),
            codec: Membrane.FLV.audio_codec_t() | Membrane.FLV.video_codec_t(),
            codec_params: video_params_t() | audio_params_t(),
            frame_type: frame_type_t()
          }

    defguard is_audio(packet) when packet.type in [:audio, :audio_config]
    defguard is_video(packet) when packet.type in [:video, :video_config]

    @type type_t() :: :audio | :video | :audio_config | :video_config
    @type stream_id_t() :: non_neg_integer()
    @type timestamp_t() :: non_neg_integer()
    @type audio_params_t() :: %{sound_rate: non_neg_integer(), sound_format: :mono | :stereo}
    @type video_params_t() :: %{composition_time: non_neg_integer()}
    @type frame_type_t() :: :keyframe | :interframe
  end
end
