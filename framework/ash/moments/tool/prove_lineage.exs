app = String.to_atom(System.get_env("MANA_LINEAGE_APP", "my_app"))
Application.put_env(app, :ash_domains, Application.get_env(app, :ash_domains, []) ++ [LineageProof.Root, LineageProof.Branches, LineageProof.Cycle])

defmodule LineageProof.Root do
  use Ash.Domain, extensions: [Moments.Extension]
  moments do
    route("/checkout")
    moment :checkout do
      description("Checkout ready to choose the payment.")
    end
  end
end

defmodule LineageProof.Branches do
  use Ash.Domain, extensions: [Moments.Extension]
  moments do
    route("/payment")
    moment :approved do
      from(:checkout)
      description("Payment approved after checkout.")
    end
    moment :declined do
      from(:checkout)
      description("Payment declined after checkout.")
    end
  end
end

defmodule LineageProof.Cycle do
  use Ash.Domain, extensions: [Moments.Extension]
  moments do
    route("/cycle")
    moment :first do
      from(:second)
      description("First")
    end
    moment :second do
      from(:first)
      description("Second")
    end
  end
end

defmodule LineageProof do
  def reject(fun, message) do
    try do
      fun.()
      raise("Invalid lineage accepted")
    rescue
      e in ArgumentError ->
        unless String.contains?(Exception.message(e), message), do: reraise(e, __STACKTRACE__)
    end
  end
end

LineageProof.reject(fn -> Moments.Manifest.build(LineageProof.Branches) end, "Unknown Moment parent")
LineageProof.reject(fn -> Moments.Manifest.build(LineageProof.Cycle) end, "Moment parent cycle")
manifest = Moments.Manifest.build_many([LineageProof.Root, LineageProof.Branches])
%{"version" => 3, "protocol" => %{"name" => "moments", "version" => "0.1"},
  "moments" => %{"approved" => %{"from" => "checkout"}, "declined" => %{"from" => "checkout"}}} = manifest
false = Map.has_key?(manifest["moments"]["checkout"], "from")
%{"version" => 1} = Moments.Manifest.build(LineageProof.Root)
[output] = System.argv()
File.mkdir_p!(Path.dirname(output))
File.write!(output, Jason.encode!(manifest, pretty: true))
IO.puts("Lineage: cross-domain parents preserved, missing parent/cycle rejected, checks optional; exported #{output}")
