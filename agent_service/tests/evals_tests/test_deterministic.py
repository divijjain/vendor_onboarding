from evals.deterministic import tax_id_verbatim


def test_tax_id_verbatim_true_when_present_in_source():
    assert tax_id_verbatim("12-3456789", "EIN: 12-3456789\nOther text") is True


def test_tax_id_verbatim_false_when_hallucinated():
    assert tax_id_verbatim("12-3456789", "EIN: 98-7654321") is False


def test_tax_id_verbatim_false_when_empty():
    assert tax_id_verbatim("", "EIN: 12-3456789") is False
    assert tax_id_verbatim("   ", "EIN: 12-3456789") is False
