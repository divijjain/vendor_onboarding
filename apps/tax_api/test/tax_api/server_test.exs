defmodule TaxApi.ServerTest do
  use ExUnit.Case, async: true

  alias TaxApi.Server

  test "accepts a well-formed EIN" do
    assert Server.valid?("12-3456789") == %{valid: true}
  end

  test "ignores surrounding whitespace" do
    assert Server.valid?("  12-3456789  ") == %{valid: true}
  end

  test "rejects malformed and absent EINs" do
    for tax_id <- ["123456789", "1-23456789", "12-345678", "[illegible]", "N/A", ""] do
      assert Server.valid?(tax_id) == %{valid: false}, "expected #{inspect(tax_id)} to be invalid"
    end
  end
end
