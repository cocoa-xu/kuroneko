defmodule Kuroneko.WakeOnLanTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WakeOnLan

  doctest WakeOnLan

  test "the magic packet is six 0xFF and the address sixteen times" do
    packet = WakeOnLan.packet(<<1, 2, 3, 4, 5, 6>>)
    assert byte_size(packet) == 102
    assert binary_part(packet, 0, 6) == <<255, 255, 255, 255, 255, 255>>
    assert binary_part(packet, 96, 6) == <<1, 2, 3, 4, 5, 6>>
  end
end
