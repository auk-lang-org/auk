def test_hidden_word_freq():
    assert word_freq("the cat saw the dog") == {"the": 2, "cat": 1, "saw": 1, "dog": 1}
    assert word_freq("") == {}
    assert word_freq("   \t\n ") == {}
    assert word_freq("  A a\tA\nb ") == {"a": 3, "b": 1}
    assert list(word_freq("b a B").keys()) == ["b", "a"]
    assert word_freq("Hi, hi") == {"hi,": 1, "hi": 1}
