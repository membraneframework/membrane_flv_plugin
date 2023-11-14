Logger.configure(level: :info)

Mix.install([
  :membrane_aac_plugin,
  :membrane_file_plugin,
  :membrane_h264_plugin,
  :membrane_h264_format,
  {:membrane_flv_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  use Membrane.Pipeline

  @input_file __DIR__ |> Path.join("../test/fixtures/reference.flv") |> Path.expand()

  @impl true
  def handle_init(_ctx, _opts) do
    structure = [
      child(:source, %Membrane.File.Source{location: @input_file})
      |> child(:demuxer, Membrane.FLV.Demuxer),
      # setup output audio stream
      get_child(:demuxer)
      |> via_out(Pad.ref(:audio, 0))
      |> child({:parser, :audio}, %Membrane.AAC.Parser{
        out_encapsulation: :ADTS
      })
      |> child({:sink, :audio}, %Membrane.File.Sink{location: "audio.aac"}),
      # setup output video stream
      get_child(:demuxer)
      |> via_out(Pad.ref(:video, 0))
      |> child({:parser, :video}, %Membrane.H264.Parser{
        output_stream_structure: :annexb,
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child({:sink, :video}, %Membrane.File.Sink{location: "video.h264"})
    ]

    {[spec: structure], %{eos_left: 2}}
  end

  # the rest of the Example module is only used for termination of the pipeline after processing finishes
  @impl true
  def handle_element_end_of_stream({:sink, _type}, _pad, _ctx, state) do
    state = Map.update!(state, :eos_left, &(&1 - 1))

    if state.eos_left == 0 do
      {[terminate: :normal], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state), do: {[], state}
end

# Initialize the pipeline and start it
{:ok, _supervisor_pid, pipeline_pid} = Example.start_link()

monitor_ref = Process.monitor(pipeline_pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^monitor_ref, :process, _pipeline_pid, _reason} ->
    :ok
end
