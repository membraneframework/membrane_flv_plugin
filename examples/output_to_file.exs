
Mix.install([
  :membrane_core,
  {:membrane_flv_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()},
  :membrane_file_plugin,
  {:membrane_aac_plugin, path: __DIR__ |> Path.join("../../membrane_aac_plugin") |> Path.expand()}
])

defmodule Example do
  use Membrane.Pipeline

  @impl true
  def handle_init(input_file) do
    spec = %ParentSpec{
      children: [
        src: %Membrane.File.Source{location: input_file},
        demuxer: Membrane.FLV.Demuxer,
        video_sink: %Membrane.File.Sink{location: "video.h264"},
        audio_sink: %Membrane.File.Sink{location: "audio.aac"},
        audio_parser: %Membrane.AAC.Parser{
          in_encapsulation: :none,
          out_encapsulation: :ADTS
        }
      ],
      links: [
        link(:src) |> to(:demuxer),

        # Mind you can prelink the pads if you know the stream id that you are interested in
        link(:demuxer) |> via_out(Pad.ref(:audio, 0)) |> to(:audio_parser) |> to(:audio_sink),
        link(:demuxer) |> via_out(Pad.ref(:video, 0)) |> to(:video_sink)
      ]
    }

    {{:ok, spec: spec}, %{}}
  end
end

ref =
  Example.start_link("../test/fixtures/input.flv")
  |> elem(1)
  |> tap(&Membrane.Pipeline.play/1)
  |> then(&Process.monitor/1)

receive do
  {:DOWN, ^ref, :process, _pid, _reason} ->
    :ok
end
