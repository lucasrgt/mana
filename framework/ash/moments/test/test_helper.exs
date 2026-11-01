Application.put_env(:ash, :default_string_length_count, :codepoints)
ExUnit.start(exclude: if(System.get_env("MANA_TEST_POSTGRES"), do: [], else: [:postgres]))
