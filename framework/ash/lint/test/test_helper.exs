# A trigger that does not point at the flagged text fails the test instead of
# printing a warning.
System.put_env("ASSERT_TRIGGERS", "1")
ExUnit.start()
