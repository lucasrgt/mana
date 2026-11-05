defmodule Mop.Money.Split do
  @moduledoc """
  Splitting an amount in cents across installments so the parts close exactly with the total.
  """

  @doc """
  Rescales `values` proportionally so they add up to `total`.

  Each part is floored and the leftover cents go to the first part. Returns `values` untouched
  when there is nothing to rescale: an empty plan, a non-positive total or a non-positive sum.
  This is PubPauta's `MediaAuthorizationBillingPlan.Rescale`, the agency's receivable over the
  commission while the client's due dates stay the same.
  """
  def rescale([], _total), do: []
  def rescale(values, total) when total <= 0, do: values

  def rescale(values, total) do
    source = sum(values)

    if source <= 0 do
      values
    else
      close(scale(values, total, source), total)
    end
  end

  @doc "Each value times `total`, floor-divided by `source`."
  def scale([value | values], total, source),
    do: [Integer.floor_div(value * total, source) | scale(values, total, source)]

  def scale([], _total, _source), do: []

  @doc "Adds to the first part whatever is missing for `parts` to add up to `total`."
  def close([first | rest] = parts, total), do: [first + (total - sum(parts)) | rest]

  def sum([value | values]), do: value + sum(values)
  def sum([]), do: 0
end
