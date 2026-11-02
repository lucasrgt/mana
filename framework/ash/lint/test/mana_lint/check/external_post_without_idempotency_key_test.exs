defmodule ManaLint.Check.ExternalPostWithoutIdempotencyKeyTest do
  use Credo.Test.Case

  alias ManaLint.Check.ExternalPostWithoutIdempotencyKey, as: Check

  test "POSTs from a Stripe client without a key" do
    """
    defmodule App.Payments.Stripe.Live do
      def refund(id), do: request(:post, "/v1/refunds", payment_intent: id)
      def capture(id), do: Req.post!(client(), url: "/v1/payment_intents/\#{id}/capture")
      def cancel(id), do: Req.request(client(), method: :post, url: "/v1/x/\#{id}")
      def get(id), do: request(:get, "/v1/payment_intents/\#{id}", [])

      defp request(method, path, fields), do: Req.request(client(), method: method, url: path, form: fields)
      defp client, do: Req.new(base_url: "https://api.stripe.com")
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == [
               "Req.post!",
               "Req.request",
               "request"
             ]
    end)
  end

  test "a key in the call or in the helper it goes through" do
    """
    defmodule App.Payments.Stripe.Live do
      def refund(charge), do: request(:post, "/v1/refunds", [payment_intent: charge.pi], "refund-" <> charge.id)
      def capture(id), do: Req.post!(client(), url: "/x", headers: [{"Idempotency-Key", "capture-" <> id}])

      defp request(method, path, fields, key),
        do: Req.request(client(), method: method, url: path, form: fields, headers: [{"idempotency-key", key}])

      defp client, do: Req.new(base_url: "https://api.stripe.com")
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "a helper whose key defaults to none, called without it" do
    """
    defmodule App.Stripe do
      def account(fields), do: request(:post, "/v1/accounts", fields)
      def refund(id, key), do: request(:post, "/v1/refunds", [payment_intent: id], key)

      defp request(method, path, fields \\\\ [], key \\\\ nil) do
        headers = if key, do: [{"idempotency-key", key}], else: []
        Req.request(Req.new(), method: method, url: path, form: fields, headers: headers)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.line_no == 2))
  end

  test "modules that are not configured clients" do
    code = """
    defmodule App.Push.Fcm do
      def send(token), do: Req.post!("https://fcm.googleapis.com/send", json: %{token: token})
    end
    """

    code |> to_source_file() |> run_check(Check) |> refute_issues()
    code |> to_source_file() |> run_check(Check, clients: ["App.Push"]) |> assert_issue()
  end
end
