defmodule Kuroneko.Screen.SettingsTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Screen.Settings

  doctest Settings

  @moduletag :tmp_dir

  test "kept in a file, defaults without one", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "data", "screen.json"])
    assert Settings.load(path) == %Settings{}

    {:ok, settings} =
      Settings.merge(%Settings{}, %{
        rotate: 180,
        brightness: 40,
        sleep: 5,
        calibration: [1.02, 0.0, -3.0, 0.01, 0.95, 4.0]
      })

    assert :ok = Settings.save(settings, path)
    assert Settings.load(path) == settings
  end

  test "values in a file that do not fit are left out", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "screen.json")
    File.write!(path, ~s({"rotate":180,"brightness":900,"calibration":[5,5,5,5,5,5],"x":1}))
    assert Settings.load(path) == %Settings{rotate: 180}

    File.write!(path, "not json")
    assert Settings.load(path) == %Settings{}
  end

  test "changes are all taken, or none" do
    assert Settings.merge(%Settings{}, %{"sleep" => 15, "rotate" => 45}) ==
             {:error, {:invalid, "rotate"}}

    assert Settings.merge(%Settings{}, [1]) == {:error, :not_an_object}
  end
end
