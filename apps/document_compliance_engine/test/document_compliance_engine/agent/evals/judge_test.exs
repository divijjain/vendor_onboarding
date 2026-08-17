defmodule DocumentComplianceEngine.Agent.Evals.JudgeTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.Evals.Judge

  describe "extract_text/1" do
    test "finds the text block when it's the only content block" do
      body = %{"content" => [%{"type" => "text", "text" => ~s({"score": 0.9})}]}

      assert {:ok, ~s({"score": 0.9})} = Judge.extract_text(body)
    end

    test "finds the text block even when a thinking block comes first" do
      # The real shape that caused a live judge-tier failure: Claude Sonnet
      # 5's extended-thinking responses put `type: "thinking"` ahead of
      # `type: "text"` in the content list.
      body = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "", "signature" => "abc"},
          %{"type" => "text", "text" => ~s({"score": 0.9, "reasoning": "ok"})}
        ]
      }

      assert {:ok, ~s({"score": 0.9, "reasoning": "ok"})} = Judge.extract_text(body)
    end

    test "errors when no content block has type text" do
      body = %{"content" => [%{"type" => "thinking", "thinking" => ""}]}

      assert {:error, {:unexpected_judge_response, _}} = Judge.extract_text(body)
    end

    test "errors on a response with no content key at all" do
      assert {:error, {:unexpected_judge_response, %{}}} = Judge.extract_text(%{})
    end
  end
end
