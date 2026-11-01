ExUnit.start(exclude: if(System.get_env("MANA_TEST_POSTGRES"), do: [], else: [:postgres]))
