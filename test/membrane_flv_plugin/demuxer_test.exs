defmodule Membrane.FLV.Demuxer.Test do
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing.Pipeline

  setup do
    pid = get_pipeline()
    on_exit(fn -> Pipeline.stop_and_terminate(pid, blocking?: true) end)
    %{pid: pid}
  end

  test "streams are detected", %{pid: pid} do
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :H264})
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :AAC})
    assert_sink_caps(pid, :video_sink, %Membrane.RemoteStream{content_format: :H264}, 3000)
    assert_sink_caps(pid, :audio_sink, %Membrane.RemoteStream.AAC{}, 3000)
    assert_sink_buffer(pid, :video_sink, %Membrane.Buffer{})
    assert_sink_buffer(pid, :audio_sink, %Membrane.Buffer{})
  end

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
          ctx,
          state
        ) do
      sink =
        case type do
          :audio -> :audio_sink
          :video -> :video_sink
        end

      spec = %ParentSpec{
        children: %{sink => Membrane.Testing.Sink},
        links: [
          link(:demuxer) |> via_out(pad) |> to(sink)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(_notification, _source, _ctx, state), do: {:ok, state}
  end

  defp get_pipeline() do
    {:ok, pid} =
      Pipeline.start_link(%Pipeline.Options{
        module: Support.Pipeline,
        custom_args: "test/fixtures/input.flv"
      })

    :ok = Pipeline.play(pid)
    pid
  end
end
