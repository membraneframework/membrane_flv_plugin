defmodule Membrane.FLV.Demuxer.Test do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline

  defmodule Support.Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, input_file_path) do
      structure = [
        child(:src, %Membrane.File.Source{
          location: input_file_path
        })
        |> child(:demuxer, Membrane.FLV.Demuxer)
      ]

      {[spec: structure], %{}}
    end

    @impl true
    def handle_child_notification(
          {:new_stream, Pad.ref(type, _ref) = pad, codec},
          :demuxer,
          _ctx,
          state
        )
        when {type, codec} in [{:audio, :AAC}, {:video, :H264}] do
      {parser, location} =
        case codec do
          :AAC ->
            {%Membrane.AAC.Parser{
               in_encapsulation: :none,
               out_encapsulation: :ADTS
             }, "/tmp/audio.aac"}

          :H264 ->
            {%Membrane.H264.FFmpeg.Parser{
               alignment: :au,
               skip_until_parameters?: false
             }, "/tmp/video.h264"}
        end

      structure = [
        get_child(:demuxer)
        |> via_out(pad)
        |> child({:parser, type}, parser)
        |> child({:sink, type}, %Membrane.File.Sink{location: location})
      ]

      {[spec: structure], state}
    end

    @impl true
    def handle_child_notification(_notification, _source, _ctx, state), do: {[], state}
  end

  setup do
    pid =
      Pipeline.start_link_supervised!(
        module: Support.Pipeline,
        custom_args: "test/fixtures/reference.flv"
      )

    Pipeline.execute_actions(pid, playback: :playing)

    on_exit(fn ->
      File.rm!("/tmp/audio.aac")
      File.rm!("/tmp/video.h264")
    end)

    %{pid: pid}
  end

  test "streams are detected", %{pid: pid} do
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :H264})
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :AAC})
    assert_end_of_stream(pid, {:sink, :video}, :input)
    assert_end_of_stream(pid, {:sink, :audio}, :input)

    assert File.exists?("/tmp/audio.aac")
    assert File.exists?("/tmp/video.h264")

    audio = File.read!("/tmp/audio.aac")
    video = File.read!("/tmp/video.h264")

    assert byte_size(audio) == 96_303
    assert byte_size(video) == 144_615
  end
end
