defmodule Kuroneko.WiFi.ScannerTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WiFi.Scanner

  @minute 60_000

  defp ap(bssid, percent), do: %{bssid: bssid, ssid: "home", signal_percent: percent}

  test "an access point stays five minutes after it was last seen, with its latest signal" do
    seen = Scanner.remember(%{}, [ap("a", 80), ap("b", 40)], 0)
    seen = Scanner.remember(seen, [ap("a", 70)], 4 * @minute)

    assert %{"a" => {%{signal_percent: 70}, _}, "b" => _} = Scanner.recent(seen, 5 * @minute)
    assert Map.keys(Scanner.recent(seen, 5 * @minute + 1)) == ["a"]
    assert Scanner.recent(seen, 9 * @minute + 1) == %{}
  end

  test "scans again after ten seconds" do
    assert Scanner.due?(nil, 0)
    refute Scanner.due?(0, 9_999)
    assert Scanner.due?(0, 10_000)
  end

  test "the host has no access points and cannot scan" do
    assert Scanner.access_points(scan: true) == []
    assert Scanner.scan() == {:error, :no_wifi}
  end
end
