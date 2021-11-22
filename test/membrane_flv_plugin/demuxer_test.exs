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
          src: %Membrane.File.Source{location: input_file_path},
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
          {:new_stream, Pad.ref(type, _ref) = pad, _codec},
          :demuxer,
          _ctx,
          state
        ) do
      {sink_name, file_name} =
        case type do
          :audio -> {:audio_sink, "/tmp/audio.aac"}
          :video -> {:video_sink, "/tmp/video.h264"}
        end

      spec = %ParentSpec{
        children: %{sink_name => %Membrane.File.Sink{location: file_name}},
        links: [
          link(:demuxer) |> via_out(pad) |> to(sink_name)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(_notification, _source, _ctx, state), do: {:ok, state}
  end

  setup do
    {:ok, pid} =
      Pipeline.start_link(%Pipeline.Options{
        module: Support.Pipeline,
        custom_args: "test/fixtures/input.flv"
      })

    :ok = Pipeline.play(pid)

    on_exit(fn ->
      Pipeline.stop_and_terminate(pid, blocking?: true)
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

    assert byte_size(audio) == 94_402
    assert byte_size(video) == 204_166
  end
end
