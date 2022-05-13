defmodule Membrane.FLV.Demuxer.Test do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing.Pipeline

  defmodule Support.Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(input_file_path) do
      spec = %ParentSpec{
        children: [
          src: %Membrane.File.Source{
            location: input_file_path,
            caps: %Membrane.RemoteStream{content_format: Membrane.FLV, type: :bytestream}
          },
          demuxer: Membrane.FLV.Demuxer
        ],
        links: [
          link(:src) |> to(:demuxer)
        ]
      }

      {{:ok, spec: spec}, %{}}
    end

    @impl true
    def handle_notification(
          {:new_stream, Pad.ref(:audio, _ref) = pad, :AAC},
          :demuxer,
          _ctx,
          state
        ) do
      spec = %ParentSpec{
        children: %{
          audio_parser: %Membrane.AAC.Parser{
            in_encapsulation: :none,
            out_encapsulation: :ADTS
          },
          audio_sink: %Membrane.File.Sink{location: "/tmp/audio.aac"}
        },
        links: [
          link(:demuxer) |> via_out(pad) |> to(:audio_parser) |> to(:audio_sink)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(
          {:new_stream, Pad.ref(:video, _ref) = pad, :H264},
          :demuxer,
          _ctx,
          state
        ) do
      spec = %ParentSpec{
        children: %{
          video_parser: %Membrane.H264.FFmpeg.Parser{
            alignment: :au,
            skip_until_parameters?: false
          },
          video_sink: %Membrane.File.Sink{location: "/tmp/video.h264"}
        },
        links: [
          link(:demuxer) |> via_out(pad) |> to(:video_parser) |> to(:video_sink)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(_notification, _source, _ctx, state), do: {:ok, state}
  end

  setup do
    assert {:ok, pid} =
             Pipeline.start(
               module: Support.Pipeline,
               custom_args: "test/fixtures/reference.flv"
             )

    Pipeline.execute_actions(pid, playback: :playing)

    on_exit(fn ->
      Pipeline.terminate(pid, blocking?: true)
      File.rm!("/tmp/audio.aac")
      File.rm!("/tmp/video.h264")
    end)

    %{pid: pid}
  end

  test "streams are detected", %{pid: pid} do
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :H264})
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :AAC})
    assert_end_of_stream(pid, :video_sink, :input)
    assert_end_of_stream(pid, :audio_sink, :input)

    assert File.exists?("/tmp/audio.aac")
    assert File.exists?("/tmp/video.h264")

    audio = File.read!("/tmp/audio.aac")
    video = File.read!("/tmp/video.h264")

    assert byte_size(audio) == 96_303
    assert byte_size(video) == 144_615
  end
end
