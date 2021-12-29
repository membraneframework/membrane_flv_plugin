
Mix.install([
  :membrane_core,
  {:membrane_flv_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
  :membrane_file_plugin,
  :membrane_aac_plugin,
  :membrane_h264_ffmpeg_plugin
])

defmodule Example do
  use Membrane.Pipeline

  @input_file __DIR__ |> Path.join("../test/fixtures/reference.flv") |> Path.expand()

  @impl true
  def handle_init(_opts) do
    spec = %ParentSpec{
      children: [
        src: %Membrane.File.Source{location: @input_file},
        demuxer: Membrane.FLV.Demuxer,
        video_sink: %Membrane.File.Sink{location: "video.h264"},
        audio_sink: %Membrane.File.Sink{location: "audio.aac"},
        audio_parser: %Membrane.AAC.Parser{
          in_encapsulation: :none,
          out_encapsulation: :ADTS
        },
        video_parser: %Membrane.H264.FFmpeg.Parser{
          framerate: {30, 1},
        }
      ],
      links: [
        link(:src) |> to(:demuxer),
        link(:demuxer) |> via_out(Pad.ref(:audio, 0)) |> to(:audio_parser) |> to(:audio_sink),
        link(:demuxer) |> via_out(Pad.ref(:video, 0)) |> to(:video_parser) |> to(:video_sink)
      ]
    }

    {{:ok, spec: spec}, %{eos_counter: 0}}
  end

  # the rest of the Example module is only used for termination of the pipeline after processing finishes
  @impl true
  def handle_element_end_of_stream({sink, _pad}, _ctx, state) when sink in [:audio_sink, :video_sink] do
    if state.eos_counter == 1 do
      __MODULE__.stop_and_terminate(self())
    end
    {:ok, Map.update!(state, :eos_counter, & &1 + 1)}
  end

  @impl true
  def handle_element_end_of_stream(_element, _ctx, state), do: {:ok, state}
end

# Initialize the pipeline and start it
{:ok, pid} = Example.start_link()
:ok = Membrane.Pipeline.play(pid)

monitor_ref = Process.monitor(pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
    :ok
end
